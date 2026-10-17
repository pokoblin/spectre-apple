import SpectreKit
import SwiftUI

/// What the controls floating over a session show (docs/ipad-layout.md):
/// for now, whether the session toolbar in the bottom-left corner is open.
///
/// The toolbar opens by itself once the session is connected, and closes
/// by itself 4 seconds later, or as soon as a finger works the remote
/// desktop, unless a control was touched by then: from that touch on it
/// only closes with its toggle, so a menu being read is never put away.
@MainActor
@Observable
final class SessionChrome {
    private(set) var isToolbarExpanded = false
    @ObservationIgnored private var autoCollapse: Task<Void, Never>?
    @ObservationIgnored private var keepsOpen = false
    @ObservationIgnored private var hasConnected = false

    static let autoCollapseDelay: Duration = .seconds(4)

    /// The session is connected (its first picture, not a reconnect's).
    func connected() {
        guard !hasConnected else { return }
        hasConnected = true
        withAnimation(FloatingKeyBar.animation) { isToolbarExpanded = true }
        autoCollapse = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.autoCollapseDelay)) != nil else { return }
            self?.collapseAutomatically()
        }
    }

    func pictureTouched() { collapseAutomatically() }

    /// A control of the toolbar was touched: it stays as the user leaves it.
    func controlTouched() {
        keepsOpen = true
        autoCollapse?.cancel()
    }

    func toggleToolbar() {
        controlTouched()
        withAnimation(FloatingKeyBar.animation) { isToolbarExpanded.toggle() }
    }

    private func collapseAutomatically() {
        autoCollapse?.cancel()
        guard !keepsOpen, isToolbarExpanded else { return }
        withAnimation(FloatingKeyBar.animation) { isToolbarExpanded = false }
    }
}

// MARK: - Bottom-left: the session toolbar

/// The round toggle in the bottom-left corner and, to its right, the bar
/// it opens: More, paste to the host, the touch keyboard, the region alert,
/// and the file transfers once there are some.
struct SessionToolbar: View {
    let model: PlaybackModel
    let chrome: SessionChrome
    let keyBar: KeyBarModel
    let regions: RegionAlertModel
    @Binding var showsStatistics: Bool
    /// Opens the file picker (Send Files…).
    let sendFiles: () -> Void
    let confirmLogOut: () -> Void
    @State private var toggleEdge: CGFloat = 0
    @State private var barEdge: CGFloat = 0

    var body: some View {
        HStack(spacing: FloatingKeyBar.spacing) {
            FloatingToggle(symbol: "line.3.horizontal", isExpanded: chrome.isToolbarExpanded,
                           accessibilityLabel: chrome.isToolbarExpanded ? Text("Close Toolbar") : Text("Open Toolbar"),
                           action: chrome.toggleToolbar)
                .overlay(alignment: .topTrailing) { RegionStatusBadge(state: regions.state) }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { toggleEdge = $0 }
            bar
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { barEdge = $0 }
                .capsuleReveal(chrome.isToolbarExpanded, from: .leading)
        }
        .padding(FloatingKeyBar.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // The key bar's row, coming from the right, stops short of this.
        .onChange(of: chrome.isToolbarExpanded ? barEdge : toggleEdge, initial: true) { _, edge in
            keyBar.leadingObstruction = edge
        }
    }

    private var bar: some View {
        HStack(spacing: FloatingKeyBar.keySpacing) {
            SessionMoreMenu(model: model, keyBar: keyBar, showsStatistics: $showsStatistics,
                            sendFiles: sendFiles, confirmLogOut: confirmLogOut)
            if let clipboard = model.clipboard, clipboard.isEnabled {
                // The system's paste button reads the clipboard without the
                // paste prompt; what it reads goes to the host's clipboard.
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in clipboard.send(text) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .tint(.white.opacity(0.15))
                .accessibilityLabel("Send Clipboard to Host")
            }
            if let input = model.input {
                KeyboardKey(input: input)
            }
            RegionAlertKey(regions: regions)
            if !model.files.items.isEmpty {
                TransfersKey(files: model.files, sendFiles: sendFiles)
            }
        }
        .padding(FloatingKeyBar.barPadding)
        .glassEffect(.regular, in: .capsule)
        .dynamicTypeSize(...FloatingKeyBar.maxTypeSize)
        // Menus and the paste button are UIKit underneath: a touch on any of
        // them still reaches this.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in chrome.controlTouched() })
    }
}

/// Shows or hides the touch keyboard; lit while it is up.
private struct KeyboardKey: View {
    let input: SessionInput

    var body: some View {
        Button {
            input.showsTouchKeyboard.toggle()
        } label: {
            Image(systemName: input.showsTouchKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
        }
        .buttonStyle(KeyCapStyle(isLit: input.showsTouchKeyboard))
        .accessibilityLabel(input.showsTouchKeyboard ? Text("Hide Keyboard") : Text("Show Keyboard"))
    }
}

/// The files sent to and downloaded from the host (gdp-spec.md §7.12): a
/// ring of how far they have got while some are going, their list in a
/// popover.
private struct TransfersKey: View {
    let files: FileTransfers
    let sendFiles: () -> Void
    @State private var showsList = false

