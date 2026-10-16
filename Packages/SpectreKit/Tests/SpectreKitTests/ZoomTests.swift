import CoreGraphics
import Foundation
import Testing
@testable import SpectreKit

/// A 1000x500 view with the picture fitted to all of it: numbers stay exact.
private let view = CGSize(width: 1000, height: 500)
private let fit = CGRect(x: 0, y: 0, width: 1000, height: 500)

@Suite("Magnifying the picture")
struct PictureZoomTests {
    @Test func fitIsTheFittedPicture() {
        #expect(PictureZoom.fit.rect(fit: CGRect(x: 0, y: 100, width: 1000, height: 300), view: view)
            == CGRect(x: 0, y: 100, width: 1000, height: 300))
        #expect(!PictureZoom.fit.isZoomed)
    }

    @Test func zoomKeepsThePointUnderTheAnchor() {
        var z = PictureZoom.fit
        z.zoom(by: 2, anchor: CGPoint(x: 250, y: 125), fit: fit, view: view, maxScale: 4)
        let r = z.rect(fit: fit, view: view)
        #expect(r.size == CGSize(width: 2000, height: 1000))
        // The picture's (0.25, 0.25) stays at (250, 125).
        #expect(r.minX + 0.25 * r.width == 250)
        #expect(r.minY + 0.25 * r.height == 125)
    }

    @Test func zoomStaysBetweenFitAndTheMaximum() {
        var z = PictureZoom.fit
        z.zoom(by: 10, anchor: CGPoint(x: 500, y: 250), fit: fit, view: view, maxScale: 3)
        #expect(z.scale == 3)
        z.zoom(by: 0.01, anchor: CGPoint(x: 500, y: 250), fit: fit, view: view, maxScale: 3)
        #expect(z == .fit)
    }

    @Test func aMagnifiedPictureNeverUncoversTheView() {
        var z = PictureZoom.fit
        z.zoom(by: 2, anchor: CGPoint(x: 0, y: 0), fit: fit, view: view, maxScale: 4)
        #expect(z.rect(fit: fit, view: view).origin == .zero)
        z.pan(by: CGPoint(x: 300, y: 300), fit: fit, view: view) // past the top-left corner: held there
        #expect(z.rect(fit: fit, view: view).origin == .zero)
        z.pan(by: CGPoint(x: -5000, y: -5000), fit: fit, view: view)
        #expect(z.rect(fit: fit, view: view).origin == CGPoint(x: -1000, y: -500))
        z.pan(by: CGPoint(x: 100, y: 0), fit: fit, view: view) // and back from the far edge at once
        #expect(z.rect(fit: fit, view: view).origin == CGPoint(x: -900, y: -500))
    }

    @Test func aSideSmallerThanTheViewStaysCentred() {
        let tall = CGRect(x: 375, y: 0, width: 250, height: 500) // a portrait picture in a wide view
        var z = PictureZoom.fit
        z.zoom(by: 2, anchor: CGPoint(x: 400, y: 250), fit: tall, view: view, maxScale: 4)
        let r = z.rect(fit: tall, view: view)
        #expect(r.width == 500)
        #expect(r.minX == 250) // 500 wide in 1000: centred, whatever the anchor
        z.pan(by: CGPoint(x: 100, y: 0), fit: tall, view: view)
        #expect(z.rect(fit: tall, view: view).minX == 250)
    }

    @Test func fillingCoversTheViewAroundAPosition() {
        let wide = CGRect(x: 0, y: 125, width: 1000, height: 250) // letterboxed top and bottom
        let z = PictureZoom.filling(fit: wide, view: view, at: CGPoint(x: 0.75, y: 0.5), maxScale: 4)
        #expect(z.scale == 2)
        let r = z.rect(fit: wide, view: view)
        #expect(r == CGRect(x: -1000, y: 0, width: 2000, height: 500)) // the right half, as far as it goes
        // A picture the view's shape fills it already: 2x instead.
        #expect(PictureZoom.filling(fit: fit, view: view, at: CGPoint(x: 0.5, y: 0.5), maxScale: 4).scale == 2)
    }

    @Test func theMaximumIsFourDevicePixelsAPixel() {
        // 1920 remote pixels in 960 points at 2x: one device pixel each, so 4x.
        #expect(PictureZoom.maxScale(fit: CGRect(x: 0, y: 0, width: 960, height: 540), videoWidth: 1920,
                                     backingScale: 2) == 4)
        // Already four device pixels a remote pixel: no magnifying at all.
        #expect(PictureZoom.maxScale(fit: CGRect(x: 0, y: 0, width: 800, height: 600), videoWidth: 400,
                                     backingScale: 2) == 1)
    }

    @Test func thePointerMapsThroughTheMagnifiedPicture() {
        var m = PointerMapping(viewSize: CGSize(width: 1024, height: 512), backingScale: 2,
                               videoSize: CGSize(width: 2048, height: 1024))
        m.zoom = PictureZoom(scale: 2, center: CGPoint(x: 0.5, y: 0.5))
        #expect(m.videoRect == CGRect(x: -512, y: -256, width: 2048, height: 1024))
        #expect(m.fitRect == CGRect(x: 0, y: 0, width: 1024, height: 512))
        #expect(m.normalized(CGPoint(x: 0, y: 0)).position == CGPoint(x: 0.25, y: 0.25))
        #expect(m.viewPoint(CGPoint(x: 0.5, y: 0.5)) == CGPoint(x: 512, y: 256))
        #expect(m.pointsPerVideoPixel == 1)
    }

    @Test func theRendererDrawsTheSameRectangleInPixels() {
        let z = PictureZoom(scale: 2, center: CGPoint(x: 0.5, y: 0.5))
        let v = VideoRenderer.viewport(video: CGSize(width: 2048, height: 1024),
                                       drawable: CGSize(width: 2048, height: 1024), zoom: z)
        #expect(v.originX == -1024 && v.originY == -512 && v.width == 4096 && v.height == 2048)
    }

    @MainActor @Test func theInputMagnifiesFillsAndGoesBack() async throws {
        let input = SessionInput(sink: RecordingSink())
        input.pictureChanged(CGSize(width: 2048, height: 1024))
        input.viewChanged(PointerMapping(viewSize: CGSize(width: 1024, height: 1024), backingScale: 2,
                                         videoSize: CGSize(width: 2048, height: 1024)))
        input.pinch(factor: 1.5, anchor: CGPoint(x: 512, y: 512), pan: .zero)
        #expect(input.zoom.scale == 1.5)
        input.toggleFill() // magnified: back to fitting
        try await Task.sleep(for: .milliseconds(400))
        #expect(input.zoom == .fit)
        input.toggleFill() // a wide picture in a square view: fills its height
        try await Task.sleep(for: .milliseconds(400))
        #expect(input.zoom.scale == 2)
        input.pictureChanged(CGSize(width: 1920, height: 1080)) // a new picture starts fitted
        #expect(input.zoom == .fit)
    }
}

