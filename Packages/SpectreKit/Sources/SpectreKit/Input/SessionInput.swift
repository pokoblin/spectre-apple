import CoreGraphics
import Foundation
import GDPKit
import Observation

/// One session's input: what the platform's session view forwards (through
/// an ``InputSender``) and the state around it that outlives a single event.
/// The views translate platform events; everything here is shared.
@MainActor
@Observable
public final class SessionInput {
    @ObservationIgnored public let sender: InputSender
    /// Characters typed on a keyboard that only gives characters (the touch
    /// keyboard on iOS), with the sticky modifiers that keyboard lacks.
    @ObservationIgnored public let typer: TextTyper
    /// Draws the cursor over the picture when the platform can't (see ``drawsCursorOverlay``).
    @ObservationIgnored public weak var presenter: VideoPresenter?

    /// The host's cursor (gdp-spec.md §7.4); nil until the first shape.
    public private(set) var cursor: CursorImage?
    /// The remote output's size in pixels (§7.2): what the pointer maps onto.
    public private(set) var videoSize: CGSize = .zero
    /// Where the host last reported its pointer (§7.4), 0...1.
    public private(set) var hostPosition: CGPoint?

    /// Whether the mouse is captured: the local pointer locked and hidden,
    /// relative motion sent, the host's cursor drawn where it reports it.
    public private(set) var isCaptured = false

    /// How fingers drive the pointer on a touch screen (``TouchPointerMapper``);
    /// remembered across sessions.
    public var touchMode: TouchPointerMapper.Mode = SessionInput.savedTouchMode {
        didSet {
            UserDefaults.standard.set(touchMode.rawValue, forKey: "touchMode")
            if touchMode != oldValue { onTouchModeChange?() }
        }
    }
    @ObservationIgnored public var onTouchModeChange: (() -> Void)?
    private static var savedTouchMode: TouchPointerMapper.Mode {
        UserDefaults.standard.string(forKey: "touchMode").flatMap(TouchPointerMapper.Mode.init) ?? .trackpad
    }

    /// Scroll units (gdp-spec.md §8.2).
    @ObservationIgnored public var scrollConverter = ScrollConverter()

    /// Called when ``cursor``, ``videoSize`` or ``isCaptured`` changed: the
    /// view updates its system cursor and pointer mapping.
    @ObservationIgnored public var onDisplayChange: (() -> Void)?
    /// The platform's half of capturing: lock and hide the local pointer
    /// (true) or give it back (false). Returns whether it took effect.
    @ObservationIgnored public var captureHandler: ((Bool) -> Bool)?

    public init(sink: InputSink, presenter: VideoPresenter? = nil) {
        sender = InputSender(sink: sink)
        typer = TextTyper(sender: sender)
        self.presenter = presenter
    }

    // MARK: Picture and cursor

    /// The picture's size changed (SessionAccept, DisplaysChanged).
    public func pictureChanged(_ size: CGSize) {
        guard size != videoSize else { return }
        videoSize = size
        if zoom.isZoomed { setZoom(.fit) } // a different picture: start from all of it
        onDisplayChange?()
    }

    // MARK: Magnifying (iOS)

    /// How the picture is magnified in the view (``PictureZoom``): pinched,
    /// or filling the screen. The presenter draws it and the view maps the
    /// pointer through it.
    public private(set) var zoom = PictureZoom.fit
    /// The session view's geometry, unmagnified: what zooming is measured
    /// against. The view keeps it current (``viewChanged(_:)``).
    @ObservationIgnored public private(set) var viewMapping: PointerMapping?
    @ObservationIgnored private var zoomAnimation: Task<Void, Never>?

    /// The view's size or scale changed: a magnified picture goes back to
    /// fitting, as the part in view would no longer be the same.
    public func viewChanged(_ mapping: PointerMapping) {
        var mapping = mapping
        mapping.zoom = .fit
        let old = viewMapping
        viewMapping = mapping
        if let old, old.viewSize != mapping.viewSize || old.backingScale != mapping.backingScale, zoom.isZoomed {
            setZoom(.fit)
        }
    }

