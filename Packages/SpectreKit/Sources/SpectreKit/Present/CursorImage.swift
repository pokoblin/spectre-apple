import CoreGraphics
import Foundation
import GDPKit
#if os(macOS)
import AppKit
#endif

/// The host's pointer image (gdp-spec.md §7.4), validated and ready to
/// draw: as a `CGImage` (for `NSCursor`) and as BGRA bytes (for a Metal
/// texture). Immutable.
///
/// The bytes are B, G, R, A in memory (a little-endian ARGB value), alpha
/// premultiplied, non-linear sRGB, rows top to bottom, tightly packed. A
/// 0×0 image is the host hiding the pointer: ``isHidden``, nothing is drawn.
public struct CursorImage: @unchecked Sendable, Equatable {
    /// The largest side the host may send; a larger shape is ignored (§7.4).
    public static let maxSide = 384

    /// No cursor (the host hid it).
    public static let hidden = CursorImage(validatedWidth: 0, height: 0, hotspot: .zero, bgra: [])

    /// Pixels.
    public let width: Int
    public let height: Int
    /// The pixel whose top-left corner sits at the pointer's position,
    /// from the image's top left; clamped into the image.
    public let hotspot: CGPoint
    /// Premultiplied BGRA, `width × height × 4` bytes.
    public let bgra: [UInt8]
    /// The same pixels as an sRGB image; nil when hidden.
    public let cgImage: CGImage?

    public var isHidden: Bool { width == 0 }

    /// nil for a shape the client must ignore: a side over 384, one side
    /// zero but not the other, or a byte count that does not match the size.
    public init?(_ shape: GDPSession.CursorShape) {
        // UInt32 → Int cannot overflow on arm64; the size check bounds the rest.
        self.init(width: Int(shape.width), height: Int(shape.height), hotspotX: Int(shape.hotspotX),
                  hotspotY: Int(shape.hotspotY), bgra: shape.bgra)
    }

    public init?(width: Int, height: Int, hotspotX: Int, hotspotY: Int, bgra: [UInt8]) {
        guard (0...Self.maxSide).contains(width), (0...Self.maxSide).contains(height),
              (width == 0) == (height == 0), bgra.count == width * height * 4
        else { return nil }
        let hotspot = CGPoint(x: min(max(hotspotX, 0), max(width - 1, 0)),
                              y: min(max(hotspotY, 0), max(height - 1, 0)))
        self.init(validatedWidth: width, height: height, hotspot: hotspot, bgra: bgra)
    }

    private init(validatedWidth width: Int, height: Int, hotspot: CGPoint, bgra: [UInt8]) {
        self.width = width
        self.height = height
        self.hotspot = hotspot
        self.bgra = bgra
        cgImage = width == 0 ? nil : Self.makeCGImage(width: width, height: height, bgra: bgra)
    }

    /// Premultiplied BGRA in memory is CoreGraphics' premultipliedFirst +
    /// byteOrder32Little; the provider owns a copy of the bytes.
    private static func makeCGImage(width: Int, height: Int, bgra: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    public static func == (a: CursorImage, b: CursorImage) -> Bool {
        a.width == b.width && a.height == b.height && a.hotspot == b.hotspot && a.bgra == b.bgra
    }
}

extension CursorImage {
    /// Bounds on a system cursor's larger side, in points: a host pixel can
    /// be tiny (a 4K output in a small window) or huge (a small output
    /// full screen), and a cursor scaled with the picture would vanish or
    /// cover it. Past these the cursor stops scaling with the picture.
    public static let systemCursorPoints: ClosedRange<CGFloat> = 8...256

    /// Points per cursor pixel for a system cursor: `pointsPerPixel`
    /// (``PointerMapping/pointsPerVideoPixel``, so the cursor matches the
    /// picture) unless that puts the larger side outside
    /// ``systemCursorPoints``, then the scale that puts it on the bound.
    public func systemCursorScale(pointsPerPixel: CGFloat) -> CGFloat {
        let scale = pointsPerPixel.isFinite && pointsPerPixel > 0 ? pointsPerPixel : 1
        let side = CGFloat(max(width, height))
        guard side > 0 else { return scale }
        let bounds = Self.systemCursorPoints
        return min(max(side * scale, bounds.lowerBound), bounds.upperBound) / side
    }
}

#if os(macOS)
extension CursorImage {
    /// The image as an `NSCursor` of `width × height` pixels at
    /// ``systemCursorScale(pointsPerPixel:)`` points each, hotspot scaled
    /// likewise. A hidden image gives a transparent 1×1-point cursor (rather
    /// than `NSCursor.hide()`, a global counter that outlives the view).
    /// Not cached: the caller keeps one per image and scale.
    @MainActor
    public func nsCursor(pointsPerPixel: CGFloat) -> NSCursor {
        guard let cgImage else {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)
            let image = NSImage(size: NSSize(width: 1, height: 1))
            if let rep {
                rep.bitmapData?.initialize(repeating: 0, count: 4)
                rep.size = image.size
                image.addRepresentation(rep)
            }
            return NSCursor(image: image, hotSpot: .zero)
        }
        let scale = systemCursorScale(pointsPerPixel: pointsPerPixel)
        let size = NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        // The rep keeps the source pixels; its size in points sets the scale.
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        // NSCursor's hot spot is measured from the image's top left, like §7.4's.
        return NSCursor(image: image, hotSpot: NSPoint(x: hotspot.x * scale, y: hotspot.y * scale))
    }
}
#endif
