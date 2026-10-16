import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import SpectreKit

/// A grey luma plane to draw on, read the way a decoded frame's is.
private struct Luma {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, value: UInt8 = 60) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: value, count: width * height)
    }

    mutating func fill(_ rect: CGRect, _ value: UInt8) {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) { bytes[y * width + x] = value }
        }
    }

    func signature(_ region: CGRect) -> RegionSignature? {
        bytes.withUnsafeBytes { buffer in
            RegionSignature.make(luma: buffer.baseAddress!, bytesPerRow: width,
                                 picture: CGSize(width: width, height: height), region: region)
        }
    }
}

private let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

@Suite("Region alerts: signatures")
struct RegionSignatureTests {
    @Test func theSamePictureIsTheSame() throws {
        let luma = Luma(width: 320, height: 200)
        let a = try #require(luma.signature(whole)), b = try #require(luma.signature(whole))
        #expect(a == b)
        #expect(!a.differs(from: b))
        #expect(a.columns == 40 && a.rows == 25) // 8-pixel cells
    }

    @Test func oneTypedCharacterIsAChange() throws {
        var luma = Luma(width: 1920, height: 1080, value: 16) // a dark terminal
        let before = try #require(luma.signature(whole))
        luma.fill(CGRect(x: 901, y: 500, width: 1, height: 12), 235) // a thin "l": 12 pixels of 2 million
        let after = try #require(luma.signature(whole))
        #expect(after.differs(from: before))
        #expect(before.columns == RegionSignature.maxCells) // 1920 / 8 is past the cap
    }

    @Test func codecNoiseIsNot() throws {
        var luma = Luma(width: 320, height: 200, value: 100)
        let before = try #require(luma.signature(whole))
        // Every pixel off by up to 2, as a re-encoded still picture might be.
        for i in luma.bytes.indices { luma.bytes[i] = UInt8(Int(luma.bytes[i]) + (i % 5) - 2) }
        #expect(!(try #require(luma.signature(whole))).differs(from: before))
    }

    @Test func onlyTheRegionCounts() throws {
        var luma = Luma(width: 400, height: 400)
        let top = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        let before = try #require(luma.signature(top))
        luma.fill(CGRect(x: 0, y: 300, width: 400, height: 100), 200) // the bottom half changes
        #expect(!(try #require(luma.signature(top))).differs(from: before))
        luma.fill(CGRect(x: 100, y: 190, width: 10, height: 9), 200) // just inside
        #expect((try #require(luma.signature(top))).differs(from: before))
    }

    @Test func aLargeRegionIsReadSparsely() throws {
        var luma = Luma(width: 3840, height: 2160)
        let before = try #require(luma.signature(whole))
        luma.fill(CGRect(x: 2000, y: 1000, width: 40, height: 40), 220)
        #expect((try #require(luma.signature(whole))).differs(from: before))
    }

    @Test func aRegionOffThePictureHasNoSignature() {
        let luma = Luma(width: 100, height: 100)
        #expect(luma.signature(CGRect(x: 1.5, y: 0, width: 0.2, height: 0.2)) == nil)
        #expect(luma.signature(CGRect(x: 0.5, y: 0.5, width: 0, height: 0.2)) == nil)
    }

    @Test func aPixelBufferIsCutToItsPicture() throws {
        // 1920x1080 coded as 1920x1088: the 8 rows of padding are not the picture.
        var pb: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 1920, 1088, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
            == kCVReturnSuccess)
        let buffer = try #require(pb)
        func setLuma(_ body: (UnsafeMutablePointer<UInt8>, Int) -> Void) throws {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
            body(base, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        }
        try setLuma { base, bpr in memset(base, 16, bpr * 1088) }
        let bottom = CGRect(x: 0, y: 0.9, width: 1, height: 0.1)
        let before = try #require(RegionSignature.make(pixelBuffer: buffer, displaySize: CGSize(width: 1920, height: 1080),
                                                        region: bottom))
        try setLuma { base, bpr in memset(base + 1080 * bpr, 235, bpr * 8) } // the padding
        #expect(!(try #require(RegionSignature.make(pixelBuffer: buffer, displaySize: CGSize(width: 1920, height: 1080),
                                                     region: bottom))).differs(from: before))
        try setLuma { base, bpr in memset(base + 1079 * bpr, 235, bpr) } // the picture's last row
        #expect((try #require(RegionSignature.make(pixelBuffer: buffer, displaySize: CGSize(width: 1920, height: 1080),
                                                    region: bottom))).differs(from: before))
    }
}