    public func setZoom(_ zoom: PictureZoom) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        presenter?.setZoom(zoom)
        onDisplayChange?()
    }

    /// A pinch: the fingers' spread changed by `factor` around `anchor`
    /// and their middle moved by `pan` (view points).
    public func pinch(factor: CGFloat, anchor: CGPoint, pan: CGPoint) {
        zoomAnimation?.cancel()
        guard let m = viewMapping else { return }
        var z = zoom
        z.pan(by: pan, fit: m.fitRect, view: m.viewSize)
        z.zoom(by: factor, anchor: anchor, fit: m.fitRect, view: m.viewSize, maxScale: m.maxZoom)
        setZoom(z)
    }

    /// Moves a magnified picture by `delta` view points (the edges pulling it).
    public func panPicture(by delta: CGPoint) {
        guard zoom.isZoomed, let m = viewMapping else { return }
        var z = zoom
        z.pan(by: delta, fit: m.fitRect, view: m.viewSize)
        setZoom(z)
    }

    /// Fill Screen, or Fit Screen when magnified: filling is centred on
    /// the pointer, and either way the change takes a quarter second.
    public func toggleFill() {
        guard let m = viewMapping else { return }
        if zoom.isZoomed {
            animateZoom(to: .fit)
        } else {
            let at = overlayPosition ?? sender.lastPosition ?? CGPoint(x: 0.5, y: 0.5)
            animateZoom(to: .filling(fit: m.fitRect, view: m.viewSize, at: at, maxScale: m.maxZoom))
        }
    }

    private func animateZoom(to target: PictureZoom, duration: TimeInterval = 0.25) {
        zoomAnimation?.cancel()
        let start = zoom
        let began = ProcessInfo.processInfo.systemUptime
        zoomAnimation = Task { [weak self] in
            while !Task.isCancelled {
                let t = min((ProcessInfo.processInfo.systemUptime - began) / duration, 1)
                let eased = 1 - pow(1 - t, 3) // ease out
                self?.setZoom(t >= 1 ? target : start.interpolated(to: target, eased))
                if t >= 1 { return }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    /// The host sent a CursorShape. One the client must ignore (§7.4) changes nothing.
    public func hostCursorShape(_ shape: GDPSession.CursorShape) {
        guard let image = CursorImage(shape), image != cursor else { return }
        cursor = image
        updateOverlay()
        onDisplayChange?()
    }

    /// The host sent a CursorPosition (only while the client sends relative motion).
    public func hostCursorPosition(_ position: CGPoint) {
        hostPosition = position
        updateOverlay()
    }

    /// Whether the cursor is drawn into the picture rather than left to the
    /// system pointer. On the Mac the system draws the host's image as an
    /// `NSCursor`, at no latency, wherever the local pointer is, except
    /// while captured: then the local pointer is locked and hidden.
    public var drawsCursorOverlay: Bool {
        #if os(macOS)
        isCaptured
        #else
        true
        #endif
    }

    /// Where the overlay cursor goes: where the host says while captured
    /// (only it knows, §7.4), otherwise where the client put the pointer.
    var overlayPosition: CGPoint? {
        guard drawsCursorOverlay else { return nil }
        return isCaptured ? hostPosition ?? sender.lastPosition : sender.lastPosition
    }

    func updateOverlay() {
        guard let presenter else { return }
        presenter.setCursorImage(drawsCursorOverlay ? cursor : nil)
        presenter.setCursorPosition(overlayPosition)
    }

    // MARK: Pointer

    /// Moves the pointer to a position on the output (0...1): absolute motion.
    public func move(to position: CGPoint) {
        sender.move(to: position)
        if drawsCursorOverlay { updateOverlay() }
    }

    /// Moves the pointer by output pixels: relative motion, while captured.
    public func move(by dx: Double, _ dy: Double) {
        sender.move(by: dx, dy)
    }

    public func button(_ code: UInt32, pressed: Bool) { sender.button(code, pressed: pressed) }

    /// A platform scroll event's deltas (content movement, see ``ScrollConverter``).
    public func scroll(deltaX: Double, deltaY: Double, precise: Bool) {
        let n = scrollConverter.notches(deltaX: deltaX, deltaY: deltaY, precise: precise)
        sender.scroll(horizontal: n.horizontal, vertical: n.vertical)
    }

    /// Scrolls by notches, positive right and down (§8.2).
    public func scroll(horizontal: Double, vertical: Double) {
        sender.scroll(horizontal: horizontal, vertical: vertical)
    }

    /// Captures or releases the mouse (gdp-spec.md §8.2: relative motion
    /// while captured). The platform view does the locking.
    public func setCaptured(_ on: Bool) {
        guard on != isCaptured else { return }
        // A button held through one source would never see its release from the other.
        sender.releaseButtons()
        guard captureHandler?(on) ?? false else { return }
        isCaptured = on
        if on {
            // Until the host reports a position, its pointer is where the last absolute motion put it.
            hostPosition = nil
        } else {
            // Relative motion moved the host's pointer: the next absolute motion must be sent.
            sender.forgetPosition()
        }
        updateOverlay()
        onDisplayChange?()
    }

    public func toggleCapture() { setCaptured(!isCaptured) }

    // MARK: Keyboard

    /// A hardware key. Letting go of one that isn't a modifier ends the
    /// key bar's locked modifiers, as a key typed on the touch keyboard does.
    public func key(_ usage: UInt32, pressed: Bool) {
        sender.key(usage, pressed: pressed)
        guard !pressed else { return }
        if HIDUsage.isModifier(usage) {
            typer.hostReleased(usage)
        } else {
            typer.releaseModifiers()
        }
    }

    /// A lock key reported once per toggle: pressed and released.
    public func tapKey(_ usage: UInt32) { sender.tap(usage) }

    // MARK: Touch keyboard

    /// Characters the host's layout has no key for, last time some were
    /// skipped; `serial` tells repeats apart, so the UI can show each one.
    public struct Untypable: Equatable, Sendable {
        public var count: Int
        public var serial: Int
    }

    /// Whether the touch keyboard is up (iOS). The view shows or hides it.
    public var showsTouchKeyboard = false {
        didSet {
            // Locked modifiers stay: the key bar on the screen shows them too.
            guard showsTouchKeyboard != oldValue else { return }
            onTouchKeyboardChange?()
        }
    }
    @ObservationIgnored public var onTouchKeyboardChange: (() -> Void)?
    /// A finger, a click or a pen came down on the picture (iOS): the app
    /// puts away controls it opened by itself.
    @ObservationIgnored public var onPictureTouch: (() -> Void)?
    public private(set) var untypable: Untypable?

    /// Text from the touch keyboard (or dictation): typed as key strokes on
    /// the host's layout, skipping what it can't type.
    public func type(_ text: String) {
        let skipped = typer.type(text)
        if skipped > 0 { untypable = Untypable(count: skipped, serial: (untypable?.serial ?? 0) + 1) }
    }

    // MARK: Focus

    /// The session view lost the keyboard (another window or app, or a
    /// control in this window took it): nothing may stay held (§8.2).
    public func focusLost() {
        typer.releaseModifiers()
        sender.releaseAll()
        setCaptured(false)
    }

    /// The session is ending or the view is going away.
    public func end() {
        focusLost()
        presenter?.setCursorImage(nil)
        presenter?.setCursorPosition(nil)
        presenter = nil
    }
}
