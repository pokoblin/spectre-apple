#if os(macOS)
import AppKit
import MetalKit

/// The video view on macOS, which also takes the session's keyboard and
/// mouse and hands them to a ``SessionInput``.
///
/// Keys are caught by a local event monitor rather than `keyDown(with:)`:
/// AppKit never delivers the key-up of a key pressed with Cmd held to a
/// view, and Cmd combinations would otherwise go to the menu first. The
/// monitor acts only while this view is the key window's first responder,
/// so a text field elsewhere in the window types normally.
public final class MacSessionView: MTKView {
    public var input: SessionInput? {
        didSet {
            guard oldValue !== input else { return }
            oldValue?.focusLost()
            oldValue?.onDisplayChange = nil
            oldValue?.captureHandler = nil
            input?.onDisplayChange = { [weak self] in self?.displayChanged() }
            input?.captureHandler = { [weak self] on in self?.capture(on) ?? false }
            displayChanged()
        }
    }

    /// The host's cursor as an NSCursor, for the image and scale it was made for.
    private var systemCursor: (image: CursorImage, scale: CGFloat, cursor: NSCursor)?

    private var keyMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []

    public override var acceptsFirstResponder: Bool { input != nil }

    public override func resignFirstResponder() -> Bool {
        input?.focusLost()
        return super.resignFirstResponder()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitors()
        guard let window else {
            input?.end()
            return
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            // Local monitors run on the main thread, inside sendEvent.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated {
                guard let self, self.handlesKeys(for: event) else { return false }
                return self.handleKey(event)
            }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        let lost: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.input?.focusLost() }
        }
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: lost),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main,
                               using: lost),
        ]
        DispatchQueue.main.async { [weak self] in
            guard let self, input != nil else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    isolated deinit {
        removeMonitors()
    }

    // MARK: - Picture and cursor

    /// Where the picture is in this view, as the renderer letterboxes it.
    var mapping: PointerMapping {
        PointerMapping(viewSize: bounds.size, backingScale: window?.backingScaleFactor ?? 2,
                       videoSize: input?.videoSize ?? .zero)
    }

    /// The picture's rectangle in this (unflipped) view's coordinates.
    private var videoRectInView: NSRect {
        let r = mapping.videoRect
        return NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    private func displayChanged() {
        window?.invalidateCursorRects(for: self)
        // Cursor rects are re-evaluated when the pointer moves; a new shape
        // under a still pointer is set here.
        if let window, window.isKeyWindow, let cursor = currentSystemCursor() {
            let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if videoRectInView.contains(p) { cursor.set() }
        }
    }

    /// The host's cursor over the picture (§7.4: the host never draws it into
    /// the video), scaled with the picture; the arrow over the bars.
    public override func resetCursorRects() {
        guard let cursor = currentSystemCursor() else { return }
        addCursorRect(videoRectInView, cursor: cursor)
    }

    private func currentSystemCursor() -> NSCursor? {
        guard let input, let image = input.cursor, !input.drawsCursorOverlay else { return nil }
        let scale = mapping.pointsPerVideoPixel
        if let c = systemCursor, c.image == image, c.scale == scale { return c.cursor }
        let cursor = image.nsCursor(pointsPerPixel: scale)
        systemCursor = (image, scale, cursor)
        return cursor
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Mouse

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { input != nil }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    public override func mouseDragged(with event: NSEvent) { pointerMoved(event) }
    public override func rightMouseDragged(with event: NSEvent) { pointerMoved(event) }
    public override func otherMouseDragged(with event: NSEvent) { pointerMoved(event) }

    public override func mouseDown(with event: NSEvent) { pointerButton(event, pressed: true) }
    public override func mouseUp(with event: NSEvent) { pointerButton(event, pressed: false) }
    public override func rightMouseDown(with event: NSEvent) { pointerButton(event, pressed: true) }
    public override func rightMouseUp(with event: NSEvent) { pointerButton(event, pressed: false) }
    public override func otherMouseDown(with event: NSEvent) { pointerButton(event, pressed: true) }
    public override func otherMouseUp(with event: NSEvent) { pointerButton(event, pressed: false) }

    public override func scrollWheel(with event: NSEvent) {
        InputTrace.log(String(format: "scrollWheel scrolling %+.3f, %+.3f delta %+.3f, %+.3f precise %d phase %lu momentum %lu",
                              event.scrollingDeltaX, event.scrollingDeltaY, event.deltaX, event.deltaY,
                              event.hasPreciseScrollingDeltas ? 1 : 0, event.phase.rawValue, event.momentumPhase.rawValue))
        guard let input else { return super.scrollWheel(with: event) }
        if window?.firstResponder === self { syncModifiers(event, changedKeyCode: nil) } // Ctrl+wheel zooms
        // Momentum (the glide after a trackpad flick) is forwarded too: the host applies none of its own.
        input.scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                     precise: event.hasPreciseScrollingDeltas)
    }

    private func pointerMoved(_ event: NSEvent) {
        guard let input else { return }
        if input.isCaptured {
            // Points of mouse travel as output pixels at the picture's scale,
            // so the remote cursor keeps up with the hand as the local one would.
            let scale = mapping.pointsPerVideoPixel
            input.move(by: event.deltaX / scale, event.deltaY / scale)
        } else {
            input.move(to: position(of: event))
        }
    }

    private func pointerButton(_ event: NSEvent, pressed: Bool) {
        InputTrace.log("mouse button \(event.buttonNumber) \(pressed ? "down" : "up") clicks \(event.clickCount)")
        guard let input, let code = PointerButton.code(forButtonNumber: event.buttonNumber) else { return }
        if pressed, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if window?.firstResponder === self { syncModifiers(event, changedKeyCode: nil) } // Ctrl+click, Super+drag
        if !input.isCaptured { input.move(to: position(of: event)) }
        input.button(code, pressed: pressed)
    }

    /// The event's position on the output, clamped to the picture.
    private func position(of event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return mapping.normalized(CGPoint(x: p.x, y: bounds.height - p.y)).position
    }

    /// Locks the local pointer (hidden, disconnected from the mouse, so
    /// moves arrive as deltas and clicks stay in this window) or frees it
    /// where the host's pointer is.
    private func capture(_ on: Bool) -> Bool {
        if on {
            guard let window, window.isKeyWindow else { return false }
            warpPointer(to: mapping.viewPoint(input?.sender.lastPosition ?? CGPoint(x: 0.5, y: 0.5)))
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            if let p = input?.hostPosition ?? input?.sender.lastPosition { warpPointer(to: mapping.viewPoint(p)) }
            NSCursor.unhide()
        }
        return true
    }

    /// Moves the local pointer to a point in this view (top-left origin).
    private func warpPointer(to point: CGPoint) {
        guard let window, let screen = window.screen ?? NSScreen.screens.first else { return }
        let inWindow = convert(NSPoint(x: point.x, y: bounds.height - point.y), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        // Quartz display space: top-left of the primary display, y down.
        let primary = NSScreen.screens.first?.frame ?? screen.frame
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primary.maxY - onScreen.y))
    }

    // MARK: - Keyboard

    private func handlesKeys(for event: NSEvent) -> Bool {
        guard input != nil, let window, event.window === window else { return false }
        let handles = window.isKeyWindow && window.firstResponder === self
        if !handles {
            InputTrace.log("key event not taken: key window \(window.isKeyWindow), first responder \(String(describing: window.firstResponder))")
        }
        return handles
    }

    /// Returns whether the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        InputTrace.log(String(format: "%@ keyCode %d flags 0x%08lX repeat %d chars %@",
                              event.type == .flagsChanged ? "flagsChanged" : event.type == .keyDown ? "keyDown" : "keyUp",
                              event.keyCode, event.modifierFlags.rawValue,
                              event.type == .flagsChanged ? 0 : (event.isARepeat ? 1 : 0),
                              event.type == .flagsChanged ? "-" : (event.charactersIgnoringModifiers ?? "?")))
        guard let input else { return false }
        switch event.type {
        case .keyDown:
            syncModifiers(event, changedKeyCode: nil)
            if let shortcut = localShortcut(event) {
                return perform(shortcut, event: event)
            }
            // The host's compositor repeats held keys itself.
            if !event.isARepeat, let usage = usage(event) { input.key(usage, pressed: true) }
            return true
        case .keyUp:
            syncModifiers(event, changedKeyCode: nil)
            if let usage = usage(event) { input.key(usage, pressed: false) }
            return true
        case .flagsChanged:
            if usage(event) == HIDUsage.capsLock {
                // One event per toggle, not per press and release.
                input.tapKey(HIDUsage.capsLock)
            } else {
                syncModifiers(event, changedKeyCode: event.keyCode)
            }
            return true
        default:
            return false
        }
    }

    /// Brings the host's modifiers in line with the event's flags (see
    /// ``MacKeyCodes/modifierStates(flags:changedKeyCode:held:)``).
    private func syncModifiers(_ event: NSEvent, changedKeyCode: UInt16?) {
        guard let input else { return }
        for m in MacKeyCodes.modifierStates(flags: event.modifierFlags.rawValue, changedKeyCode: changedKeyCode,
                                            held: input.sender.heldKeys) {
            input.key(m.usage, pressed: m.pressed)
        }
    }

    private func usage(_ event: NSEvent) -> UInt32? {
        MacKeyCodes.hidUsage(forKeyCode: event.keyCode, isISO: MacKeyCodes.currentKeyboardIsISO)
    }

    private func localShortcut(_ event: NSEvent) -> LocalShortcut? {
        let flags = event.modifierFlags
        var modifiers: LocalShortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        guard !modifiers.isEmpty, let character = event.charactersIgnoringModifiers else { return nil }
        return LocalShortcut.match(character: character, modifiers: modifiers)
    }

    private func perform(_ shortcut: LocalShortcut, event: NSEvent) -> Bool {
        switch shortcut {
        case .toggleCapture:
            input?.toggleCapture()
            return true
        case .toggleFullScreen:
            input?.focusLost()
            window?.toggleFullScreen(nil)
            return true
        case .quit:
            input?.focusLost()
            return false // to the app menu
        }
    }
}
#endif
