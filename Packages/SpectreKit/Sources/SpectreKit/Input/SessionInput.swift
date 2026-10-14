import CoreGraphics
import GDPKit
import Observation

/// One session's input: what the platform's session view forwards (through
/// an ``InputSender``) and the state around it that outlives a single event.
/// The views translate platform events; everything here is shared.
@MainActor
@Observable
public final class SessionInput {
    @ObservationIgnored public let sender: InputSender
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
        self.presenter = presenter
    }

    // MARK: Picture and cursor

    /// The picture's size changed (SessionAccept, DisplaysChanged).
    public func pictureChanged(_ size: CGSize) {
        guard size != videoSize else { return }
        videoSize = size
        onDisplayChange?()
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

    /// Captures or releases the mouse (gdp-spec.md §8.2: relative motion
    /// while captured). The platform view does the locking.
    public func setCaptured(_ on: Bool) {
        guard on != isCaptured, captureHandler?(on) ?? false else { return }
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

    public func key(_ usage: UInt32, pressed: Bool) { sender.key(usage, pressed: pressed) }

    /// A lock key reported once per toggle: pressed and released.
    public func tapKey(_ usage: UInt32) { sender.tap(usage) }

    // MARK: Focus

    /// The session view lost the keyboard (another window or app, or a
    /// control in this window took it): nothing may stay held (§8.2).
    public func focusLost() {
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