@Suite("Region alerts: when to alert")
struct RegionWatcherTests {
    private let still = RegionSignature(columns: 1, rows: 1, cells: [50])
    private let other = RegionSignature(columns: 1, rows: 1, cells: [90])

    /// Feeds signatures every 0.25 s from `start`; the times of the alerts.
    private func run(_ watcher: inout RegionWatcher, from start: TimeInterval, until end: TimeInterval,
                     _ picture: (TimeInterval) -> RegionSignature) -> [TimeInterval] {
        var alerts: [TimeInterval] = []
        for t in stride(from: start, through: end, by: 0.25) where watcher.observe(picture(t), at: t) {
            alerts.append(t)
        }
        return alerts
    }

    @Test func aRegionStillFromTheStartNeverAlertsThatItStopped() {
        var w = RegionWatcher(condition: .stopsChanging, stillSeconds: 5)
        #expect(run(&w, from: 0, until: 60) { _ in still }.isEmpty)
        #expect(w.state(at: 60) == .watching)
    }

    @Test func stoppingAfterChangesAlertsOnceAfterTheStillSpell() {
        var w = RegionWatcher(condition: .stopsChanging, stillSeconds: 5)
        // Scrolling output until 3 s, then still.
        let alerts = run(&w, from: 0, until: 30) { t in t < 3 && Int(t * 4) % 2 == 1 ? other : still }
        #expect(alerts == [8]) // the last change (back to still) at 3 s, then 5 s still
        #expect(w.state(at: 8.5) == .alerted)
        #expect(w.state(at: 13.5) == .watching)
    }

    @Test func eachStillSpellAlertsAgain() {
        var w = RegionWatcher(condition: .stopsChanging, stillSeconds: 3)
        // Changes at 1 s and at 10 s (and back).
        let alerts = run(&w, from: 0, until: 30) { t in (1..<1.5).contains(t) || (10..<10.5).contains(t) ? other : still }
        #expect(alerts == [4.5, 13.5])
    }

    @Test func startingToChangeNeedsAStillSpellFirst() {
        var w = RegionWatcher(condition: .startsChanging, stillSeconds: 5)
        // Changing from the start until 2 s: no alert; still until 10 s, then a change.
        let alerts = run(&w, from: 0, until: 20) { t in
            (t < 2 && Int(t * 4) % 2 == 1) || t >= 10 ? other : still
        }
        #expect(alerts == [10])
        #expect(w.state(at: 10.5) == .alerted)
    }

    @Test func afterAnAlertTheRegionMustSettleAgain() {
        var w = RegionWatcher(condition: .startsChanging, stillSeconds: 5)
        // Still, then changing every other look from 6 s to 8 s, still, and a change at 20 s.
        let alerts = run(&w, from: 0, until: 25) { t in
            ((6..<8).contains(t) && Int(t * 4) % 2 == 0) || t >= 20 ? other : still
        }
        #expect(alerts == [6, 20]) // 6.5, 7 … are the same burst; 7.75 to 20 is the next still spell
    }

    @Test func theOutlineShowsChangesForASecond() {
        var w = RegionWatcher(condition: .stopsChanging, stillSeconds: 60)
        _ = w.observe(still, at: 0)
        _ = w.observe(other, at: 1)
        #expect(w.state(at: 1.5) == .changing)
        #expect(w.state(at: 2.1) == .watching)
    }

    @Test func aChangeAfterTheAlertEndsIt() {
        var w = RegionWatcher(condition: .stopsChanging, stillSeconds: 1)
        _ = w.observe(still, at: 0)
        _ = w.observe(other, at: 1)
        let fired = w.observe(other, at: 2)
        #expect(fired)
        #expect(w.state(at: 2.5) == .alerted)
        _ = w.observe(still, at: 3)
        #expect(w.state(at: 3.5) == .changing)
        #expect(w.state(at: 4.5) == .watching) // not back to the alert's green
    }

    @Test func dismissingTheAlertEndsIt() {
        var w = RegionWatcher(condition: .startsChanging, stillSeconds: 1)
        _ = w.observe(still, at: 0)
        _ = w.observe(still, at: 1)
        let fired1 = w.observe(other, at: 2)
        #expect(fired1)
        w.dismissAlert()
        #expect(w.state(at: 2.5) == .changing)
    }

