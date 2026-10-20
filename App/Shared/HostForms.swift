import GDPKit
import SpectreKit
import SwiftUI

/// The top of a form sheet: a large symbol in the accent colour, a title
/// and a line saying what the form is for, centred on the form's background.
struct FormHeader: View {
    var symbol: String
    var title: Text?
    var message: Text?

    var body: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 48))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                if let title {
                    title.font(.title2.bold())
                }
                if let message {
                    message.font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }
}

// MARK: - Adding and editing

/// A ghost server, the account on it and, if the user likes, its
/// password: everything Connect needs in one form (docs/saved-logins.md).
struct HostEditor: View {
    let isNew: Bool
    /// The account's password is in the Keychain already.
    let hasSavedPassword: Bool
    /// A password typed for the host before, kept until the app quits.
    let hasSessionPassword: Bool
    /// The host, the password typed (empty: none, or the known one stays),
    /// and whether to keep it in the Keychain.
    let save: (SavedHost, String, Bool) -> Void
    /// The host as it was, to tell whether the account changed.
    private let original: SavedHost
    @State private var host: SavedHost
    @State private var address: String
    @State private var port: String
    @State private var password = ""
    /// As it is: on if the password is saved, off unless the user turns it on otherwise.
    @State private var remember: Bool
    @Environment(\.dismiss) private var dismiss

    init(host: SavedHost, isNew: Bool, hasSavedPassword: Bool = false, hasSessionPassword: Bool = false,
         save: @escaping (SavedHost, String, Bool) -> Void) {
        self.isNew = isNew
        self.hasSavedPassword = hasSavedPassword
        self.hasSessionPassword = hasSessionPassword
        self.save = save
        original = host
        _host = State(initialValue: host)
        _remember = State(initialValue: hasSavedPassword)
        let parsed = host.address
        _address = State(initialValue: parsed?.host ?? host.server)
        _port = State(initialValue: parsed.map { $0.port == GDPLobby.defaultPort ? "" : String($0.port) } ?? "")
    }

    /// The address as the login takes it: `host` or `host:port`, brackets around IPv6.
    private var server: ServerAddress? {
        let host = address.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        guard !port.isEmpty else { return ServerAddress(parsing: host) }
        guard let p = UInt16(port), p > 0 else { return nil }
        return ServerAddress(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: p)
    }

    private var isComplete: Bool { server != nil && !host.username.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A password the switch can keep or let go: one typed now, or the
    /// account's known one while it stays the same account.
    private var canRemember: Bool {
        guard password.isEmpty else { return true }
        let sameAccount = server != nil && server == original.address
            && host.username.trimmingCharacters(in: .whitespaces) == original.username
        return sameAccount && (hasSavedPassword || hasSessionPassword)
    }

    var body: some View {
        NavigationStack {
            Form {
                FormHeader(symbol: "pc", message: Text("Enter the address of the ghost server and your username on it."))
                Section {
                    TextField("Name (Optional)", text: $host.name)
                    TextField("Address", text: $address)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    TextField(text: $port, prompt: Text(verbatim: String(GDPLobby.defaultPort))) { Text("Port") }
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("Username", text: $host.username)
                        .textContentType(.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } footer: {
                    Text("The default port is \(String(GDPLobby.defaultPort)). To connect from outside your network, use a VPN such as Tailscale rather than exposing the port to the internet.")
                }
                Section {
                    // iOS shows only the prompt, so it names the field too.
                    SecureField(text: $password,
                                prompt: hasSavedPassword ? Text("Password (Saved in Keychain)") : Text("Password (Optional)")) {
                        Text("Password")
                    }
                    .textContentType(.password)
                    Toggle("Remember in Keychain", isOn: Binding(get: { remember && canRemember },
                                                                set: { remember = $0 }))
                        .disabled(!canRemember)
                } footer: {
                    Text("Connect signs in with it. If you leave it empty, or the server asks for more, such as a one-time code, you are asked when you connect. Not remembered, it is kept until Spectre quits; remembered, it stays in this device's Keychain.")
                }
            }
            .navigationTitle(isNew ? Text("Add Server") : Text("Edit Server"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .formStyle(.grouped)
            .frame(minWidth: 460, minHeight: 540)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        guard let server else { return }
                        var saved = host
                        saved.server = server.description
                        saved.username = host.username.trimmingCharacters(in: .whitespaces)
                        saved.name = host.name.trimmingCharacters(in: .whitespaces)
                        save(saved, password, remember && canRemember)
                        dismiss()
                    }
                    .disabled(!isComplete)
                }
            }
        }
    }
}

// MARK: - Signing in

/// Signing in to a host, one step of the login at a time (gdp-spec.md
/// §4, §5): the password, the server's further questions, its
/// certificate the first time, the device and the desktop. It goes away
/// when the session opens.
struct LoginSheet: View {
    @Bindable var app: AppModel
    let host: SavedHost
    @State private var password = ""
    @State private var remember: Bool
    @FocusState private var passwordFocused: Bool

