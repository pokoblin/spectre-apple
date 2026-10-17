import SpectreKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The list of files going to and coming from the host (gdp-spec.md §7.12):
/// each one's progress or outcome, a button to cancel it, and the list's own
/// actions. In a popover from the Mac's toolbar (docs/file-transfer.md).
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
                .accessibilityLabel(item.direction == .download ? Text("Download") : Text("Upload"))
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
                    .textSelection(.enabled) // the host's folder, to copy
            }
            Spacer(minLength: 0)
            if !item.isFinished {
                Button(action: cancel) {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop this transfer")
            }
            #if os(macOS)
            if let url = item.localURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Show in Finder", systemImage: "magnifyingglass.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }
            #else
            if let url = item.localURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button {
                    // The Files app, at the folder the file is in.
                    if let files = URL(string: "shareddocuments://"
                        + url.deletingLastPathComponent().path(percentEncoded: true)) {
                        UIApplication.shared.open(files)
                    }
                } label: {
                    Label("Show in Files", systemImage: "folder.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            #endif
        }
    }

    private var symbol: String {
        switch item.state {
        case .waiting, .offered, .sending: item.direction == .download ? "arrow.down.doc" : "arrow.up.doc"
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
        case .saved(let name) where item.direction == .download:
            return name == item.name ? String(localized: "Downloaded · \(size)")
                : String(localized: "Downloaded as “\(name)” · \(size)")
        case .saved(let name):
            if let folder = item.hostDirectory {
                return name == item.name ? String(localized: "Saved to \(folder) · \(size)")
                    : String(localized: "Saved to \(folder) as “\(name)” · \(size)")
            }
            return name == item.name ? String(localized: "Sent · \(size)")
                : String(localized: "Sent as “\(name)” · \(size)")
        case .failed(.folder) where item.direction == .download:
            return String(localized: "Folders can't be downloaded yet.")
        case .failed(let failure): return failure.explanation
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}

extension FileTransfers {
    /// How far the unfinished files have got, together.
    var activeFraction: Double {
        let going = items.filter { !$0.isFinished }
        let total = going.reduce(0) { $0 + $1.size }
        return total == 0 ? 0 : Double(going.reduce(0) { $0 + $1.sent }) / Double(total)
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
        if !downloaded.isEmpty {
            // Two or more files where there is a number: no singular forms needed.
            switch (downloaded.count, failed.count) {
            case (1, 0): return Text("Downloaded “\(downloaded[0])”")
            case (let n, 0): return Text("Downloaded \(n) files")
            case (let n, let failed): return Text("Downloaded \(n) of \(n + failed) files")
            }
        }
        return uploadNotice
    }

    private var uploadNotice: Text {
        if let folder = hostDirectory {
            switch (saved.count, failed.count) {
            case (1, 0): return Text("Sent “\(saved[0])” to \(folder) on the host")
            // Two or more files: no singular forms needed.
            case (let n, 0): return Text("Sent \(n) files to \(folder) on the host")
            case (let sent, let failed): return Text("Sent \(sent) of \(sent + failed) files to \(folder) on the host")
            }
        }
        return switch (saved.count, failed.count) {
        case (1, 0): Text("Sent “\(saved[0])” to the host")
        // Two or more files from here on: no singular forms needed.
        case (let n, 0): Text("Sent \(n) files to the host")
        case (0, 1): Text("Couldn't send “\(failed[0])”")
        case (0, let n): Text("Couldn't send \(n) files")
        case (let sent, let failed): Text("Sent \(sent) of \(sent + failed) files")
        }
    }

    var isFailure: Bool { saved.isEmpty && downloaded.isEmpty }
    var symbol: String { isFailure ? "exclamationmark.triangle" : downloaded.isEmpty ? "arrow.up.doc" : "arrow.down.doc" }
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

/// Files the host's user copied, offered for download (gdp-spec.md §7.12):
/// over the picture, at the top, for a while after each copy.
struct CopiedFilesBanner: View {
    let files: FileTransfers.HostFiles
    let download: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label {
                if files.files.count == 1 {
                    Text("“\(files.files[0].name)” was copied on the host")
                } else {
                    // Two or more: no singular form needed.
                    Text("\(files.files.count) files were copied on the host")
                }
            } icon: {
                Image(systemName: "doc.on.doc")
            }
            .lineLimit(1)
            Button("Download", action: download)
                .disabled(files.downloadable.isEmpty)
                #if os(macOS)
                .help("Download them to the Downloads folder")
                #else
                .help("Download them to Spectre's folder in the Files app")
                #endif
            Button(action: dismiss) {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

