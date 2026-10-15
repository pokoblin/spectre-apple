import GDPKit
import SpectreKit
import SwiftUI

/// Signing in, one LoginFlow step at a time (gdp-spec.md §4, §5).
struct LoginView: View {
    @Bindable var app: AppModel
    @State private var serverText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remember = false
    @FocusState private var focus: Field?
    @State private var showTrustedServers = false

    private enum Field { case server, username, password }

    private var flow: LoginFlow { app.login }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                card
                    .padding(20)
                    .frame(maxWidth: 440)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showTrustedServers) { TrustedServersView(app: app) }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "display")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            Text(verbatim: "Spectre").font(.largeTitle.weight(.semibold))
            Text("Connect to a ghost host").foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    @ViewBuilder private var card: some View {
        switch flow.step {
        case .idle:
            connectForm(message: app.lastSessionEnd, isError: false)
        case let .failed(failure):
            connectForm(message: failure.message, isError: true)
        case let .working(message):
            WorkingView(message: message) { flow.cancel() }
        case let .trustNewHost(request):
            TrustView(request: request, onTrust: flow.trustAndContinue, onCancel: flow.cancel)
        case let .certificateChanged(request):
            CertificateChangedView(request: request, onForget: flow.forgetPinnedCertificate, onCancel: flow.cancel)
        case let .prompt(prompt):
            PromptView(prompt: prompt, username: flow.username, server: flow.server, notice: flow.notice,
                       remembered: flow.server.map { flow.hasSavedLogin(server: $0, username: flow.username) } ?? false,
                       onAnswer: { flow.answer($0, remember: $1) }, onCancel: flow.cancel)
                .id(prompt.text) // a fresh field per prompt
        case let .chooseDevice(devices):
            DeviceListView(devices: devices, onSelect: flow.select(device:), onCancel: flow.cancel)
        case let .chooseSession(choice):
            SessionChoiceView(choice: choice, onOpen: flow.open(type:takeOver:), onCancel: flow.cancel)
        case .redirected:
            WorkingView(message: String(localized: "Opening the session…"), onCancel: nil)
        }
    }

    private var parsedServer: ServerAddress? { ServerAddress(parsing: serverText) }

    @ViewBuilder private func connectForm(message: String?, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(isError ? .red : .secondary)
                    .font(.callout)
            }
            LabeledField("Server") {
                TextField("host or host:port", text: $serverText)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focus, equals: .server)
                    .onSubmit { focus = .username }
            }
            LabeledField("Username") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
            }
            // Answers the server's first secret prompt; left empty, the
            // server's prompts come one at a time (docs/login.md).
            LabeledField("Password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit(connect)
            }
            Toggle("Remember", isOn: $remember)
                .help("Keep the password in the Keychain and sign in with one tap next time.")
                .disabled(password.isEmpty)
            Button(action: connect) {
                Text("Connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(parsedServer == nil || username.isEmpty)

            if !app.recent.isEmpty {
                Divider()
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                ForEach(app.recent) { entry in
                    let saved = app.savedRecent.contains(entry)
                    HStack {
                        Button {
                            serverText = entry.server
                            username = entry.username
                            password = ""
                            remember = saved
                            // A saved login connects right away (docs/saved-logins.md).
                            if saved { _ = app.signInWithSaved(entry) } else { focus = .password }
                        } label: {
                            Label(entry.title, systemImage: saved ? "key.fill" : "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(saved ? "Connect with the saved password" : "Fill in this server and username")
                        .contextMenu {
                            if saved {
                                Button("Forget Saved Password", role: .destructive) { app.forgetSavedLogin(entry) }
                            }
                            Button("Forget This Login", role: .destructive) { app.forgetRecent(entry) }
                        }
                        Button(role: .destructive) { app.forgetRecent(entry) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Forget \(entry.server)")
                    }
                }
            }

            Divider()
            Button {
                focus = nil // on the Mac, the password field's AutoFill button would float over the sheet
                showTrustedServers = true
            } label: {
                Label("Trusted Servers…", systemImage: "lock.shield")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .onAppear {
            if serverText.isEmpty, let last = app.recent.first {
                serverText = last.server
                username = last.username
                remember = app.savedRecent.contains(last) // unticked, signing in forgets it
            }
            focusFirstEmpty()
        }
    }

    private func connect() {
        guard let server = parsedServer, !username.isEmpty else { return }
        app.signIn(server: server, username: username, password: password, remember: remember)
        password = "" // the login holds it until a prompt takes it
    }

    /// The first field still to fill in.
    private func focusFirstEmpty() {
        focus = parsedServer == nil ? .server : username.isEmpty ? .username : .password
    }
}

private struct LabeledField<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content.textFieldStyle(.roundedBorder)
        }
    }
}

private struct WorkingView: View {
    let message: String
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
            if let onCancel {
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// The fingerprint in the colon-separated form people compare (§2.3), eight
/// byte pairs per line so it fits a phone and a large type size alike.
struct FingerprintText: View {
    let fingerprint: CertificateFingerprint

    var body: some View {
        let pairs = fingerprint.displayString.split(separator: ":")
        let lines = stride(from: 0, to: pairs.count, by: 8).map { pairs[$0..<min($0 + 8, pairs.count)].joined(separator: ":") }
        Text(lines.joined(separator: "\n"))
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TrustView: View {
    let request: LoginFlow.TrustRequest
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("First connection to \(request.server.description)", systemImage: "lock.shield")
                .font(.headline)
            Text("Spectre hasn't seen this server before. Check that its certificate fingerprint matches the one its administrator gave you before you sign in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "SHA-256").font(.caption).foregroundStyle(.secondary)
            FingerprintText(fingerprint: request.presented)
            Text("Nothing has been sent to the server yet. If you trust it, Spectre remembers this fingerprint and warns you if it ever changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Trust and Continue", action: onTrust)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct CertificateChangedView: View {
    let request: LoginFlow.TrustRequest
    let onForget: () -> Void
    let onCancel: () -> Void
    @State private var confirmForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("The certificate of \(request.server.description) has changed", systemImage: "exclamationmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("This can mean someone is intercepting the connection. Spectre did not send your username. Unless the server's administrator told you its certificate was replaced, don't continue.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let pinned = request.pinned {
                Text("Saved").font(.caption).foregroundStyle(.secondary)
                FingerprintText(fingerprint: pinned)
            }
            Text("Presented now").font(.caption).foregroundStyle(.secondary)
            FingerprintText(fingerprint: request.presented)
            HStack {
                Button("Forget Saved Fingerprint…", role: .destructive) { confirmForget = true }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .confirmationDialog("Forget the saved fingerprint?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive, action: onForget)
        } message: {
            Text("The next connection to \(request.server.description) will ask you to verify its new fingerprint.")
        }
    }
}

private struct PromptView: View {
    let prompt: LoginFlow.Prompt
    let username: String
    let server: ServerAddress?
    let notice: String?
    let onAnswer: (String, Bool) -> Void
    let onCancel: () -> Void
    @State private var answer = ""
    /// For a secret: keep it in the Keychain once signed in.
    @State private var remember: Bool
    @FocusState private var focused: Bool

    /// `remembered`: a login is already saved for this user and server, so
    /// "Remember" starts ticked; otherwise it starts off.
    init(prompt: LoginFlow.Prompt, username: String, server: ServerAddress?, notice: String?, remembered: Bool,
         onAnswer: @escaping (String, Bool) -> Void, onCancel: @escaping () -> Void) {
        self.prompt = prompt
        self.username = username
        self.server = server
        self.notice = notice
        self.onAnswer = onAnswer
        self.onCancel = onCancel
        _remember = State(initialValue: remembered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            Text(verbatim: "\(username) @ \(server?.description ?? "")").font(.caption).foregroundStyle(.secondary)
            // The server's own prompt text, as its authentication stack wrote it (§4.3).
            Text(prompt.text.trimmingCharacters(in: .whitespaces)).font(.headline)
            Group {
                if prompt.echo {
                    TextField("", text: $answer)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } else {
                    SecureField("", text: $answer)
                        .textContentType(.password)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(submit)
            if !prompt.echo {
                Toggle("Remember", isOn: $remember)
                    .help("Keep this in the Keychain and sign in with one tap next time. Leave one-time codes unticked.")
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Continue", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        onAnswer(answer, remember)
        answer = ""
    }
}

private struct DeviceListView: View {
    let devices: [GDPLobby.Device]
    let onSelect: (GDPLobby.Device) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a host").font(.headline)
            if devices.isEmpty {
                Text("No hosts are assigned to you.").foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                Button { onSelect(device) } label: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.online ? (device.hasSession ? "Session running" : "Online") : "Offline")
                                .font(.caption)
                                .foregroundStyle(device.online ? .green : .secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!device.online)
            }
            Button("Cancel", role: .cancel, action: onCancel)
        }
    }
}

private struct SessionChoiceView: View {
    let choice: LoginFlow.SessionChoice
    let onOpen: (String?, Bool) -> Void
    let onCancel: () -> Void
    @State private var type = ""
    @State private var takeOver = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let running = choice.runningTypeName {
                Text("Your session").font(.headline)
                // §4.6: SessionOpen reattaches to a running session, whatever type it names.
                Label("A \(running) session is running; you'll return to it.", systemImage: "play.rectangle")
                    .font(.callout)
                if choice.needsTakeOver {
                    Text("Someone is viewing it from another device. Taking over disconnects them; the session keeps running.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Take over from the other viewer", isOn: $takeOver)
                }
            } else {
                Text("Choose a desktop").font(.headline)
                Picker("Desktop", selection: $type) {
                    ForEach(choice.list.types) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button(choice.runningTypeName == nil ? "Start" : "Connect") {
                    onOpen(type.isEmpty ? nil : type, takeOver)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(choice.needsTakeOver && !takeOver)
            }
        }
        .onAppear { type = choice.list.defaultType }
    }
}