    init(app: AppModel, host: SavedHost) {
        self.app = app
        self.host = host
        _remember = State(initialValue: app.hasSavedPassword(host))
    }

    private var flow: LoginFlow { app.login }

    private var isAtForm: Bool {
        switch flow.step {
        case .idle, .failed: true
        default: false
        }
    }

    /// The step's view has a Cancel button of its own (the Mac shows only that one).
    private var hasOwnCancel: Bool {
        #if os(macOS)
        switch flow.step {
        case .trustNewHost, .certificateChanged, .prompt, .chooseDevice, .chooseSession: true
        default: false
        }
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sign In")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #else
                .formStyle(.grouped)
                .frame(minWidth: 480, minHeight: 440)
                #endif
                .toolbar {
                    // The Mac puts it at the bottom, beside a later step's own Cancel.
                    if !hasOwnCancel {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { app.cancelLogin() }
                        }
                    }
                    if isAtForm {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Connect", action: connect)
                        }
                    }
                }
        }
        .interactiveDismissDisabled()
    }

    private var header: some View {
        FormHeader(symbol: "pc", title: Text("Sign In to “\(host.title)”"),
                   message: Text("Use the password of \(host.username) on this server. If the server asks for more, such as a one-time code, it comes next."))
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .idle, .failed:
            Form {
                header
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($passwordFocused)
                        .onSubmit(connect)
                    Toggle("Remember in Keychain", isOn: $remember)
                        .disabled(password.isEmpty)
                } footer: {
                    if case let .failed(failure) = flow.step {
                        // The server's own words.
                        Label { Text(verbatim: failure.message) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                            .foregroundStyle(.red)
                    }
                }
            }
            .onAppear { passwordFocused = true }
        case let .working(message):
            Form {
                header
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(verbatim: message).foregroundStyle(.secondary)
                    }
                }
            }
        case let .trustNewHost(request):
            step { TrustView(request: request, onTrust: flow.trustAndContinue, onCancel: app.cancelLogin) }
        case let .certificateChanged(request):
            step { CertificateChangedView(request: request, onForget: flow.forgetPinnedCertificate, onCancel: app.cancelLogin) }
        case let .prompt(prompt):
            step {
                PromptView(prompt: prompt, username: flow.username, server: flow.server, notice: flow.notice,
                           remembered: app.hasSavedPassword(host),
                           onAnswer: { flow.answer($0, remember: $1) }, onCancel: app.cancelLogin)
            }
        case let .chooseDevice(devices):
            step { DeviceListView(devices: devices, onSelect: flow.select(device:), onCancel: app.cancelLogin) }
        case let .chooseSession(choice):
            step { SessionChoiceView(choice: choice, onOpen: flow.open(type:takeOver:), onCancel: app.cancelLogin) }
        case .redirected:
            ProgressView()
        }
    }

    /// A later step: the login screen's own view of it, in the sheet.
    private func step(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
    }

    private func connect() {
        app.signIn(host, password: password, remember: remember && !password.isEmpty)
        password = "" // the login holds it until a prompt takes it
    }
}
