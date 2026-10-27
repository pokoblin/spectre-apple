import CoreImage
import MetalKit
import QuartzCore
import Synchronization

/// Puts decoded frames on screen through an `MTKView`.
///
/// Two pacing modes:
/// - ``Mode/onArrival``: the view's own display link is paused and each
///   decoded frame is drawn as soon as it arrives (the drawable then
///   presents at the next refresh). Lowest latency; what a remote desktop wants.
/// - ``Mode/displayLink``: the view's display link polls the mailbox every
///   refresh. Steadier pacing, up to one refresh more latency.
@MainActor
public final class VideoPresenter: NSObject, MTKViewDelegate {
    public enum Mode: String, Sendable, CaseIterable {
        case onArrival
        case displayLink
    }

    public let renderer: VideoRenderer
    public let mailbox: FrameMailbox
    public let stats: PlaybackStats
    public var color = ColorDescription.blockCodecDefault
    /// The picture's size (gdp-spec.md §7.2); nil: the decoded texture's.
    public var displaySize: CGSize?
    public private(set) var lastError: String?

    public var mode: Mode = .onArrival {
        didSet { applyMode() }
    }

    /// Whether decode→present times are measured on-screen times
    /// (`MTLDrawable.presentedTime`) or, in the simulator, GPU completion.
    public static let measuresOnScreenTime: Bool = {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }()

    /// When set, each drawable stays on screen at least this long
    /// (`MTLCommandBuffer.present(_:afterMinimumDuration:)`): even pacing
    /// of a 60 fps stream on a 120 Hz display, at the cost of latency when
    /// frames arrive early.
    public var minimumPresentDuration: CFTimeInterval?

    /// The display link's rate in ``Mode/displayLink`` (the view's
    /// `preferredFramesPerSecond`); matching the stream's rate gives each
    /// frame the same number of refreshes on a faster display.
    public var displayLinkRate = 120 {
        didSet { view?.preferredFramesPerSecond = displayLinkRate }
    }

    /// The most drawables committed but not yet on screen. Past it, a new
    /// frame waits in the mailbox (where a newer one replaces it) until one
    /// is presented. Without a cap, a stream at exactly the display's rate
    /// builds a queue that never drains: three frames of latency on a 60 Hz
    /// display. 1 halves the frame rate (a presented handler fires too late
    /// to make the next refresh); 2 keeps 60 fps at about half the latency.
    /// nil: no cap (CAMetalLayer's own three drawables).
    public var maxFramesInFlight: Int? = 2

    private weak var view: MTKView?
    private let drawScheduled = Atomic<Bool>(false)
    private let inFlight = Atomic<Int>(0)

    // The cursor overlay (gdp-spec.md §7.4): drawn over every frame, and over
    // the last one again when it changes between frames.
    private var cursorImage: CursorImage?
    private var cursorTexture: CursorTexture?
    private var cursorPosition: CGPoint?
    private var zoom = PictureZoom.fit
    /// Lossless refinement's overlay plane while the session has it
    /// (gdp-spec.md §7.8): drawn over every frame, and over the last one
    /// again when a layer-only frame changes it.
    public var refinement: RefinementPlane? {
        didSet {
            guard refinement !== oldValue else { return }
            overlayTexture = nil
            cursorChanged()
        }
    }
    private var overlayTexture: MTLTexture?

    /// The last frame drawn, kept (with its pixel buffer) to redraw the cursor over.
    private var lastTextures: VideoTextures?
    /// The cursor changed since the last drawable: present the last frame
    /// again unless a new one comes first.
    private let redrawWanted = Atomic<Bool>(false)

    public init(renderer: VideoRenderer, mailbox: FrameMailbox, stats: PlaybackStats) {
        self.renderer = renderer
        self.mailbox = mailbox
        self.stats = stats
    }

    /// The highest refresh rate of the display the view is on, 0 before it
    /// is in a window.
    public var displayRefreshRate: Int {
        #if os(macOS)
        view?.window?.screen?.maximumFramesPerSecond ?? 0
        #else
        view?.window?.windowScene?.screen.maximumFramesPerSecond ?? 0
        #endif
    }

    #if os(macOS)
    /// The window the view is in, to follow it across displays.
    public var window: NSWindow? { view?.window }
    #endif