    @Test func aPictureOfADifferentSizeIsNotAChange() {
        var w = RegionWatcher(condition: .startsChanging, stillSeconds: 1)
        _ = w.observe(still, at: 0)
        _ = w.observe(still, at: 2)
        let fired = w.observe(RegionSignature(columns: 2, rows: 1, cells: [0, 255]), at: 3)
        #expect(!fired)
        #expect(w.state(at: 3) == .watching)
    }

    @Test func aGapStartsTheStillSpellOver() {
        var w = RegionWatcher(condition: .stopsChanging, stillSeconds: 5)
        _ = w.observe(still, at: 0)
        _ = w.observe(other, at: 1) // armed
        w.resume(at: 100) // back from the background
        let fired2 = w.observe(other, at: 100)
        #expect(!fired2)
        let fired3 = w.observe(other, at: 104.75)
        #expect(!fired3)
        let fired4 = w.observe(other, at: 105)
        #expect(fired4)
    }

    @Test func aChangeDuringAGapShowsOnReturn() {
        var w = RegionWatcher(condition: .startsChanging, stillSeconds: 5)
        _ = w.observe(still, at: 0)
        _ = w.observe(still, at: 6) // armed
        w.resume(at: 100)
        let fired5 = w.observe(other, at: 100)
        #expect(fired5)
    }
}

@Suite("Region alerts: on screen")
struct PictureRegionTests {
    /// 1920x1080 in a 1000x1000 view: 1000x562.5 letterboxed, 218.75 from the top.
    private var mapping: PointerMapping {
        PointerMapping(viewSize: CGSize(width: 1000, height: 1000), backingScale: 1,
                       videoSize: CGSize(width: 1920, height: 1080))
    }

    @Test func aDraggedRectangleBecomesARegionAndBack() throws {
        let m = mapping
        let fit = m.videoRect
        let rect = CGRect(x: 100, y: fit.minY + 50, width: 200, height: 100)
        let region = try #require(m.region(of: rect))
        #expect(abs(region.minX - 0.1) < 0.002 && abs(region.width - 0.2) < 0.002)
        let back = m.viewRect(of: region)
        #expect(abs(back.minX - rect.minX) < 1 && abs(back.minY - rect.minY) < 1)
        #expect(abs(back.width - rect.width) < 1 && abs(back.height - rect.height) < 1)
    }

    @Test func draggingUpwardsCounts() throws {
        let m = mapping
        let y = m.videoRect.minY
        #expect(m.region(of: CGRect(x: 300, y: y + 150, width: -200, height: -100))
            == m.region(of: CGRect(x: 100, y: y + 50, width: 200, height: 100)))
    }

    @Test func theBlackBarsAreCutOff() throws {
        let m = mapping
        let region = try #require(m.region(of: CGRect(x: 0, y: 0, width: 500, height: 400)))
        #expect(region.minY == 0) // starts at the picture's top edge, not the bar's
    }

    @Test func aTapIsNotARegion() {
        let m = mapping
        let y = m.videoRect.minY
        #expect(m.region(of: CGRect(x: 100, y: y + 10, width: 19, height: 300)) == nil)
        #expect(m.region(of: CGRect(x: 100, y: y + 10, width: 300, height: 19)) == nil)
        #expect(m.region(of: CGRect(x: 0, y: 0, width: 500, height: 235)) == nil) // about 16 of it on the picture
    }

    @Test func theRegionFollowsTheMagnifiedPicture() throws {
        var m = mapping
        let region = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        let before = m.viewRect(of: region)
        m.zoom.zoom(by: 2, anchor: CGPoint(x: 500, y: 500), fit: m.fitRect, view: m.viewSize, maxScale: 4)
        let after = m.viewRect(of: region)
        #expect(abs(after.width - 2 * before.width) < 0.01)
        #expect(abs(after.minX - 500) < 0.01) // the picture's centre stayed under the anchor
        // A drag over the magnified picture is a region of the picture, not of the view.
        let dragged = try #require(m.region(of: after))
        #expect(abs(dragged.minX - 0.5) < 0.001 && abs(dragged.width - 0.1) < 0.001)
    }
}

