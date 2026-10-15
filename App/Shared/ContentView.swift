import SpectreKit
import SwiftUI

/// The login screen or a session.
struct ContentView: View {
    @State private var app = AppModel()

    var body: some View {
        switch app.screen {
        case .login:
            LoginView(app: app)
        case let .session(model):
            SessionView(model: model)
                .id(ObjectIdentifier(model))
        }
    }
}

/// A session (or, from the command line, the prototype's test sources): the
/// video, its statistics, and the session controls.
struct SessionView: View {
    let model: PlaybackModel
    @State private var diagnostics = DiagnosticsModel()
    @State private var showStats: Bool
    @State private var confirmLogOut = false

    init(model: PlaybackModel) {
        self.model = model
        // Over a real desktop the statistics would cover its top-left corner.
        _showStats = State(initialValue: model.showsStatisticsByDefault)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let presenter = model.presenter {
                VideoView(presenter: presenter, input: model.input)
                    #if os(iOS)
                    .ignoresSafeArea()
                    #endif
                    // On the Mac the picture starts below the toolbar: under
                    // it, the remote desktop's top edge (GNOME's top bar) is hidden.
            }
            VStack(alignment: .leading, spacing: 8) {
                #if os(iOS)
                HStack { sessionButtons }
                    .buttonStyle(.bordered)
                    .tint(.white)
                #endif
                if showStats {
                    overlay.allowsHitTesting(false) // clicks on it go to the remote desktop
                }
            }
            .padding(10)
        }
        #if os(macOS)
        .toolbar {
            ToolbarItemGroup { sessionButtons }
            if !model.isRemoteSession {
                ToolbarItemGroup { sourceControls }
            }
        }
        #endif
        .alert("Microphone", isPresented: Binding(get: { model.microphoneError != nil },
                                                  set: { if !$0 { model.microphoneError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.microphoneError ?? "")
        }
        .confirmationDialog("Log out of the remote desktop?", isPresented: $confirmLogOut, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) { model.logOut() }
        } message: {
            Text("This ends the desktop session itself, not just this connection.")
        }
        .task { await model.start() }
        .onDisappear { model.windowClosed() }
        .task { if !model.isRemoteSession { await diagnostics.run() } }
    }

    @ViewBuilder private var sessionButtons: some View {
        if model.isRemoteSession {
            Button { model.disconnect() } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .help("Leave the session running and disconnect")
            Button { confirmLogOut = true } label: {
                Label("Log Out", systemImage: "power")
            }
            .help("End the desktop session")
        }
        if let input = model.input {
            Toggle(isOn: Binding(get: { input.isCaptured }, set: { input.setCaptured($0) })) {
                Label("Capture Mouse", systemImage: input.isCaptured ? "cursorarrow.square.fill" : "cursorarrow.square")
            }
            .help("Capture the mouse for games and 3D views: relative motion, the pointer locked (Ctrl+Cmd+G)")
            #if os(iOS)
            .toggleStyle(.button)
            #endif
        }
        if let clipboard = model.clipboard {
            ClipboardControls(clipboard: clipboard)
        }
        if let gamepads = model.gamepads {
            GamepadControls(gamepads: gamepads)
        }
        #if os(iOS)
        if let input = model.input {
            Button {
                input.touchMode = input.touchMode == .direct ? .trackpad : .direct
            } label: {
                if input.touchMode == .direct {
                    Label("Touch", systemImage: "hand.point.up.left")
                } else {
                    Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left")
                }
            }
            .help("Touch: the pointer goes where you touch. Trackpad: the screen works like a laptop trackpad.")
        }
        #endif
        if model.hasMicrophone {
            Toggle(isOn: Binding(get: { model.isMicrophoneOn }, set: { _ in model.toggleMicrophone() })) {
                Label("Microphone", systemImage: model.isMicrophoneOn ? "mic.fill" : "mic.slash")
            }
            .help(model.isMicrophoneOn
                  ? "Stop sending your microphone"
                  : "Send your microphone to the remote desktop (use headphones, or it hears its own sound)")
            #if os(iOS)
            .toggleStyle(.button)
            #endif
        }
        if model.hasAudio {
            Button { model.isAudioMuted.toggle() } label: {
                if model.isAudioMuted {
                    Label("Unmute", systemImage: "speaker.slash")
                } else {
                    Label("Mute", systemImage: "speaker.wave.2")
                }
            }
            .help(model.isAudioMuted ? "Play the remote desktop's sound" : "Mute the remote desktop's sound on this device")
        }
        Toggle(isOn: $showStats) {
            Label("Statistics", systemImage: "chart.bar.xaxis")
        }
        #if os(iOS)
        .toggleStyle(.button)
        #endif
    }