@Suite("Touch to pointer: pinch")
struct PinchTests {
    let mapping = PointerMapping(viewSize: CGSize(width: 1024, height: 512), backingScale: 2,
                                 videoSize: CGSize(width: 2048, height: 1024))

    private func t(_ id: Int, _ x: CGFloat, _ y: CGFloat) -> TouchPointerMapper.Touch {
        TouchPointerMapper.Touch(id: id, location: CGPoint(x: x, y: y))
    }

    @Test func spreadingFingersZoomAndNeverScroll() {
        var m = TouchPointerMapper(mode: .trackpad, mapping: mapping)
        _ = m.began([t(1, 400, 256), t(2, 600, 256)], at: 0)
        // Apart by 40 points, the middle unmoved: a pinch.
        let first = m.moved([t(1, 380, 256), t(2, 620, 256)], at: 0.1)
        #expect(first == [.zoom(factor: 1.2, anchor: CGPoint(x: 500, y: 256), pan: .zero)])
        // Then both slide down together: still the pinch, moving the picture.
        let next = m.moved([t(1, 380, 286), t(2, 620, 286)], at: 0.2)
        #expect(next == [.zoom(factor: 1, anchor: CGPoint(x: 500, y: 286), pan: CGPoint(x: 0, y: 30))])
        _ = m.ended([t(1, 380, 286), t(2, 620, 286)], at: 0.3)
    }

    @Test func movingTogetherStillScrolls() {
        var m = TouchPointerMapper(mode: .trackpad, mapping: mapping)
        _ = m.began([t(1, 400, 256), t(2, 600, 256)], at: 0)
        let actions = m.moved([t(1, 400, 232), t(2, 600, 232)], at: 0.1)
        #expect(actions == [.scroll(horizontal: 0, vertical: 1)])
    }

    @Test func aDirectDragFollowsThePictureUnderIt() {
        var m = TouchPointerMapper(mode: .direct, mapping: mapping)
        _ = m.began([t(1, 512, 256)], at: 0)
        _ = m.moved([t(1, 530, 256)], at: 0.2)
        #expect(m.trackedPoint == CGPoint(x: 530, y: 256))
        var moved = mapping
        moved.zoom = PictureZoom(scale: 2, center: CGPoint(x: 0.5, y: 0.5))
        // The finger is still at (530, 256); the picture under it is magnified.
        let actions = m.pictureMoved(moved)
        #expect(actions == [.move(moved.normalized(CGPoint(x: 530, y: 256)).position)])
    }
}
