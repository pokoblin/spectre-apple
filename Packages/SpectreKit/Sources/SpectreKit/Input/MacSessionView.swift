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
            if oldValue !== input { oldValue?.focusLost() }
        }
    }

    private var keyMonitor: Any?
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

    // MARK: - Keyboard

    private func handlesKeys(for event: NSEvent) -> Bool {
        guard input != nil, let window, event.window === window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    /// Returns whether the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let input else { return false }
        switch event.type {
        case .keyDown:
            if let shortcut = localShortcut(event) {
                return perform(shortcut, event: event)
            }
            // The host's compositor repeats held keys itself.
            if !event.isARepeat, let usage = usage(event) { input.key(usage, pressed: true) }
            return true
        case .keyUp:
            if let usage = usage(event) { input.key(usage, pressed: false) }
            return true
        case .flagsChanged:
            guard let usage = usage(event) else { return true }
            if usage == HIDUsage.capsLock {
                // One event per toggle, not per press and release.
                input.tapKey(usage)
            } else if let mask = MacKeyCodes.deviceFlagMask(forKeyCode: event.keyCode) {
                input.key(usage, pressed: event.modifierFlags.rawValue & mask != 0)
            }
            return true
        default:
            return false
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
