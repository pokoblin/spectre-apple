import SpectreKit
import SwiftUI

#if os(iOS)
/// iPad and iPhone: the home screen, with the session over it. The Mac
/// has a window for each (SpectreApp.swift).
struct ContentView: View {
    @State private var app = AppModel()

    var body: some View {
        HomeView(app: app)
    }
}
#endif

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
    @State private var prompt = PromptModel()
    @State private var voice = VoiceInputModel()
    @State private var regions = RegionAlertModel()
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
                if let input = model.input {
                    RegionOutline(regions: regions, input: input)
                        .ignoresSafeArea(.container)
                }
                #else
                VideoView(presenter: presenter, input: model.input)
                    // On the Mac the picture starts below the toolbar: under
                    // it, the remote desktop's top edge (GNOME's top bar) is hidden.
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
                #endif
            }
            #if os(iOS)
            // Over the picture, bottom to top (docs/ipad-layout.md): the
            // connection's state, notices, the toolbar, the statistics, choosing a region.
            SessionStatusOverlay(model: model)
                .animation(.easeInOut(duration: 0.2), value: model.phase)
            TopNotices(model: model, regions: regions)
            VoiceOverlay(voice: voice)
            if keyBar.isPromptOpen {
                PromptPanel(prompt: prompt, model: model) { keyBar.isPromptOpen = false }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // The corners make way for the prompt panel, or choosing a
            // region, rather than show beside them.
            SessionToolbar(model: model, chrome: chrome, keyBar: keyBar, regions: regions,
                           showsStatistics: $showStats) {
                confirmLogOut = true
            }
            .opacity(cornersHidden ? 0 : 1)
            .allowsHitTesting(!cornersHidden)
            .accessibilityHidden(cornersHidden)
            VStack(alignment: .leading, spacing: 8) {
                if model.isRemoteSession && chrome.isToolbarExpanded && !cornersHidden {
                    SessionBackButton(title: model.title) { model.disconnect() }
                        .transition(.opacity)
                }
                if showStats {
                    overlay.allowsHitTesting(false) // touches on it go to the remote desktop
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // Choosing a region covers everything else, the statistics too.
            if regions.isSelecting, let input = model.input {
                RegionSelectionLayer(regions: regions, input: input)
                    .ignoresSafeArea(.container)
                    .transition(.opacity)
                RegionSelectionHint(regions: regions)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            #else
            // Over the picture, as on the iPad (docs/macos-layout.md): the
            // connection's state, notices, the statistics. Dark glass on the
            // picture, whatever the system's appearance.
            Group {
                SessionStatusOverlay(model: model)
                    .animation(.easeInOut(duration: 0.2), value: model.phase)
                TopNotices(model: model)
                if showStats {
                    overlay
                        .allowsHitTesting(false) // clicks on it go to the remote desktop
                        .padding(10)
                }
            }
            .environment(\.colorScheme, .dark)
            #endif
        }
        #if os(iOS)
        // The picture is surrounded by black and the controls float on it in
        // glass: always dark, whatever the system's appearance.
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .animation(.smooth(duration: 0.3), value: keyBar.isPromptOpen)
        .animation(.smooth(duration: 0.3), value: regions.isSelecting)
        .onChange(of: regions.isSelecting) { keyBar.isSelectingRegion = regions.isSelecting }
        .onAppear {
            regions.attach(presenter: model.presenter, key: model.regionKey, title: model.title) { [weak model] in
                model?.phase == .playing
            }
        }
        .onDisappear { regions.detach() }
        .onChange(of: model.phase) {
            if model.phase == .playing { chrome.connected() }
        }
        .onChange(of: model.input.map(ObjectIdentifier.init), initial: true) {
            model.input?.onPictureTouch = { [weak chrome] in chrome?.pictureTouched() }
            keyBar.input = model.input
            keyBar.voice = voice
            voice.model = model
            SessionCommands.shared.register(model, keyBar: keyBar, regions: regions)
        }
        .onDisappear {
            voice.cancel()
            SessionCommands.shared.unregister(model)
        }
        #else
        .toolbar {
            if model.isRemoteSession {
                // Before the window's title, the host's name: back to the hosts.
                ToolbarItem(placement: .navigation) {
                    Button { model.disconnect() } label: {
                        Label("Disconnect", systemImage: "chevron.backward")
                    }
                    .help("Disconnect, leaving the desktop session running")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) { sessionButtons }
            if !model.isRemoteSession {
                ToolbarItemGroup { sourceControls }
            }
        }
        .navigationSubtitle(qualityText)
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

    #if os(iOS)
    /// The prompt panel is open or a region is being chosen: the corners' controls are out of the way.
    private var cornersHidden: Bool { keyBar.isPromptOpen || regions.isSelecting }
    #endif

    #if os(macOS)
    /// The window's toolbar: what is used during a session, then More. iOS
    /// floats its controls over the picture instead (App/iOS/SessionControls.swift).
    @ViewBuilder private var sessionButtons: some View {
        if let clipboard = model.clipboard {
            ClipboardControls(clipboard: clipboard)
        }
        if let input = model.input {
            Toggle(isOn: Binding(get: { input.isCaptured }, set: { input.setCaptured($0) })) {
                Label("Capture Mouse", systemImage: input.isCaptured ? "cursorarrow.square.fill" : "cursorarrow.square")
            }
            .help("Capture the mouse for games and 3D views: relative motion, the pointer locked (Ctrl+Cmd+G)")
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
        Menu {
            if model.isRemoteSession {
                ResolutionControls(model: model)
            }
            if let gamepads = model.gamepads {
                GamepadControls(gamepads: gamepads)
            }
            Toggle(isOn: $showStats) {
                Label("Statistics", systemImage: "chart.bar.xaxis")
            }
            if model.isRemoteSession {
                Divider()
                Button(role: .destructive) { confirmLogOut = true } label: {
                    Label("Log Out…", systemImage: "power")
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Resolution, gamepads, statistics, and logging out")
    }

    /// The window's subtitle while the picture plays: the round trip and
    /// the frames shown, each second.
    private var qualityText: String {
        guard model.phase == .playing, let quality = model.quality else { return "" }
        let ms = quality.milliseconds < 1 ? "<1" : quality.milliseconds.formatted(.number.precision(.fractionLength(0)))
        return "\(ms) ms · \(quality.framesPerSecond.formatted(.number.precision(.fractionLength(0)))) fps"
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
        #if os(iOS)
        // Glass like the other floating controls, as wide as its lines.
        .padding(10)
        .fixedSize()
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        #else
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        #endif
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
        Section {
            Toggle(isOn: $gamepads.isEnabled) {
                Label(gamepads.isEnabled && !names.isEmpty ? "Gamepads (\(names.count))" : "Gamepads",
                      systemImage: gamepads.isEnabled ? "gamecontroller.fill" : "gamecontroller")
            }
        } footer: {
            names.isEmpty
                ? Text("Forward game controllers to the remote desktop, up to four")
                : Text("Forwarding: \(names.formatted(.list(type: .and)))")
        }
    }
}

/// The remote desktop's size: the window's, or whatever the host has
/// (gdp-spec.md §7.2, docs/resolution.md).
private struct ResolutionControls: View {
    @Bindable var model: PlaybackModel

    var body: some View {
        // A submenu of More.
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
    }
}
#endif

