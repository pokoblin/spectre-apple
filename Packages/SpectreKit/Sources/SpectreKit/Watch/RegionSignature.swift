import CoreGraphics
import CoreVideo

/// A coarse picture of one region of a frame, to tell whether it changed:
/// the region cut into a grid of cells (8 pixels each, at most
/// ``maxCells`` each way) and the mean luma of each.
///
/// Decoded frames are NV12, so the luma plane is already the grey picture.
/// A cell's mean hides the codec's fine noise but not a character typed
/// into it: one glyph moves an 8-pixel cell's mean by tens of code values.
public struct RegionSignature: Sendable, Equatable {
    public let columns: Int
    public let rows: Int
    /// Mean luma per cell, row by row from the top left.
    public let cells: [UInt8]

    /// The cells' side in pixels, unless the region is too large for ``maxCells``.
    public static let cellSize = 8
    public static let maxCells = 160
    /// The most pixels read per signature: up to a whole 1080p picture
    /// pixel by pixel; a larger region is read every other pixel (or
    /// sparser) each way, where a stroke one pixel thin may be missed.
    public static let maxSamples = 2_500_000
    /// How far a cell's mean may move (code values of 255) before it counts
    /// as a change.
    public static let threshold = 4

    public init(columns: Int, rows: Int, cells: [UInt8]) {
        precondition(cells.count == columns * rows)
        self.columns = columns
        self.rows = rows
        self.cells = cells
    }

    /// Whether `other` is a different picture of the region: a cell moved
    /// by ``threshold`` or more. A different grid (the picture's size
    /// changed) isn't comparable and doesn't count.
    public func differs(from other: RegionSignature, threshold: Int = Self.threshold) -> Bool {
        guard columns == other.columns, rows == other.rows else { return false }
        for i in cells.indices where abs(Int(cells[i]) - Int(other.cells[i])) >= threshold { return true }
        return false
    }

    /// The signature of `region` (0...1 each way over the picture, top-left
    /// origin) of a decoded frame whose picture is `displaySize` (nil: the
    /// whole buffer; a larger coded buffer's padding is left out). Nil
    /// without a luma plane or an empty region.
    public static func make(pixelBuffer: CVPixelBuffer, displaySize: CGSize?, region: CGRect) -> RegionSignature? {
        guard CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let picture = CGSize(width: min(displaySize?.width ?? CGFloat(width), CGFloat(width)),
                             height: min(displaySize?.height ?? CGFloat(height), CGFloat(height)))
        return make(luma: UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                    picture: picture, region: region)
    }

    /// The same from a luma plane: one byte per pixel, `picture` the part of it to use.
    public static func make(luma: UnsafeRawPointer, bytesPerRow: Int, picture: CGSize,
                            region: CGRect) -> RegionSignature? {
        let r = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull else { return nil }
        let x0 = Int((r.minX * picture.width).rounded(.down)), x1 = Int((r.maxX * picture.width).rounded(.up))
        let y0 = Int((r.minY * picture.height).rounded(.down)), y1 = Int((r.maxY * picture.height).rounded(.up))
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0 else { return nil }
        let columns = min(maxCells, max(1, (w + cellSize - 1) / cellSize))
        let rows = min(maxCells, max(1, (h + cellSize - 1) / cellSize))
        let step = max(1, Int((Double(w * h) / Double(maxSamples)).squareRoot().rounded(.up)))

        // Plain pointers and while loops: this runs four times a second, and
        // in a debug build arrays and strides made it 20 times slower.
        let cellCount = columns * rows
        let sums = UnsafeMutablePointer<Int>.allocate(capacity: cellCount)
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: cellCount)
        sums.initialize(repeating: 0, count: cellCount)
        counts.initialize(repeating: 0, count: cellCount)
        defer {
            sums.deallocate()
            counts.deallocate()
        }
        // Each cell column's span of sampled pixels: [start, end) in steps.
        var spans: [(start: Int, end: Int, count: Int)] = []
        spans.reserveCapacity(columns)
        for c in 0..<columns {
            let first = (c * w + columns - 1) / columns, last = ((c + 1) * w + columns - 1) / columns
            let start = (first + step - 1) / step * step, end = (last + step - 1) / step * step
            spans.append((start, end, max(0, (end - start) / step)))
        }
        let bytes = luma.assumingMemoryBound(to: UInt8.self)
        var y = 0
        while y < h {
            let row = bytes + (y0 + y) * bytesPerRow + x0
            let cellRow = (y * rows / h) * columns
            for c in 0..<columns {
                let span = spans[c]
                var p = row + span.start
                let end = row + span.end
                var sum = 0
                while p < end {
                    sum &+= Int(p.pointee)
                    p += step
                }
                sums[cellRow + c] &+= sum
                counts[cellRow + c] &+= span.count
            }
            y += step
        }
        var cells = [UInt8](repeating: 0, count: cellCount)
        for i in 0..<cellCount where counts[i] > 0 {
            cells[i] = UInt8((sums[i] + counts[i] / 2) / counts[i])
        }
        return RegionSignature(columns: columns, rows: rows, cells: cells)
    }
}
