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

    private weak var view: MTKView?
    private let drawScheduled = Atomic<Bool>(false)

    public init(renderer: VideoRenderer, mailbox: FrameMailbox, stats: PlaybackStats) {
        self.renderer = renderer
        self.mailbox = mailbox
        self.stats = stats
    }

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

    /// Called from any thread when the decoder produced a frame.
    public nonisolated func frameAvailable() {
        // Coalesce: one pending main-thread draw at a time.
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
        guard let frame = mailbox.take() else { return }
        let textures: VideoTextures
        do {
            textures = try renderer.textures(for: frame)
        } catch {
            lastError = String(describing: error)
            return
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "video frame \(frame.sequence)"
        let videoSize = displaySize ?? CGSize(width: textures.luma.width, height: textures.luma.height)
        let viewport = VideoRenderer.fitViewport(video: videoSize, drawable: view.drawableSize)
        renderer.encode(textures, color: color, displaySize: displaySize, viewport: viewport, pass: pass,
                        into: commandBuffer)

        // Stats need both the GPU times (completed) and the on-screen time (presented), in either order.
        let record = PresentRecord(frame: frame, zeroCopy: textures.isZeroCopy, stats: stats)
        #if targetEnvironment(simulator)
        // The simulator has neither presented handlers nor timed presents:
        // the GPU finishing the frame stands in for it reaching the screen.
        commandBuffer.addCompletedHandler { cb in
            record.completed(gpuStart: cb.gpuStartTime, gpuEnd: cb.gpuEndTime)
            record.presented(cb.gpuEndTime)
        }
        commandBuffer.present(drawable)
        #else
        drawable.addPresentedHandler { d in record.presented(d.presentedTime) }
        commandBuffer.addCompletedHandler { cb in record.completed(gpuStart: cb.gpuStartTime, gpuEnd: cb.gpuEndTime) }
        if let minimumPresentDuration {
            commandBuffer.present(drawable, afterMinimumDuration: minimumPresentDuration)
        } else {
            commandBuffer.present(drawable)
        }
        #endif
        commandBuffer.commit()
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
