import SpectreKit
import SwiftUI

/// How text written in the prompt panel reaches the host's cursor
/// (docs/ipad-layout.md). Linux has no one paste key: terminals take
/// Ctrl+Shift+V, other programs Ctrl+V. Typing needs no clipboard but only
/// has the keys of the host's US layout.
enum PasteMethod: String, CaseIterable, Identifiable {
    case ctrlShiftV, ctrlV, typing

    var id: String { rawValue }
    static let key = "promptPasteMethod"

    var combo: KeyCombo? {
        switch self {
        case .ctrlShiftV: KeyCombo([.control, .shift], HIDUsage.v, title: "Ctrl+Shift+V")
        case .ctrlV: KeyCombo([.control], HIDUsage.v, title: "Ctrl+V")
        case .typing: nil
        }
    }
}

/// The prompt panel's text: the draft, kept until sent, and the last 20
/// sent. Both stay on this device.
@MainActor
@Observable
final class PromptModel {
    var draft = UserDefaults.standard.string(forKey: PromptModel.draftKey) ?? "" {
        didSet { UserDefaults.standard.set(draft, forKey: Self.draftKey) }
    }
    private(set) var history = UserDefaults.standard.stringArray(forKey: PromptModel.historyKey) ?? []

    private static let draftKey = "promptDraft"
    private static let historyKey = "promptHistory"
    static let historyLimit = 20
    /// Between the clipboard and the paste key, which travel on different
    /// streams (gdp-spec.md §7.9, §8.2) with no order between them.
    static let pasteDelay: Duration = .milliseconds(250)

    func clearHistory() {
        history = []
        UserDefaults.standard.set(history, forKey: Self.historyKey)
    }

    /// Sends the draft to where the host's cursor is: on the host's
    /// clipboard and pasted, or typed. Then it is history and the draft is
    /// empty. False if there was nothing to send.
    @discardableResult
    func send(pressingReturn: Bool, input: SessionInput, clipboard: ClipboardSync?, method: PasteMethod) -> Bool {
        let text = draft
        guard !text.isEmpty else { return false }
        if let combo = method.combo, let clipboard, clipboard.sendForPaste(text) {
            Task {
                try? await Task.sleep(for: Self.pasteDelay)
                input.typer.press(combo)
                if pressingReturn { input.typer.press(HIDUsage.returnOrEnter) }
            }
        } else {
            // No clipboard on this session (or typing chosen): the host's US
            // layout, characters it has no key for skipped and counted.
            input.type(text)
            if pressingReturn { input.typer.press(HIDUsage.returnOrEnter) }
        }
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        history = Array(history.prefix(Self.historyLimit))
        UserDefaults.standard.set(history, forKey: Self.historyKey)
        draft = ""
        return true
    }
}

/// Writing on the iPad, with its input methods, dictation and paste, and
/// sending it all at once to the host's cursor, while the remote desktop
/// stays in view above. Floats at the bottom centre; the corner controls
/// hide while it is open.
struct PromptPanel: View {
    @Bindable var prompt: PromptModel
    let model: PlaybackModel
    let close: () -> Void
    @AppStorage(PasteMethod.key) private var method: PasteMethod = .ctrlShiftV
    @FocusState private var focused: Bool

    private var isEmpty: Bool { prompt.draft.isEmpty }
    private var pastes: Bool { method != .typing && model.clipboard != nil }

    var body: some View {
        VStack(spacing: 10) {
            header
            TextField(text: $prompt.draft, axis: .vertical) {
                Text("Write here, then send it to the cursor on the host")
            }
            .lineLimit(4...9) // about 90 to 220 points, growing with the text
            .focused($focused)
            .padding(12)
            .background(.black.opacity(0.25), in: .rect(cornerRadius: 14))
            HStack(spacing: 12) {
                Button("Clear") { prompt.draft = "" }
                    .disabled(isEmpty)
                Spacer()
                Button("Send") { send(pressingReturn: false) }
                    .buttonStyle(.glass)
                    .disabled(isEmpty)
                Button { send(pressingReturn: true) } label: {
                    Label("Send and Return", systemImage: "return")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: 720)
        .glassEffect(.regular, in: .rect(cornerRadius: FloatingKeyBar.cardCornerRadius))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Send to Host", systemImage: "square.and.pencil")
                .font(.headline)
            Spacer()
            Menu {
                Picker("Paste With", selection: $method) {
                    Text(verbatim: "Ctrl+Shift+V").tag(PasteMethod.ctrlShiftV)
                    Text(verbatim: "Ctrl+V").tag(PasteMethod.ctrlV)
                    Text("Typing").tag(PasteMethod.typing)
                }
                .pickerStyle(.inline)
            } label: {
                Text(pastes ? (method.combo?.title ?? "") : String(localized: "Typing"))
                    .font(.footnote.monospaced())
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Paste With")
            Menu {
                Section {
                    ForEach(prompt.history, id: \.self) { text in
                        Button { prompt.draft = text } label: {
                            Text(verbatim: text).lineLimit(2)
                        }
                    }
                }
                Button("Clear History", systemImage: "trash", role: .destructive) { prompt.clearHistory() }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(prompt.history.isEmpty)
            .accessibilityLabel("Recently Sent")
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
        }
    }

    private func send(pressingReturn: Bool) {
        guard let input = model.input else { return }
        if prompt.send(pressingReturn: pressingReturn, input: input, clipboard: model.clipboard, method: method) {
            close()
        }
    }
}

/// Opens the prompt panel: on the floating key bar and above the keyboard.
struct PromptKey: View {
    let model: KeyBarModel

    var body: some View {
        Button { model.isPromptOpen = true } label: {
            Image(systemName: "square.and.pencil")
        }
        .buttonStyle(KeyCapStyle())
        .accessibilityLabel("Write and Send to Host")
    }
}