    var body: some View {
        Button {
            showsList.toggle()
        } label: {
            if files.hasActive {
                ProgressView(value: files.activeFraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "list.bullet")
            }
        }
        .buttonStyle(KeyCapStyle(isLit: showsList))
        .accessibilityLabel("Transfers")
        .popover(isPresented: $showsList) {
            FileTransferList(files: files) {
                showsList = false
                // The picker can't come up while the popover is still going away.
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    sendFiles()
                }
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - More

/// Everything else the session offers, in groups: the picture, the
/// clipboard, input, sound, and logging out.
struct SessionMoreMenu: View {
    @Bindable var model: PlaybackModel
    @Bindable var keyBar: KeyBarModel
    @Binding var showsStatistics: Bool
    let sendFiles: () -> Void
    let confirmLogOut: () -> Void

    var body: some View {
        Menu {
            // Fill Screen / Fit Screen is only in the menu bar's Session menu,
            // for a keyboard and trackpad: fingers pinch, and it was little used here.
            Section("Display") {
                if model.isRemoteSession {
                    Toggle(isOn: $model.matchesWindowSize) {
                        Label("Match Window Size", systemImage: "aspectratio")
                    }
                }
                Toggle(isOn: $keyBar.isShown) {
                    Label("Show Key Bar", systemImage: "keyboard")
                }
                Toggle(isOn: $showsStatistics) {
                    Label("Performance", systemImage: "gauge.with.dots.needle.33percent")
                }
            }
            if model.hasRefinement {
                Section("Exact text and lines on a still screen, at more work for the host") {
                    Toggle(isOn: $model.isRefinementOn) {
                        Label("Lossless Refinement", systemImage: "sparkles")
                    }
                }
            }
            if model.isRemoteSession {
                Section("Sharper on Retina screens, at up to four times the work for the host") {
                    Toggle(isOn: Binding(get: { model.resolutionUnits == .pixels },
                                         set: { model.resolutionUnits = $0 ? .pixels : .points })) {
                        Label("Retina Resolution", systemImage: "sparkles.rectangle.stack")
                    }
                    .disabled(!model.matchesWindowSize)
                }
            }
            if let clipboard = model.clipboard {
                ClipboardSection(clipboard: clipboard)
            }
            if model.files.isAvailable {
                Section("Files") {
                    Button(action: sendFiles) {
                        Label("Send Files…", systemImage: "arrow.up.doc")
                    }
                    if let copied = model.copiedFiles, !copied.downloadable.isEmpty {
                        Button(action: model.downloadCopiedFiles) {
                            Label("Download Copied Files", systemImage: "arrow.down.doc")
                        }
                    }
                }
            }
            if let voice = keyBar.voice {
                VoiceInputSection(voice: voice)
            }
            if let input = model.input {
                InputSection(input: input, gamepads: model.gamepads)
            }
            if model.hasAudio || model.hasMicrophone {
                Section("Sound") {
                    if model.hasAudio {
                        Toggle(isOn: $model.isAudioMuted) {
                            Label("Mute", systemImage: "speaker.slash")
                        }
                    }
                    if model.hasMicrophone {
                        Toggle(isOn: Binding(get: { model.isMicrophoneOn }, set: { _ in model.toggleMicrophone() })) {
                            Label("Microphone", systemImage: "mic")
                        }
                    }
                }
            }
            if model.isRemoteSession {
                Section {
                    Button(role: .destructive, action: confirmLogOut) {
                        Label("Log Out…", systemImage: "power")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .keyCap()
        }
        .menuIndicator(.hidden)
        .tint(.primary)
        .accessibilityLabel("More")
    }
}

private struct ClipboardSection: View {
    @Bindable var clipboard: ClipboardSync

    var body: some View {
        Section("Clipboard") {
            Toggle(isOn: $clipboard.isEnabled) {
                Label("Share Clipboard", systemImage: "doc.on.clipboard")
            }
        }
        Section("iOS asks before Spectre reads what other apps copied, unless allowed in Settings") {
            Toggle(isOn: $clipboard.sendsAutomatically) {
                Label("Send Copies Automatically", systemImage: "arrow.up.doc.on.clipboard")
            }
            .disabled(!clipboard.isEnabled)
        }
    }
}

private struct InputSection: View {
    @Bindable var input: SessionInput
    let gamepads: GamepadForwarder?

    var body: some View {
        Section("Input") {
            Picker(selection: $input.touchMode) {
                Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left")
                    .tag(TouchPointerMapper.Mode.trackpad)
                Label("Touch", systemImage: "hand.point.up.left")
                    .tag(TouchPointerMapper.Mode.direct)
            } label: {
                Label("Input Mode", systemImage: input.touchMode == .direct ? "hand.point.up.left"
                                                                            : "rectangle.and.hand.point.up.left")
            }
            .pickerStyle(.menu)
            Toggle(isOn: Binding(get: { input.isCaptured }, set: { input.setCaptured($0) })) {
                Label("Capture Mouse", systemImage: "cursorarrow.square")
            }
            if let gamepads {
                GamepadToggle(gamepads: gamepads)
            }
        }
    }
}

private struct GamepadToggle: View {
    @Bindable var gamepads: GamepadForwarder

    var body: some View {
        Toggle(isOn: $gamepads.isEnabled) {
            Label(gamepads.isEnabled && !gamepads.slots.isEmpty ? "Gamepads (\(gamepads.slots.count))" : "Gamepads",
                  systemImage: "gamecontroller")
        }
    }
}

// MARK: - Top-left

/// Back to the login screen: disconnects (the remote session keeps
/// running). Shown while the toolbar is open.
struct SessionBackButton: View {
    let title: String
    let disconnect: () -> Void

    var body: some View {
        Button(action: disconnect) {
            Label(title, systemImage: "chevron.backward")
                .font(.headline)
                .lineLimit(1)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityLabel("Disconnect from \(title)")
    }
}
