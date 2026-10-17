import GDPKit
import Metal
import Synchronization

/// Lossless refinement's overlay plane (gdp-spec.md §7.8, §9.6): one per
/// output, its size, transparent until the host writes tiles into it,
/// drawn over the decoded video so that what the host sent losslessly
/// shows exactly.
///
/// The plane is kept in memory and each frame's layer is applied to it as
/// the frame arrives, in frame order, whatever becomes of the frame's
/// video: replaced in the mailbox before it is shown, skipped while video
/// is suspended in the background, or waiting for a keyframe. The host
/// counts every frame the client didn't report lost as applied, so the
/// plane must follow every one. The presenter then uploads what changed
/// since its last draw (``takeUpload(device:)``), copied out under the lock
/// so the GPU never reads pixels being written.
///
/// Applied ahead of the frame's own picture, by the decode time: a clear
/// can show the previous picture's lossy pixels under it for a frame,
/// where the content is changing anyway.
public final class RefinementPlane: Sendable {
    /// Pixels changed since the last upload, for the presenter to copy into its texture.
    public struct Upload: @unchecked Sendable {
        /// One changed region's pixels in `buffer`: BGRA from `offset`, `bytesPerRow` apart.
        public struct Piece: Sendable {
            public let region: MTLRegion
            public let offset: Int
            public let bytesPerRow: Int
        }
        /// The plane's size: the texture must have it (a new size starts a new texture).
        public let width: Int
        public let height: Int
        public let buffer: MTLBuffer
        public let pieces: [Piece]
    }

    /// Counts for the statistics overlay.
    public struct Counters: Sendable, Equatable {
        public var layers: UInt64 = 0
        public var tiles: UInt64 = 0
        public var tilePixels: UInt64 = 0
        public var resets: UInt64 = 0
    }

    private struct State {
        var width = 0
        var height = 0
        var pixels: [UInt8] = []
        /// What changed since the last upload: x0, y0, x1, y1 (exclusive).
        /// Kept apart, so two small tiles far apart don't upload all
        /// between them; past ``maxDirtyRects`` they merge into their bounds.
        var dirty: [(Int, Int, Int, Int)] = []
        var counters = Counters()
    }

    private let state = Mutex(State())

    public init() {}

    public var size: (width: Int, height: Int) { state.withLock { ($0.width, $0.height) } }
    public var counters: Counters { state.withLock { $0.counters } }

    /// The output's size (§7.2): a change starts a transparent plane of the
    /// new size (§9.6: a client SHOULD reset the plane then).
    public func resize(width: Int, height: Int) {
        state.withLock { s in
            guard width != s.width || height != s.height else { return }
            s.width = max(0, width)
            s.height = max(0, height)
            s.pixels = [UInt8](repeating: 0, count: s.width * s.height * 4)
            s.dirty = s.width > 0 && s.height > 0 ? [(0, 0, s.width, s.height)] : []
        }
    }

    /// One frame's layer, in order (§9.6): the reset, the clears, then the
    /// tiles. Rectangles are clipped to the plane. `layer.bgra` is read
    /// during the call only.
    public func apply(_ layer: GDPSession.RefineLayer) {
        state.withLock { s in
            s.counters.layers += 1
            let w = s.width, h = s.height
            guard w > 0, h > 0 else { return }
            if layer.reset {
                s.counters.resets += 1
                s.pixels.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
                s.dirty = [(0, 0, w, h)]
            }
            for clear in layer.clears {
                guard let (x0, y0, x1, y1) = Self.clip(clear, w, h) else { continue }
                s.pixels.withUnsafeMutableBytes { plane in
                    for y in y0..<y1 {
                        let row = UnsafeMutableRawBufferPointer(rebasing: plane[(y * w + x0) * 4..<(y * w + x1) * 4])
                        row.initializeMemory(as: UInt8.self, repeating: 0)
                    }
                }
                Self.markDirty(&s, x0, y0, x1, y1)
            }
            var offset = 0
            for tile in layer.tiles {
                let tw = Int(tile.width), th = Int(tile.height)
                defer { offset += tw * th * 4 }
                s.counters.tiles += 1
                s.counters.tilePixels += UInt64(tw * th)
                guard offset + tw * th * 4 <= layer.bgra.count,
                      let (x0, y0, x1, y1) = Self.clip(tile, w, h) else { continue }
                let skipX = x0 - Int(tile.x), skipY = y0 - Int(tile.y)
                s.pixels.withUnsafeMutableBytes { plane in
                    for y in y0..<y1 {
                        let from = offset + ((y - y0 + skipY) * tw + skipX) * 4
                        let count = (x1 - x0) * 4
                        plane.baseAddress!.advanced(by: (y * w + x0) * 4)
                            .copyMemory(from: layer.bgra.baseAddress!.advanced(by: from), byteCount: count)
                    }
                }
                Self.markDirty(&s, x0, y0, x1, y1)
            }
        }
    }

    /// What changed since the last call, copied into a buffer of its own
    /// for the presenter to blit into its texture; nil if nothing did.
    public func takeUpload(device: MTLDevice) -> Upload? {
        state.withLock { s in
            guard !s.dirty.isEmpty else { return nil }
            let rects = s.dirty
            s.dirty = []
            let total = rects.reduce(0) { $0 + ($1.2 - $1.0) * ($1.3 - $1.1) * 4 }
            guard let buffer = device.makeBuffer(length: total, options: .storageModeShared) else { return nil }
            var pieces: [Upload.Piece] = []
            var offset = 0
            s.pixels.withUnsafeBytes { plane in
                for (x0, y0, x1, y1) in rects {
                    let rowBytes = (x1 - x0) * 4
                    for y in y0..<y1 {
                        buffer.contents().advanced(by: offset + (y - y0) * rowBytes)
                            .copyMemory(from: plane.baseAddress!.advanced(by: (y * s.width + x0) * 4),
                                        byteCount: rowBytes)
                    }
                    pieces.append(Upload.Piece(region: MTLRegionMake2D(x0, y0, x1 - x0, y1 - y0), offset: offset,
                                               bytesPerRow: rowBytes))
                    offset += rowBytes * (y1 - y0)
                }
            }
            return Upload(width: s.width, height: s.height, buffer: buffer, pieces: pieces)
        }
    }

    /// The plane's pixel at (`x`, `y`), BGRA: for tests.
    func pixel(x: Int, y: Int) -> [UInt8] {
        state.withLock { s in Array(s.pixels[(y * s.width + x) * 4..<(y * s.width + x) * 4 + 4]) }
    }

    private static func clip(_ r: GDPSession.RefineRect, _ w: Int, _ h: Int) -> (Int, Int, Int, Int)? {
        let x0 = min(Int(r.x), w), y0 = min(Int(r.y), h)
        let x1 = min(Int(r.x) + Int(r.width), w), y1 = min(Int(r.y) + Int(r.height), h)
        return x1 > x0 && y1 > y0 ? (x0, y0, x1, y1) : nil
    }

    static let maxDirtyRects = 64

    private static func markDirty(_ s: inout State, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        // Already inside one: nothing new.
        if s.dirty.contains(where: { $0.0 <= x0 && $0.1 <= y0 && $0.2 >= x1 && $0.3 >= y1 }) { return }
        s.dirty.append((x0, y0, x1, y1))
        if s.dirty.count > maxDirtyRects {
            s.dirty = [s.dirty.dropFirst().reduce(s.dirty[0]) {
                (min($0.0, $1.0), min($0.1, $1.1), max($0.2, $1.2), max($0.3, $1.3))
            }]
        }
    }
}
