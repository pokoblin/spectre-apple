import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A file dragged onto the picture from another app (Files, Photos...),
/// to send to the host (gdp-spec.md §7.12). The system's copy goes when the
/// drop is over, and the file is read only when the host accepts it, so it
/// is copied into a folder of the app's own first. Folders aren't taken:
/// they can't be sent in this version.
struct DroppedFile: Transferable {
    let url: URL

    /// Where dropped files wait until they are sent.
    static let folder = URL.temporaryDirectory.appending(path: "Dropped Files", directoryHint: .isDirectory)

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            // A folder each: two drops can bring the same name.
            let place = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            let url = place.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: url)
            return DroppedFile(url: url)
        }
    }

    /// Lets go of every dropped file: when nothing is left to send, and at launch.
    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}
