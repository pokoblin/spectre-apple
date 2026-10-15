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
public final class IOSSessionView: MTKView, UIPointerInteractionDelegate, UIKeyInput {
    public var input: SessionInput? {
        didSet {
            guard oldValue !== input else { return }
            oldValue?.focusLost()
            oldValue?.captureHandler = nil
            oldValue?.onDisplayChange = nil
            oldValue?.onTouchModeChange = nil
            oldValue?.onTouchKeyboardChange = nil
            oldValue?.showsTouchKeyboard = false
            keyboardBar = nil
            endTouches()
            touchMapper = nil
            input?.captureHandler = { [weak self] on in self?.capture(on) ?? false }
            input?.onDisplayChange = { [weak self] in self?.layoutChanged() }
            input?.onTouchModeChange = { [weak self] in self?.touchModeChanged() }
            input?.onTouchKeyboardChange = { [weak self] in self?.touchKeyboardChanged() }
            if input != nil, window != nil { becomeFirstResponder() }
        }
    }

    /// Pointer buttons held through `.indirectPointer` touches.
    private var heldPointerButtons: Set<UInt32> = []
    private var lastScrollTranslation: CGPoint = .zero
    private var observers: [NSObjectProtocol] = []
    private var mouse: GCMouse?
    private var touchMapper: TouchPointerMapper?
    private var touchDeadline: DispatchWorkItem?

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
        endTouches()
        input?.focusLost()
        return super.resignFirstResponder()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutChanged()
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
            MainActor.assumeIsolated {
                self?.endTouches()
                self?.input?.focusLost()
            }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: window.windowScene,
                               queue: .main, using: lost),
            // The keyboard put away by the system (its own hide key, a hardware
            // keyboard attached): the switch follows.
            center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.input?.showsTouchKeyboard = false }
            },
        ]
        if input != nil { becomeFirstResponder() }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Touch keyboard

    // The touch keyboard comes from adopting UIKeyInput: it shows for a first
    // responder that adopts it, unless `inputView` replaces it. Hardware keys
    // never reach insertText: pressesBegan below takes them and doesn't call
    // super. Everything that would change what was typed is off.
    public var keyboardType: UIKeyboardType = .asciiCapable // the host's input method does CJK
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var inlinePredictionType: UITextInlinePredictionType = .no
    public var keyboardAppearance: UIKeyboardAppearance = .dark

    /// Always: so that Backspace on an "empty" field still reaches the host.
    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        input?.type(text)
        keyboardBar?.refresh()
    }

    public func deleteBackward() {
        input?.typer.press(HIDUsage.deleteOrBackspace)
        keyboardBar?.refresh()
    }

    private let noKeyboard = UIView(frame: .zero)
    private var keyboardBar: TouchKeyboardBar?

    /// Hidden: an empty input view stands in for the keyboard.
    public override var inputView: UIView? { input?.showsTouchKeyboard == true ? nil : noKeyboard }

    public override var inputAccessoryView: UIView? {
        guard let input, input.showsTouchKeyboard else { return nil }
        if keyboardBar == nil {
            keyboardBar = TouchKeyboardBar(typer: input.typer) { [weak input] in input?.showsTouchKeyboard = false }
        }
        return keyboardBar
    }

    private func touchKeyboardChanged() {
        if input?.showsTouchKeyboard == true, !isFirstResponder { becomeFirstResponder() }
        keyboardBar?.refresh()
        reloadInputViews()
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
        fingers(touches, event: event) { $0.began($1, at: $2) }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointerTouches(touches, event: event, ending: false)
        fingers(touches, event: event) { $0.moved($1, at: $2) }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointerTouches(touches, event: event, ending: true)
        fingers(touches, event: event) { $0.ended($1, at: $2) }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pointerTouches(touches, event: event, ending: true)
        fingers(touches, event: event) { $0.cancelled($1, at: $2) }
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

    // MARK: - Fingers

    /// Fingers (and the Pencil) become pointer input through the gesture
    /// mapper: the host ignores TouchEvent (gdp-spec.md §8.3).
    private func fingers(_ touches: Set<UITouch>, event: UIEvent?,
                         _ step: (inout TouchPointerMapper, [TouchPointerMapper.Touch], TimeInterval) -> [TouchPointerAction]) {
        guard let input else { return }
        let direct = touches.filter { $0.type == .direct || $0.type == .pencil }
        guard !direct.isEmpty else { return }
        var mapper = touchMapper ?? TouchPointerMapper(mode: input.touchMode, mapping: mapping)
        let list = direct.map { TouchPointerMapper.Touch(id: ObjectIdentifier($0).hashValue, location: $0.location(in: self)) }
        let actions = step(&mapper, list, event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
        touchMapper = mapper
        perform(actions)
        scheduleTouchDeadline()
    }

    private func perform(_ actions: [TouchPointerAction]) {
        guard let input else { return }
        for action in actions {
            switch action {
            case let .move(p): input.move(to: p)
            case let .button(code, pressed): input.button(code, pressed: pressed)
            case let .scroll(h, v): input.scroll(horizontal: h, vertical: v)
            case .longPress: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    /// The mapper's timers (a long press firing while the finger rests).
    private func scheduleTouchDeadline() {
        touchDeadline?.cancel()
        touchDeadline = nil
        guard let deadline = touchMapper?.nextDeadline else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, var mapper = self.touchMapper else { return }
                let actions = mapper.update(at: ProcessInfo.processInfo.systemUptime)
                self.touchMapper = mapper
                self.perform(actions)
                self.scheduleTouchDeadline()
            }
        }
        touchDeadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(deadline - ProcessInfo.processInfo.systemUptime, 0),
                                      execute: item)
    }

    /// Lets go of whatever the fingers hold (focus lost, mode change).
    private func endTouches() {
        touchDeadline?.cancel()
        touchDeadline = nil
        guard var mapper = touchMapper else { return }
        let actions = mapper.reset()
        touchMapper = mapper
        perform(actions)
    }

    private func touchModeChanged() {
        endTouches()
        guard let input else { return }
        touchMapper?.mode = input.touchMode
        // The trackpad's cursor is the client's to show: put it where the pointer is.
        if input.touchMode == .trackpad, let mapper = touchMapper { input.move(to: mapper.cursor) }
    }

    private func layoutChanged() {
        touchMapper?.mapping = mapping
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
