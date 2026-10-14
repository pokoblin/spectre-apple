#if os(iOS)
import GameController
import MetalKit
import UIKit

/// The view controller that can lock the pointer: the window's root (the
/// system asks no other, see the app's AppDelegate).
@MainActor
public protocol PointerLockHost: UIViewController {
    var wantsPointerLock: Bool { get set }
}

/// The video view on iOS and iPadOS, which also takes the session's input
/// and hands it to a ``SessionInput``:
///
/// - a hardware keyboard: `UIKey.keyCode` already is the HID usage (§8.2);
/// - an iPad trackpad or mouse: hover moves the pointer (absolute), clicks
///   arrive as `.indirectPointer` touches with their buttons, scrolling as
///   a scroll-only pan; captured, the pointer is locked and GCMouse gives
///   the deltas and buttons;
/// - fingers: see ``TouchPointerMapper``.
///
/// The system pointer is hidden over the picture: iPadOS can't show a
/// bitmap pointer, so the host's cursor is drawn by the presenter.
public final class IOSSessionView: MTKView, UIPointerInteractionDelegate {
    public var input: SessionInput? {
        didSet {
            guard oldValue !== input else { return }
            oldValue?.focusLost()
            oldValue?.captureHandler = nil
            input?.captureHandler = { [weak self] on in self?.capture(on) ?? false }
            if input != nil, window != nil { becomeFirstResponder() }
        }
    }

    /// Pointer buttons held through `.indirectPointer` touches.
    private var heldPointerButtons: Set<UInt32> = []
    private var lastScrollTranslation: CGPoint = .zero
    private var observers: [NSObjectProtocol] = []
    private var mouse: GCMouse?

    public override init(frame: CGRect, device: (any MTLDevice)?) {
        super.init(frame: frame, device: device)
        setUp()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        isMultipleTouchEnabled = true
        addInteraction(UIPointerInteraction(delegate: self))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = [] // trackpad and wheel scrolling only; fingers are touches
        addGestureRecognizer(scroll)
    }

    // MARK: - Focus

    public override var canBecomeFirstResponder: Bool { input != nil }

