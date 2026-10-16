import CoreGraphics

/// A watched region is kept as a rectangle of the remote picture, 0...1 each
/// way (top-left origin), so it stays on the same part of the desktop
/// whatever the view's size or magnification.
extension PointerMapping {
    /// The smallest rectangle, in points each way, that selects a region:
    /// anything smaller was a tap, not a drag.
    public static let minimumRegionSize: CGFloat = 20

    /// `region` of the picture as a rectangle in view points: past the
    /// view's edges while magnified, like the picture.
    public func viewRect(of region: CGRect) -> CGRect {
        let r = videoRect
        return CGRect(x: r.minX + region.minX * r.width, y: r.minY + region.minY * r.height,
                      width: region.width * r.width, height: region.height * r.height)
    }

    /// A rectangle dragged out in view points as a region of the picture,
    /// cut to the picture and to what is on screen. Nil when what is left is
    /// smaller than ``minimumRegionSize`` either way, or there is no picture.
    public func region(of rect: CGRect) -> CGRect? {
        let r = videoRect
        guard r.width > 0, r.height > 0 else { return nil }
        let onScreen = rect.standardized
            .intersection(r)
            .intersection(CGRect(origin: .zero, size: viewSize))
        guard !onScreen.isNull, onScreen.width >= Self.minimumRegionSize,
              onScreen.height >= Self.minimumRegionSize else { return nil }
        return CGRect(x: (onScreen.minX - r.minX) / r.width, y: (onScreen.minY - r.minY) / r.height,
                      width: onScreen.width / r.width, height: onScreen.height / r.height)
    }
}