    @ViewBuilder private var sourceControls: some View {
        @Bindable var model = model
        Picker("Source", selection: $model.source) {
            Text("Loopback").tag(PlaybackModel.Source.loopback)
            Text("Direct").tag(PlaybackModel.Source.direct)
            Text("Remote").tag(PlaybackModel.Source.remote)
        }
        Picker("Codec", selection: $model.codec) {
            ForEach(VideoCodec.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("Pacing", selection: $model.mode) {
            Text("On arrival").tag(VideoPresenter.Mode.onArrival)
            Text("Display link").tag(VideoPresenter.Mode.displayLink)
        }
    }

    @ViewBuilder private var overlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.phase {
            case .idle:
                EmptyView()
            case let .encoding(codec, progress):
                ProgressView("Encoding \(codec.displayName) test stream…", value: progress)
                    .frame(width: 280)
            case let .connecting(target):
                ProgressView("Connecting to \(target)…")
            case .playing:
                Text(model.streamInfo)
                Text(model.statsText)
                if !model.sessionText.isEmpty { Text(model.sessionText) }
            case let .failed(message):
                Text(message).foregroundStyle(.red)
            }
            ForEach(diagnostics.lines, id: \.self) { Text($0) }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Sharing the clipboard with the remote desktop (gdp-spec.md §7.9).
private struct ClipboardControls: View {
    @Bindable var clipboard: ClipboardSync

    var body: some View {
        #if os(macOS)
        Toggle(isOn: $clipboard.isEnabled) {
            Label("Clipboard", systemImage: clipboard.isEnabled ? "doc.on.clipboard.fill" : "doc.on.clipboard")
        }
        .help("Share the clipboard with the remote desktop: text copied on either side can be pasted on the other")
        #else
        Menu {
            Toggle("Share Clipboard", isOn: $clipboard.isEnabled)
            Section("iOS asks before Spectre reads what other apps copied, unless allowed in Settings") {
                Toggle("Send Copies Automatically", isOn: $clipboard.sendsAutomatically)
                    .disabled(!clipboard.isEnabled)
            }
        } label: {
            Label("Clipboard", systemImage: clipboard.isEnabled ? "doc.on.clipboard.fill" : "doc.on.clipboard")
        }
        if clipboard.isEnabled && !clipboard.sendsAutomatically {
            // The system's paste button reads the clipboard without the paste
            // prompt; what it reads goes to the host's clipboard.
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in clipboard.send(text) }
            }
            .help("Send this device's clipboard to the remote desktop")
        }
        #endif
    }
}

/// Forwarding game controllers to the remote desktop (gdp-spec.md §8.5).
private struct GamepadControls: View {
    @Bindable var gamepads: GamepadForwarder

    var body: some View {
        let names = gamepads.slots.sorted { $0.key < $1.key }.map(\.value)
        Toggle(isOn: $gamepads.isEnabled) {
            Label(gamepads.isEnabled && !names.isEmpty ? "Gamepads (\(names.count))" : "Gamepads",
                  systemImage: gamepads.isEnabled ? "gamecontroller.fill" : "gamecontroller")
        }
        .help(names.isEmpty
            ? "Forward game controllers to the remote desktop, up to four"
            : "Forwarding: " + names.joined(separator: ", "))
        #if os(iOS)
        .toggleStyle(.button)
        #endif
    }
}