    public override func resignFirstResponder() -> Bool {
        input?.focusLost()
        return super.resignFirstResponder()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else {
            input?.end()
            return
        }
        let lost: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.input?.focusLost() }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: window.windowScene,
                               queue: .main, using: lost),
        ]
        if input != nil { becomeFirstResponder() }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Keyboard

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let input else { return super.pressesBegan(presses, with: event) }
        for press in presses {
            guard let key = press.key else { continue }
            if isCaptureShortcut(key) {
                input.toggleCapture()
                continue
            }
            input.key(UInt32(key.keyCode.rawValue), pressed: true)
        }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let input else { return super.pressesEnded(presses, with: event) }
        for press in presses {
            guard let key = press.key else { continue }
            input.key(UInt32(key.keyCode.rawValue), pressed: false)
        }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    /// Ctrl+Cmd+G, as on the Mac. The Mac's other local shortcuts (full
    /// screen, quit) mean nothing here and go to the remote desktop.
    private func isCaptureShortcut(_ key: UIKey) -> Bool {
        var modifiers: LocalShortcut.Modifiers = []
        if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
        if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
        return LocalShortcut.match(character: key.charactersIgnoringModifiers, modifiers: modifiers) == .toggleCapture
    }

    // MARK: - Pointer (trackpad, mouse)

    /// Where the picture is in this view.
    var mapping: PointerMapping {
        PointerMapping(viewSize: bounds.size, backingScale: contentScaleFactor, videoSize: input?.videoSize ?? .zero)
    }

    private func position(_ point: CGPoint) -> CGPoint { mapping.normalized(point).position }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard let input, !input.isCaptured else { return }
        switch g.state {
        case .began, .changed: input.move(to: position(g.location(in: self)))
        default: break
        }
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        guard let input else { return }
        switch g.state {
        case .began:
            lastScrollTranslation = .zero
            fallthrough
        case .changed:
            // Like AppKit's scrolling deltas: the content's movement, natural scrolling applied.
            let t = g.translation(in: self)
            input.scroll(deltaX: t.x - lastScrollTranslation.x, deltaY: t.y - lastScrollTranslation.y, precise: true)
            lastScrollTranslation = t
        default:
            lastScrollTranslation = .zero
        }
    }

    public func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        input == nil ? nil : .hidden()
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if input != nil, !isFirstResponder { becomeFirstResponder() }
        pointerTouches(touches, event: event, ending: false)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointerTouches(touches, event: event, ending: false)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointerTouches(touches, event: event, ending: true)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointerTouches(touches, event: event, ending: true)
    }

    /// A trackpad or mouse click is one `.indirectPointer` touch whose
    /// event carries the buttons held; this follows the mask.
    private func pointerTouches(_ touches: Set<UITouch>, event: UIEvent?, ending: Bool) {
        guard let input, let touch = touches.first(where: { $0.type == .indirectPointer }) else { return }
        // Captured, GCMouse reports the buttons; the locked pointer's touches would double them.
        guard !input.isCaptured else { return }
        input.move(to: position(touch.location(in: self)))
        var buttons: Set<UInt32> = []
        if !ending, let mask = event?.buttonMask {
            for n in 0..<8 where mask.contains(.button(n + 1)) {
                if let code = PointerButton.code(forButtonNumber: n) { buttons.insert(code) }
            }
        }
        for code in heldPointerButtons.subtracting(buttons).sorted() { input.button(code, pressed: false) }
        for code in buttons.subtracting(heldPointerButtons).sorted() { input.button(code, pressed: true) }
        heldPointerButtons = buttons
    }

    // MARK: - Capture

    /// Locks the pointer (through the root view controller) and takes
    /// motion and buttons from GCMouse, which reports raw deltas.
    private func capture(_ on: Bool) -> Bool {
        guard let host = window?.rootViewController as? PointerLockHost else { return false }
        if on {
            guard let mouse = GCMouse.current else { return false }
            for code in heldPointerButtons.sorted() { input?.button(code, pressed: false) }
            heldPointerButtons = []
            attach(mouse)
        } else {
            detachMouse()
        }
        host.wantsPointerLock = on
        return true
    }

    private func attach(_ mouse: GCMouse) {
        self.mouse = mouse
        guard let m = mouse.mouseInput else { return }
        m.mouseMovedHandler = { [weak self] _, dx, dy in
            MainActor.assumeIsolated {
                guard let self, let input = self.input, input.isCaptured else { return }
                // GameController's y is up-positive; §8.2's is down. Points of
                // travel as output pixels at the picture's scale, as on the Mac.
                let scale = self.mapping.pointsPerVideoPixel
                input.move(by: Double(dx) / scale, Double(-dy) / scale)
            }
        }
        let buttons: [(GCControllerButtonInput?, UInt32)] = [
            (m.leftButton, PointerButton.left), (m.rightButton, PointerButton.right),
            (m.middleButton, PointerButton.middle),
        ] + (m.auxiliaryButtons ?? []).enumerated().compactMap { i, b in
            PointerButton.code(forButtonNumber: 3 + i).map { (b, $0) }
        }
        for (button, code) in buttons {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated {
                    guard let input = self?.input, input.isCaptured else { return }
                    input.button(code, pressed: pressed)
                }
            }
        }
    }

    private func detachMouse() {
        guard let m = mouse?.mouseInput else { return }
        m.mouseMovedHandler = nil
        m.leftButton.pressedChangedHandler = nil
        m.rightButton?.pressedChangedHandler = nil
        m.middleButton?.pressedChangedHandler = nil
        m.auxiliaryButtons?.forEach { $0.pressedChangedHandler = nil }
        mouse = nil
    }
}
#endif