    public func attach(_ view: MTKView) {
        view.device = renderer.device
        view.colorPixelFormat = VideoRenderer.colorPixelFormat
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.autoResizeDrawable = true
        view.preferredFramesPerSecond = displayLinkRate
        // The shader writes non-linear R'G'B' into a non-sRGB format: tag
        // the layer sRGB so the system colour-manages it like the upstream
        // client's B8G8R8A8_UNORM + SRGB_NONLINEAR swapchain.
        #if os(macOS)
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #else
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #endif
        view.delegate = self
        self.view = view
        applyMode()
    }

    /// The host's cursor image to draw over the picture; nil or hidden: none.
    public func setCursorImage(_ image: CursorImage?) {
        let image = image?.isHidden == false ? image : nil
        guard image != cursorImage else { return }
        let wasDrawn = cursorOverlay != nil
        cursorImage = image
        cursorTexture = image.flatMap(renderer.makeCursorTexture)
        if wasDrawn || cursorOverlay != nil { cursorChanged() }
    }

    /// Where to draw it: 0...1 over the output (gdp-spec.md §7.4), nil: not drawn.
    public func setCursorPosition(_ position: CGPoint?) {
        guard position != cursorPosition else { return }
        let wasDrawn = cursorOverlay != nil
        cursorPosition = position
        if wasDrawn || cursorOverlay != nil { cursorChanged() }
    }

    /// The last frame drawn, as an image no larger than `maxDimension`
    /// pixels on its long side (a thumbnail of the remote desktop), the
    /// codec's padding cropped off. Nil before the first frame.
    public func snapshot(maxDimension: CGFloat) -> CGImage? {
        guard let frame = lastTextures?.frame else { return nil }
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        if let displaySize {
            // CIImage's origin is the bottom left: the picture is the top of the buffer.
            let extent = image.extent
            image = image.cropped(to: CGRect(x: 0, y: extent.height - displaySize.height,
                                             width: min(displaySize.width, extent.width),
                                             height: min(displaySize.height, extent.height)))
        }
        let long = max(image.extent.width, image.extent.height)
        guard long > 0 else { return nil }
        let scale = min(1, maxDimension / long)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent.integral)
    }

    /// The last frame drawn (what is on screen), nil before the first.
    /// Region alerts read it (``RegionSignature``).
    public var lastFrame: DecodedFrame? { lastTextures?.frame }

    /// How the picture is magnified; the last frame is drawn again at once.
    public func setZoom(_ zoom: PictureZoom) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        cursorChanged()
    }

    private var cursorOverlay: CursorOverlay? {
        guard let cursorTexture, let cursorPosition else { return nil }
        return CursorOverlay(texture: cursorTexture, position: cursorPosition)
    }

    /// The overlay plane changed with no new picture (a layer-only frame):
    /// the last frame again, with it. Any thread.
    public nonisolated func refinementChanged() {
        redrawWanted.store(true, ordering: .releasing)
        frameAvailable()
    }

    /// Ask for the last frame again with the new cursor. In
    /// ``Mode/displayLink`` the next refresh picks the request up; on
    /// arrival it is one coalesced draw, like a frame's.
    private func cursorChanged() {
        redrawWanted.store(true, ordering: .releasing)
        frameAvailable()
    }

    /// Called from any thread when the decoder produced a frame.
    public nonisolated func frameAvailable() {
        // Coalesce: one pending main-thread draw at a time (frames and cursor redraws alike).
        guard drawScheduled.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
        else { return }
        DispatchQueue.main.async { [self] in
            drawScheduled.store(false, ordering: .releasing)
            MainActor.assumeIsolated {
                guard mode == .onArrival, let view else { return }
                view.draw()
            }
        }
    }

    /// A drawable reached the screen (or was dropped): draw what waited for it.
    private nonisolated func frameLeftQueue() {
        inFlight.subtract(1, ordering: .acquiringAndReleasing)
        if mailbox.hasFrame || redrawWanted.load(ordering: .acquiring) { frameAvailable() }
    }

    private func applyMode() {
        guard let view else { return }
        switch mode {
        case .onArrival:
            view.isPaused = true
            view.enableSetNeedsDisplay = false
        case .displayLink:
            view.enableSetNeedsDisplay = false
            view.isPaused = false
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        // At the cap, a frame waits in the mailbox and a redraw in
        // `redrawWanted`; frameLeftQueue() comes back for either.
        if let limit = maxFramesInFlight, inFlight.load(ordering: .acquiring) >= limit { return }
        if let frame = mailbox.take() {
            let textures: VideoTextures
            do {
                textures = try renderer.textures(for: frame)
            } catch {
                lastError = String(describing: error)
                return
            }
            lastTextures = textures
            // The new frame carries the current cursor.
            redrawWanted.store(false, ordering: .releasing)
            present(textures, label: "video frame \(frame.sequence)",
                    record: PresentRecord(frame: frame, zeroCopy: textures.isZeroCopy, stats: stats), in: view)
        } else if redrawWanted.exchange(false, ordering: .acquiringAndReleasing), let textures = lastTextures {
            // A cursor change between frames: the last frame again, not
            // recorded (the stats are the video's), but counted in flight.
            if !present(textures, label: "cursor redraw", record: nil, in: view) {
                redrawWanted.store(true, ordering: .releasing)
            }
        }
    }

    /// Encodes `textures` (with the cursor) into the view's next drawable
    /// and commits it. `record`, for a new video frame, collects its stats.
    @discardableResult
    private func present(_ textures: VideoTextures, label: String, record: PresentRecord?, in view: MTKView) -> Bool {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return false }
        commandBuffer.label = label
        let videoSize = displaySize ?? CGSize(width: textures.luma.width, height: textures.luma.height)
        let viewport = VideoRenderer.viewport(video: videoSize, drawable: view.drawableSize, zoom: zoom)
        renderer.encode(textures, color: color, displaySize: displaySize, viewport: viewport, overlay: updatedOverlay(commandBuffer),
                        cursor: cursorOverlay, pass: pass, into: commandBuffer)

        // Stats need both the GPU times (completed) and the on-screen time (presented), in either order.
        inFlight.add(1, ordering: .acquiringAndReleasing)
        #if targetEnvironment(simulator)
        // The simulator has neither presented handlers nor timed presents:
        // the GPU finishing the frame stands in for it reaching the screen.
        commandBuffer.addCompletedHandler { [self] cb in
            record?.completed(gpuStart: cb.gpuStartTime, gpuEnd: cb.gpuEndTime)
            record?.presented(cb.gpuEndTime)
            frameLeftQueue()
        }
        commandBuffer.present(drawable)
        #else
        drawable.addPresentedHandler { [self] d in
            record?.presented(d.presentedTime)
            frameLeftQueue()
        }
        if let record {
            commandBuffer.addCompletedHandler { cb in record.completed(gpuStart: cb.gpuStartTime, gpuEnd: cb.gpuEndTime) }
        }
        if let minimumPresentDuration {
            commandBuffer.present(drawable, afterMinimumDuration: minimumPresentDuration)
        } else {
            commandBuffer.present(drawable)
        }
        #endif
        commandBuffer.commit()
        return true
    }
}

