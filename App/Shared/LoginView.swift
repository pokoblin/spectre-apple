import GDPKit
import SpectreKit
import SwiftUI

// The login's later steps, shown in the home screen's sign-in sheet
// (HostForms.swift): waiting, the server's certificate, its questions,
// the device and the desktop to open.

struct WorkingView: View {
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

struct TrustView: View {
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

struct CertificateChangedView: View {
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

struct PromptView: View {
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

struct DeviceListView: View {
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

struct SessionChoiceView: View {
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
