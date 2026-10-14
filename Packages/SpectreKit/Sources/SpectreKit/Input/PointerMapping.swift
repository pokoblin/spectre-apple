import CoreGraphics

/// Where the picture sits in the video view, and the conversion between a
/// point in the view and a position on the remote output (0...1 each way,
/// (0, 0) at the top left, gdp-spec.md §8.2).
///
/// The picture is drawn into ``VideoRenderer/fitViewport(video:drawable:)``,
/// which is computed and rounded in drawable pixels, so the mapping goes
/// through the same pixels: whatever the renderer letterboxes, the pointer
/// letterboxes too.
public struct PointerMapping: Sendable, Equatable {
    /// The view's size in points.
    public var viewSize: CGSize
    /// Drawable pixels per point (the backing scale factor).
    public var backingScale: CGFloat
    /// The remote output's size in pixels (the picture's display size, §7.2).
    public var videoSize: CGSize

    public init(viewSize: CGSize, backingScale: CGFloat, videoSize: CGSize) {
        self.viewSize = viewSize
        self.backingScale = backingScale
        self.videoSize = videoSize
    }

    /// The picture's rectangle in view points, top-left origin.
    public var videoRect: CGRect {
        let scale = backingScale > 0 ? backingScale : 1
        let drawable = CGSize(width: (viewSize.width * scale).rounded(), height: (viewSize.height * scale).rounded())
        let v = VideoRenderer.fitViewport(video: videoSize, drawable: drawable)
        return CGRect(x: v.originX / scale, y: v.originY / scale, width: v.width / scale, height: v.height / scale)
    }

    /// View points per remote pixel: how large one host pixel (a cursor's,
    /// a relative motion's) appears.
    public var pointsPerVideoPixel: CGFloat {
        guard videoSize.width > 0 else { return 1 }
        return videoRect.width / videoSize.width
    }

    /// A view point (top-left origin) as a position on the output, clamped
    /// to 0...1, and whether it was on the picture rather than a bar.
    public func normalized(_ point: CGPoint) -> (position: CGPoint, inside: Bool) {
        let r = videoRect
        guard videoSize.width > 0, videoSize.height > 0, r.width > 0, r.height > 0 else {
            return (CGPoint(x: 0.5, y: 0.5), false) // no picture yet
        }
        let x = (point.x - r.minX) / r.width
        let y = (point.y - r.minY) / r.height
        let inside = (0...1).contains(x) && (0...1).contains(y)
        return (CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)), inside)
    }

    /// The view point (top-left origin) of a position on the output.
    public func viewPoint(_ position: CGPoint) -> CGPoint {
        let r = videoRect
        return CGPoint(x: r.minX + position.x * r.width, y: r.minY + position.y * r.height)
    }
}
