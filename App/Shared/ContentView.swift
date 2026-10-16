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
    @State private var viewSize: CGSize = .zero
    @Environment(\.displayScale) private var displayScale
    #if os(iOS)
    @State private var chrome = SessionChrome()
    @State private var keyBar = KeyBarModel()
    #endif

    init(model: PlaybackModel) {
        self.model = model
        // Over a real desktop the statistics would cover its top-left corner.
        _showStats = State(initialValue: model.showsStatisticsByDefault)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
                #if os(iOS)
                // The remote desktop is kept the size of the whole screen
                // area, not of what the touch keyboard leaves (that would
                // resize it each time the keyboard shows). The proxy's size
                // leaves out the safe area even here; its insets add it back.
                .onGeometryChange(for: CGSize.self) { proxy in
                    let insets = proxy.safeAreaInsets
                    return CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                                  height: proxy.size.height + insets.top + insets.bottom)
                } action: { viewSize = $0 }
                #endif
            if let presenter = model.presenter {
                #if os(iOS)
                // Edge to edge, except where the touch keyboard is: the
                // picture shrinks to fit above it, so nothing is hidden.
                // The key bar of the bottom-right corner is part of it.
                RemoteScreen(presenter: presenter, input: model.input, keyBar: keyBar)
                    .ignoresSafeArea(.container)
                #else
                VideoView(presenter: presenter, input: model.input)
                    // On the Mac the picture starts below the toolbar: under
                    // it, the remote desktop's top edge (GNOME's top bar) is hidden.
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
                #endif
            }
            #if os(iOS)
            // Over the picture, bottom to top (docs/ipad-layout.md): the
            // connection's state, notices, the toolbar, the statistics.
            SessionStatusOverlay(model: model)
                .animation(.easeInOut(duration: 0.2), value: model.phase)
            TopNotices(model: model)
            SessionToolbar(model: model, chrome: chrome, keyBar: keyBar, showsStatistics: $showStats) {
                confirmLogOut = true
            }
            VStack(alignment: .leading, spacing: 8) {
                if model.isRemoteSession && chrome.isToolbarExpanded {
                    SessionBackButton(title: model.title) { model.disconnect() }
                        .transition(.opacity)
                }
                if showStats {
                    overlay.allowsHitTesting(false) // touches on it go to the remote desktop
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            #else
            if showStats {
                overlay
                    .allowsHitTesting(false) // clicks on it go to the remote desktop
                    .padding(10)
            }
            if case let .reconnecting(attempt, total, reason) = model.phase {
                ReconnectingCard(attempt: attempt, total: total, reason: reason) { model.cancelReconnect() }
            }
            #endif
        }
        #if os(iOS)
        // The picture is surrounded by black and the controls float on it in
        // glass: always dark, whatever the system's appearance.
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: model.phase) {
            if model.phase == .playing { chrome.connected() }
        }
        .onChange(of: model.input.map(ObjectIdentifier.init), initial: true) {
            model.input?.onPictureTouch = { [weak chrome] in chrome?.pictureTouched() }
            keyBar.input = model.input
        }
        #else
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
        .onChange(of: viewSize, initial: true) { model.sessionViewChanged(viewSize, scale: displayScale) }
        .onChange(of: displayScale) { model.sessionViewChanged(viewSize, scale: displayScale) }
        .task { await model.start() }
        .onDisappear { model.windowClosed() }
        .task { if !model.isRemoteSession { await diagnostics.run() } }
    }

    #if os(macOS)
    /// The window's toolbar. iOS floats its controls over the picture instead
    /// (App/iOS/SessionControls.swift).
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
        }
        if let clipboard = model.clipboard {
            ClipboardControls(clipboard: clipboard)
        }
        if let gamepads = model.gamepads {
            GamepadControls(gamepads: gamepads)
        }
        if model.isRemoteSession {
            ResolutionControls(model: model)
        }
        if model.hasMicrophone {
            Toggle(isOn: Binding(get: { model.isMicrophoneOn }, set: { _ in model.toggleMicrophone() })) {
                Label("Microphone", systemImage: model.isMicrophoneOn ? "mic.fill" : "mic.slash")
            }
            .help(model.isMicrophoneOn
                  ? "Stop sending your microphone"
                  : "Send your microphone to the remote desktop (use headphones, or it hears its own sound)")
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
    }

    @ViewBuilder private var sourceControls: some View {
        @Bindable var model = model
        // The prototype's test sources (no login): developer controls, in English.
        Picker(selection: $model.source) {
            Text(verbatim: "Loopback").tag(PlaybackModel.Source.loopback)
            Text(verbatim: "Direct").tag(PlaybackModel.Source.direct)
            Text(verbatim: "Remote").tag(PlaybackModel.Source.remote)
        } label: { Text(verbatim: "Source") }
        Picker(selection: $model.codec) {
            ForEach(VideoCodec.allCases) { Text($0.displayName).tag($0) }
        } label: { Text(verbatim: "Codec") }
        Picker(selection: $model.mode) {
            Text(verbatim: "On arrival").tag(VideoPresenter.Mode.onArrival)
            Text(verbatim: "Display link").tag(VideoPresenter.Mode.displayLink)
        } label: { Text(verbatim: "Pacing") }
    }
    #endif

    @ViewBuilder private var overlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.phase {
            case .idle:
                EmptyView()
            case let .encoding(codec, progress):
                // The statistics overlay stays in English, like the logs (docs/localization.md).
                ProgressView(value: progress) { Text(verbatim: "Encoding \(codec.displayName) test stream…") }
                    .frame(width: 280)
            case let .connecting(target):
                ProgressView { Text(verbatim: "Connecting to \(target)…") }
            case let .reconnecting(attempt, total, _):
                Text(verbatim: "Reconnecting (\(attempt) of \(total))…")
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

#if os(macOS)
/// Sharing the clipboard with the remote desktop (gdp-spec.md §7.9).
private struct ClipboardControls: View {
    @Bindable var clipboard: ClipboardSync

    var body: some View {
        Toggle(isOn: $clipboard.isEnabled) {
            Label("Clipboard", systemImage: clipboard.isEnabled ? "doc.on.clipboard.fill" : "doc.on.clipboard")
        }
        .help("Share the clipboard with the remote desktop: text copied on either side can be pasted on the other")
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
            ? Text("Forward game controllers to the remote desktop, up to four")
            : Text("Forwarding: \(names.formatted(.list(type: .and)))"))
    }
}

/// The remote desktop's size: the window's, or whatever the host has
/// (gdp-spec.md §7.2, docs/resolution.md).
private struct ResolutionControls: View {
    @Bindable var model: PlaybackModel

    var body: some View {
        Menu {
            Toggle("Match Window Size", isOn: $model.matchesWindowSize)
            Section("Sharper on Retina screens, at up to four times the work for the host") {
                Toggle("Retina Resolution", isOn: Binding(get: { model.resolutionUnits == .pixels },
                                                          set: { model.resolutionUnits = $0 ? .pixels : .points }))
                    .disabled(!model.matchesWindowSize)
            }
        } label: {
            Label("Resolution", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .help("Resize the remote desktop to fit this window")
    }
}
#endif


#if os(macOS)
/// Over the last picture while a lost connection is being restored. iOS
/// has its own (App/iOS/SessionStatus.swift).
private struct ReconnectingCard: View {
    let attempt: Int
    let total: Int
    let reason: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Connection lost").font(.headline)
            Text("Reconnecting… (attempt \(attempt) of \(total))").font(.callout)
            if !reason.isEmpty {
                Text(reason).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