extension VideoPresenter {
    /// The overlay texture with what changed in the plane copied in, ahead
    /// of this draw in `commandBuffer`; nil without refinement.
    private func updatedOverlay(_ commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let refinement else { return nil }
        if let upload = refinement.takeUpload(device: renderer.device) {
            if overlayTexture?.width != upload.width || overlayTexture?.height != upload.height {
                // A new size: the upload is the whole plane.
                overlayTexture = renderer.makeOverlayTexture(width: upload.width, height: upload.height)
            }
            if let overlayTexture { renderer.encodeUpload(upload, into: overlayTexture, commandBuffer: commandBuffer) }
        }
        return overlayTexture
    }
}

private final class PresentRecord: Sendable {
    private struct State {
        var presented: CFTimeInterval?
        var gpu: (CFTimeInterval, CFTimeInterval)?
    }

    private let frame: DecodedFrame
    private let zeroCopy: Bool
    private let stats: PlaybackStats
    private let state = Mutex(State())

    init(frame: DecodedFrame, zeroCopy: Bool, stats: PlaybackStats) {
        self.frame = frame
        self.zeroCopy = zeroCopy
        self.stats = stats
    }

    func presented(_ t: CFTimeInterval) { update { $0.presented = t } }
    func completed(gpuStart: CFTimeInterval, gpuEnd: CFTimeInterval) { update { $0.gpu = (gpuStart, gpuEnd) } }

    private func update(_ body: (inout State) -> Void) {
        let done: (CFTimeInterval, CFTimeInterval, CFTimeInterval)? = state.withLock {
            body(&$0)
            guard let p = $0.presented, let g = $0.gpu else { return nil }
            return (p, g.0, g.1)
        }
        if let (p, s, e) = done {
            stats.recordPresented(frame: frame, presentedTime: p, gpuStart: s, gpuEnd: e, zeroCopy: zeroCopy)
        }
    }
}
