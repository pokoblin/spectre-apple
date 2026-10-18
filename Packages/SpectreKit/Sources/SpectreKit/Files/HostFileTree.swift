import Foundation
import GDPKit

/// One of the host's lists of copied files as a tree (gdp-spec.md §7.12,
/// `file-clipboard`): each entry by its index in the list, each folder's
/// entries by theirs. A list carries copied folders' contents as far as it
/// had room; a folder left `unlisted` is filled in by ``merge(folder:firstIndex:files:)``
/// once the host has listed it.
struct HostFileTree: Sendable {
    /// A file inside a copied folder, with the folders on the way to it.
    struct File: Equatable, Sendable {
        var index: UInt32
        var path: [String]
        var size: UInt64
    }

    private(set) var entries: [UInt32: GDPSession.FileListEntry] = [:]
    private var children: [UInt32: [UInt32]] = [:]

    init(_ files: [GDPSession.FileListEntry]) {
        for (i, file) in files.enumerated() {
            let index = UInt32(i)
            entries[index] = file
            if file.parent > 0 { children[file.parent - 1, default: []].append(index) }
        }
    }

    /// Every entry known, in folders listed so far.
    var count: Int { entries.count }

    /// A listing of folder `folder`: its entries take the indices from
    /// `firstIndex` on. It is listed from now on.
    mutating func merge(folder: UInt32, firstIndex: UInt32, files: [GDPSession.FileListEntry]) {
        guard var entry = entries[folder], entry.isDirectory else { return }
        entry.isUnlisted = false
        entries[folder] = entry
        for (k, var file) in files.enumerated() {
            let index = firstIndex + UInt32(k)
            guard entries[index] == nil else { continue } // listed already
            file.parent = folder + 1
            entries[index] = file
            children[folder, default: []].append(index)
        }
    }

    /// Folders at or under `root` whose contents aren't known yet.
    func unlisted(under root: UInt32) -> [UInt32] {
        walk(root).filter { entries[$0]?.isUnlisted == true }
    }

    /// The folders under `root` and the files in them, parents before
    /// their contents, each with its path below `root`. What has a name
    /// that breaks §7.12's rules is left out, with everything in it; the
    /// count of those comes back too.
    func contents(of root: UInt32) -> (folders: [[String]], files: [File], skipped: Int) {
        var folders: [[String]] = []
        var files: [File] = []
        var skipped = 0
        var pending: [(UInt32, [String])] = [(root, [])]
        while !pending.isEmpty {
            let (folder, path) = pending.removeFirst()
            for index in children[folder] ?? [] {
                guard let entry = entries[index] else { continue }
                guard GDPSession.isValidFileName(entry.name) else {
                    skipped += 1
                    continue
                }
                let inner = path + [entry.name]
                if entry.isDirectory {
                    folders.append(inner)
                    pending.append((index, inner))
                } else {
                    files.append(File(index: index, path: inner, size: entry.size))
                }
            }
        }
        return (folders, files, skipped)
    }

    /// How much the files at or under `root` come to, as listed.
    func totalSize(under root: UInt32) -> UInt64 {
        walk(root).reduce(0) { total, index in
            guard let entry = entries[index], !entry.isDirectory else { return total }
            return total + entry.size
        }
    }

    /// `root` and everything known under it.
    private func walk(_ root: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        var pending = [root]
        while let index = pending.popLast() {
            out.append(index)
            pending.append(contentsOf: children[index] ?? [])
        }
        return out
    }
}
