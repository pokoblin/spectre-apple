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

    /// Called when ``cursor`` or ``videoSize`` changed: the view updates
    /// its system cursor and pointer mapping.
    @ObservationIgnored public var onDisplayChange: (() -> Void)?

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
    /// `NSCursor`, at no latency, wherever the local pointer is.
    public var drawsCursorOverlay: Bool { false }

    /// Where the overlay cursor goes: where the client put the pointer.
    var overlayPosition: CGPoint? {
        drawsCursorOverlay ? sender.lastPosition : nil
    }

    func updateOverlay() {
        guard let presenter else { return }
        presenter.setCursorImage(drawsCursorOverlay ? cursor : nil)
        presenter.setCursorPosition(overlayPosition)
    }

    // MARK: Keyboard

    public func key(_ usage: UInt32, pressed: Bool) { sender.key(usage, pressed: pressed) }

    /// A lock key reported once per toggle: pressed and released.
    public func tapKey(_ usage: UInt32) { sender.tap(usage) }

    // MARK: Focus

    /// The session view lost the keyboard (another window or app, or a
    /// control in this window took it): nothing may stay held (§8.2).
    public func focusLost() {
        sender.releaseAll()
    }

    /// The session is ending or the view is going away.
    public func end() {
        focusLost()
    }
}
