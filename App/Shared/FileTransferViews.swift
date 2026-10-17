import SpectreKit
import SwiftUI

/// The list of files going to the host (gdp-spec.md §7.12): each one's
/// progress or outcome, a button to cancel it, and the list's own actions.
/// In a popover from the Mac's toolbar (docs/file-transfer.md).
struct FileTransferList: View {
    let files: FileTransfers
    /// Opens the file picker, for more.
    let sendMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(files.items.reversed()) { item in
                        FileTransferRow(item: item) { files.cancel(item.id) }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 360)
            Divider()
            HStack {
                Button("Send Files…", action: sendMore)
                    .disabled(!files.isAvailable)
                Spacer()
                if files.hasActive {
                    Button("Cancel All", role: .destructive) { files.cancelAll() }
                }
                Button("Clear") { files.clearFinished() }
                    .disabled(!files.items.contains(where: \.isFinished))
            }
            .padding(10)
        }
        .frame(width: 340)
    }
}

private struct FileTransferRow: View {
    let item: FileTransfers.Item
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .sending {
                    ProgressView(value: item.fraction)
                        .controlSize(.small)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if !item.isFinished {
                Button(action: cancel) {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop sending this file")
            }
        }
    }

    private var symbol: String {
        switch item.state {
        case .waiting, .offered, .sending: "arrow.up.doc"
        case .saved: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var tint: Color {
        switch item.state {
        case .saved: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private var status: String {
        let size = item.size.formatted(.byteCount(style: .file))
        switch item.state {
        case .waiting: return String(localized: "Waiting · \(size)")
        case .offered: return String(localized: "Waiting for the host · \(size)")
        case .sending:
            return String(localized: "\(item.sent.formatted(.byteCount(style: .file))) of \(size)")
        case .saved(let name):
            return name == item.name ? String(localized: "Sent · \(size)")
                : String(localized: "Sent as “\(name)” · \(size)")
        case .failed(let failure): return failure.explanation
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}

extension FileTransfers.Failure {
    /// Why a file didn't go, in a few words.
    var explanation: String {
        switch self {
        case .folder: String(localized: "Folders can't be sent.")
        case .unreadable: String(localized: "The file couldn't be read.")
        case .badName: String(localized: "The name can't be used on the host.")
        case .changed: String(localized: "The file changed while it was being sent.")
        case .refused(let error), .hostFailed(let error):
            switch error {
            case .noSpace: String(localized: "Not enough space on the host.")
            case .badName: String(localized: "The name can't be used on the host.")
            case .refused: String(localized: "The host refused it.")
            case .writeFailed: String(localized: "The host couldn't save it.")
            case .sizeMismatch: String(localized: "The transfer was incomplete.")
            case .gone: String(localized: "It's no longer on the host.")
            case .readFailed: String(localized: "The host couldn't read it.")
            case .unsupported, .unspecified: String(localized: "The host couldn't take it.")
            }
        case .cancelledByHost: String(localized: "The host stopped receiving it.")
        case .timedOut: String(localized: "The host didn't answer.")
        case .notSent: String(localized: "The connection ended before it was sent.")
        case .couldntSave: String(localized: "It couldn't be saved on this device.")
        }
    }
}

extension FileTransfers.Batch {
    /// A notice for the batch: what went, and what didn't.
    var notice: Text {
        switch (saved.count, failed.count) {
        case (1, 0): Text("Sent “\(saved[0])” to the host")
        // Two or more files from here on: no singular forms needed.
        case (let n, 0): Text("Sent \(n) files to the host")
        case (0, 1): Text("Couldn't send “\(failed[0])”")
        case (0, let n): Text("Couldn't send \(n) files")
        case (let sent, let failed): Text("Sent \(sent) of \(sent + failed) files")
        }
    }

    var isFailure: Bool { saved.isEmpty }
}

/// Over the picture while files are dragged onto it: dropping sends them.
struct FileDropHint: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            Label("Drop to send to the remote desktop", systemImage: "arrow.up.doc")
                .font(.title3)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: .capsule)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
