import CoreGraphics

/// How far the picture is magnified past fitting the view, and which part
/// of it is in view: the renderer's viewport and the pointer's mapping both
/// go through it, so what is drawn, where the cursor is drawn and where a
/// touch lands stay the same place.
///
/// `scale` 1 is the fitted picture. `center` is the point of the picture
/// (0...1 each way) at the view's centre; it is kept where the picture
/// covers the view, so that no black shows on a side the picture is larger
/// than. Sizes are in whatever unit `fit` and `view` share (drawable pixels
/// for the renderer, points for the pointer).
public struct PictureZoom: Sendable, Equatable {
    public var scale: CGFloat
    public var center: CGPoint

    public static let fit = PictureZoom(scale: 1, center: CGPoint(x: 0.5, y: 0.5))

    public init(scale: CGFloat, center: CGPoint) {
        self.scale = scale
        self.center = center
    }

    public var isZoomed: Bool { scale > 1.001 }

    /// The magnified picture's rectangle: `fit` (the fitted picture in the
    /// view) grown by `scale`, placed so that `center` is in the middle of
    /// the view, without uncovering the view along an axis it fills.
    public func rect(fit: CGRect, view: CGSize) -> CGRect {
        guard isZoomed else { return fit }
        let w = fit.width * scale, h = fit.height * scale
        return CGRect(x: Self.place(length: w, in: view.width, center: center.x),
                      y: Self.place(length: h, in: view.height, center: center.y), width: w, height: h)
    }

    private static func place(length: CGFloat, in view: CGFloat, center: CGFloat) -> CGFloat {
        guard length > view else { return (view - length) / 2 } // smaller than the view: centred
        return min(0, max(view - length, view / 2 - center * length))
    }

    /// `center` as the clamped rectangle has it, so a later pan starts from
    /// what is on screen.
    private mutating func settle(fit: CGRect, view: CGSize) {
        guard isZoomed else { self = .fit; return }
        let r = rect(fit: fit, view: view)
        center = CGPoint(x: (view.width / 2 - r.minX) / r.width, y: (view.height / 2 - r.minY) / r.height)
    }

    /// Magnifies by `factor` (a pinch's spread ratio) keeping the picture
    /// under `anchor` (view units) where it is, between 1 and `maxScale`.
    public mutating func zoom(by factor: CGFloat, anchor: CGPoint, fit: CGRect, view: CGSize, maxScale: CGFloat) {
        let r = rect(fit: fit, view: view)
        guard r.width > 0, r.height > 0, factor > 0 else { return }
        let under = CGPoint(x: (anchor.x - r.minX) / r.width, y: (anchor.y - r.minY) / r.height)
        scale = min(max(scale * factor, 1), max(maxScale, 1))
        let w = fit.width * scale, h = fit.height * scale
        center = CGPoint(x: (view.width / 2 - (anchor.x - under.x * w)) / w,
                         y: (view.height / 2 - (anchor.y - under.y * h)) / h)
        settle(fit: fit, view: view)
    }

    /// Moves the picture by `delta` (view units), as a finger drags it.
    public mutating func pan(by delta: CGPoint, fit: CGRect, view: CGSize) {
        guard isZoomed else { return }
        let r = rect(fit: fit, view: view)
        center = CGPoint(x: (view.width / 2 - (r.minX + delta.x)) / r.width,
                         y: (view.height / 2 - (r.minY + delta.y)) / r.height)
        settle(fit: fit, view: view)
    }

    /// Magnified until the picture covers the view, `position` (0...1 on
    /// the picture) in the middle as far as the edges allow. A picture
    /// already the view's shape is magnified 2x instead.
    public static func filling(fit: CGRect, view: CGSize, at position: CGPoint, maxScale: CGFloat) -> PictureZoom {
        guard fit.width > 0, fit.height > 0 else { return .fit }
        var scale = max(view.width / fit.width, view.height / fit.height)
        if scale < 1.05 { scale = 2 }
        var zoom = PictureZoom(scale: min(scale, max(maxScale, 1)), center: position)
        zoom.settle(fit: fit, view: view)
        return zoom
    }

    /// The largest magnification: one remote pixel about four device pixels
    /// across (never less than fitting).
    public static func maxScale(fit: CGRect, videoWidth: CGFloat, backingScale: CGFloat) -> CGFloat {
        guard fit.width > 0, videoWidth > 0 else { return 1 }
        let devicePixelsPerRemotePixel = fit.width * max(backingScale, 1) / videoWidth
        return max(1, 4 / devicePixelsPerRemotePixel)
    }

    /// Part way from `self` to `target`, for an animation (`t` 0...1).
    public func interpolated(to target: PictureZoom, _ t: CGFloat) -> PictureZoom {
        PictureZoom(scale: scale + (target.scale - scale) * t,
                    center: CGPoint(x: center.x + (target.center.x - center.x) * t,
                                    y: center.y + (target.center.y - center.y) * t))
    }
}
