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
    @State private var showStats = true
    @State private var confirmLogOut = false

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
        .confirmationDialog("Log out of the remote desktop?", isPresented: $confirmLogOut, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) { model.logOut() }
        } message: {
            Text("This ends the desktop session itself, not just this connection.")
        }
        .task { await model.start() }
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
