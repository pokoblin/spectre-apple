import CoreGraphics
import Foundation
import Testing
@testable import SpectreKit

typealias Mapper = TouchPointerMapper
typealias Action = TouchPointerAction

private let left = PointerButton.left
private let right = PointerButton.right
private let middle = PointerButton.middle

/// The picture fills a 1024x512 pt view exactly: a view point (x, y) is
/// output position (x / 1024, y / 512), and every number below stays exact.
private let fullView = PointerMapping(viewSize: CGSize(width: 1024, height: 512), backingScale: 2,
                                      videoSize: CGSize(width: 2048, height: 1024))

private func t(_ id: Int, _ x: CGFloat, _ y: CGFloat) -> Mapper.Touch {
    Mapper.Touch(id: id, location: CGPoint(x: x, y: y))
}

private func pos(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func press(_ b: UInt32) -> Action { .button(b, pressed: true) }
private func release(_ b: UInt32) -> Action { .button(b, pressed: false) }

@Suite("Touch to pointer: direct mode")
struct DirectTouchTests {
    var m = Mapper(mode: .direct, mapping: fullView)

    @Test mutating func tapClicksWhereTouched() {
        #expect(m.began([t(1, 256, 128)], at: 10) == [])
        #expect(m.nextDeadline == 10.5)
        #expect(m.moved([t(1, 260, 131)], at: 10.05) == [])  // under the slop
        #expect(m.ended([t(1, 262, 133)], at: 10.2) == [.move(pos(0.25, 0.25)), press(left), release(left)])
        #expect(m.cursor == pos(0.25, 0.25))
        #expect(m.nextDeadline == nil)
    }

    @Test mutating func slowLiftIsNotATap() {
        _ = m.began([t(1, 256, 128)], at: 0)
        #expect(m.update(at: 0.4) == [])
        #expect(m.ended([t(1, 256, 128)], at: 0.4) == [])
    }

    @Test mutating func doubleTapReusesTheFirstPosition() {
        _ = m.began([t(1, 256, 128)], at: 0)
        #expect(m.ended([t(1, 256, 128)], at: 0.1) == [.move(pos(0.25, 0.25)), press(left), release(left)])
        _ = m.began([t(2, 272, 140)], at: 0.3)
        #expect(m.ended([t(2, 272, 140)], at: 0.4) == [.move(pos(0.25, 0.25)), press(left), release(left)])
        // A third tap chains onto the same spot: a triple-click.
        _ = m.began([t(3, 240, 120)], at: 0.6)
        #expect(m.ended([t(3, 240, 120)], at: 0.7) == [.move(pos(0.25, 0.25)), press(left), release(left)])
    }

    @Test mutating func farOrLateSecondTapIsItsOwnTap() {
        _ = m.began([t(1, 256, 128)], at: 0)
        _ = m.ended([t(1, 256, 128)], at: 0.1)
        _ = m.began([t(2, 512, 128)], at: 0.2)  // too far
        #expect(m.ended([t(2, 512, 128)], at: 0.3) == [.move(pos(0.5, 0.25)), press(left), release(left)])
        _ = m.began([t(3, 520, 128)], at: 0.3 + 0.4)  // too late
        #expect(m.ended([t(3, 520, 128)], at: 0.8) == [.move(pos(520.0 / 1024, 0.25)), press(left), release(left)])
    }

    @Test mutating func gestureBetweenTapsBreaksTheDoubleTap() {
        _ = m.began([t(1, 256, 128)], at: 0)
        _ = m.ended([t(1, 256, 128)], at: 0.05)
        _ = m.began([t(2, 256, 128), t(3, 288, 128)], at: 0.1)
        _ = m.ended([t(2, 256, 128), t(3, 288, 128)], at: 0.15)  // two-finger tap
        _ = m.began([t(4, 264, 128)], at: 0.2)
        #expect(m.ended([t(4, 264, 128)], at: 0.25) == [.move(pos(264.0 / 1024, 0.25)), press(left), release(left)])
    }

    @Test mutating func dragPressesAtTouchDownAndFollows() {
        _ = m.began([t(1, 256, 128)], at: 0)
        // Past the slop but inside the grace period: held back.
        #expect(m.moved([t(1, 256, 148)], at: 0.05) == [])
        #expect(m.nextDeadline == 0.1)
        #expect(m.moved([t(1, 256, 192)], at: 0.15) == [.move(pos(0.25, 0.25)), press(left), .move(pos(0.25, 0.375))])
        #expect(m.nextDeadline == nil)
        #expect(m.moved([t(1, 512, 256)], at: 0.2) == [.move(pos(0.5, 0.5))])
        #expect(m.update(at: 1) == [])  // no long press once dragging
        #expect(m.ended([t(1, 768, 256)], at: 1.2) == [.move(pos(0.75, 0.5)), release(left)])
    }

    @Test mutating func dragCommitsFromTheTimerWhenTheFingerStops() {
        _ = m.began([t(1, 256, 128)], at: 0)
        _ = m.moved([t(1, 256, 160)], at: 0.05)
        #expect(m.update(at: 0.08) == [])
        #expect(m.update(at: 0.1) == [.move(pos(0.25, 0.25)), press(left), .move(pos(0.25, 0.3125))])
        #expect(m.ended([t(1, 256, 160)], at: 0.3) == [release(left)])
    }

    @Test mutating func flickInsideTheGraceIsAShortDrag() {
        _ = m.began([t(1, 256, 128)], at: 0)
        _ = m.moved([t(1, 256, 160)], at: 0.03)
        #expect(m.ended([t(1, 256, 192)], at: 0.06)
                == [.move(pos(0.25, 0.25)), press(left), .move(pos(0.25, 0.375)), release(left)])
    }

    @Test mutating func cancelledDragReleases() {
        _ = m.began([t(1, 256, 128)], at: 0)
        _ = m.moved([t(1, 256, 192)], at: 0.2)
        #expect(m.cancelled([t(1, 300, 300)], at: 0.3) == [release(left)])
        #expect(m.ended([t(1, 300, 300)], at: 0.3) == [])
        #expect(m.reset() == [])
    }

    @Test mutating func cancelledTouchIsNoTap() {
        _ = m.began([t(1, 256, 128)], at: 0)
        #expect(m.cancelled([t(1, 256, 128)], at: 0.1) == [])
        #expect(m.nextDeadline == nil)
    }

    @Test mutating func rapidMovesOnlyMove() {
        _ = m.began([t(1, 0, 0)], at: 0)
        var out: [Action] = []
        for i in 1...100 {
            out += m.moved([t(1, CGFloat(i) * 4, 0)], at: 0.1 + Double(i) * 0.008)
        }
        out += m.ended([t(1, 400, 0)], at: 1)
        let buttons = out.filter { if case .button = $0 { true } else { false } }
        #expect(buttons == [press(left), release(left)])
        #expect(out.first == .move(pos(0, 0)))
        #expect(out.count == 1 + 1 + 98 + 1)  // touch-down point, press, each move from the 3rd, release
        #expect(m.cursor == pos(400.0 / 1024, 0))
    }

    @Test mutating func longPressRightClicksFromTheTimer() {
        _ = m.began([t(1, 256, 128)], at: 0)
        _ = m.moved([t(1, 260, 128)], at: 0.2)
        #expect(m.update(at: 0.49) == [])
        #expect(m.update(at: 0.5) == [.longPress, .move(pos(0.25, 0.25)), press(right), release(right)])
        #expect(m.nextDeadline == nil)
        #expect(m.update(at: 0.6) == [])
        // The finger is spent: moving and lifting do nothing.
        #expect(m.moved([t(1, 512, 256)], at: 0.7) == [])
        #expect(m.ended([t(1, 512, 256)], at: 0.8) == [])
    }

    @Test mutating func longPressFiresOnLiftWhenTheTimerWasLate() {
        _ = m.began([t(1, 256, 128)], at: 0)
        #expect(m.ended([t(1, 256, 128)], at: 0.7) == [.longPress, .move(pos(0.25, 0.25)), press(right), release(right)])
    }

    @Test mutating func letterboxClampsOntoThePicture() {
        // A 2:1 picture in a square view: bars of 256 pt above and below.
        m.mapping = PointerMapping(viewSize: CGSize(width: 1024, height: 1024), backingScale: 2,
                                   videoSize: CGSize(width: 2048, height: 1024))
        _ = m.began([t(1, 512, 100)], at: 0)
        #expect(m.ended([t(1, 512, 100)], at: 0.1) == [.move(pos(0.5, 0)), press(left), release(left)])
        _ = m.began([t(2, 256, 512)], at: 1)
        _ = m.moved([t(2, 256, 1000)], at: 1.2)
        #expect(m.ended([t(2, 256, 1000)], at: 1.3) == [release(left)])
        #expect(m.cursor == pos(0.25, 1))
    }

    @Test mutating func twoFingerPanScrolls() {
        _ = m.began([t(1, 256, 256), t(2, 320, 256)], at: 0)
        #expect(m.nextDeadline == nil)
        // Fingers up 48 pt: content follows, two notches down. The pointer
        // first goes to the fingers' centroid.
        #expect(m.moved([t(1, 256, 208), t(2, 320, 208)], at: 0.05)
                == [.move(pos(288.0 / 1024, 0.5)), .scroll(horizontal: 0, vertical: 2)])
        // Fingers left 12 pt: half a notch right.
        #expect(m.moved([t(1, 244, 208), t(2, 308, 208)], at: 0.1) == [.scroll(horizontal: 0.5, vertical: 0)])
        // One finger moving moves the centroid by half: a quarter notch up.
        #expect(m.moved([t(2, 308, 220)], at: 0.15) == [.scroll(horizontal: 0, vertical: -0.25)])
        #expect(m.update(at: 1) == [])
        // A finger lifts: the scroll is over, the other finger does nothing.
        #expect(m.ended([t(1, 244, 208)], at: 1.1) == [])
        #expect(m.moved([t(2, 400, 400)], at: 1.2) == [])
        #expect(m.ended([t(2, 400, 400)], at: 1.3) == [])
    }

    @Test mutating func scrollCountsTravelFromTouchDown() {
        _ = m.began([t(1, 100, 100), t(2, 200, 100)], at: 0)
        #expect(m.moved([t(1, 100, 106)], at: 0.02) == [])     // under the slop
        #expect(m.moved([t(1, 100, 112)], at: 0.04)
                == [.move(pos(150.0 / 1024, 100.0 / 512)), .scroll(horizontal: 0, vertical: -0.25)])
        #expect(m.moved([t(2, 200, 106)], at: 0.06) == [.scroll(horizontal: 0, vertical: -0.125)])
    }

    @Test mutating func secondFingerWithinGraceMakesAScrollNotADrag() {
        _ = m.began([t(1, 256, 256)], at: 0)
        #expect(m.moved([t(1, 256, 232)], at: 0.04) == [])   // past the slop, held back
        #expect(m.began([t(2, 320, 256)], at: 0.06)
                == [.move(pos(288.0 / 1024, 0.5)), .scroll(horizontal: 0, vertical: 0.5)])
        #expect(m.nextDeadline == nil)
        #expect(m.update(at: 0.2) == [])
    }

    @Test mutating func secondFingerJoinsAStillFirstFinger() {
        _ = m.began([t(1, 256, 256)], at: 0)
        _ = m.update(at: 0.3)
        _ = m.began([t(2, 320, 256)], at: 0.35)
        #expect(m.nextDeadline == nil)
        #expect(m.update(at: 0.6) == [])  // no long press once two fingers
        #expect(m.moved([t(1, 256, 280), t(2, 320, 280)], at: 0.7)
                == [.move(pos(288.0 / 1024, 0.5)), .scroll(horizontal: 0, vertical: -1)])
    }

    @Test mutating func twoFingerTapRightClicksAtTheCentroid() {
        _ = m.began([t(1, 256, 256)], at: 0)
        _ = m.began([t(2, 320, 256)], at: 0.03)
        _ = m.moved([t(1, 258, 258)], at: 0.05)
        #expect(m.ended([t(1, 258, 258)], at: 0.12) == [])
        #expect(m.ended([t(2, 320, 256)], at: 0.15) == [.move(pos(288.0 / 1024, 0.5)), press(right), release(right)])
    }

    @Test mutating func slowTwoFingerTapDoesNothing() {
        _ = m.began([t(1, 256, 256), t(2, 320, 256)], at: 0)
        #expect(m.ended([t(1, 256, 256), t(2, 320, 256)], at: 0.4) == [])
    }

    @Test mutating func threeFingerTapMiddleClicks() {
        _ = m.began([t(1, 256, 256), t(2, 320, 256)], at: 0)
        _ = m.began([t(3, 288, 320)], at: 0.05)
        #expect(m.ended([t(1, 256, 256), t(2, 320, 256), t(3, 288, 320)], at: 0.2)
                == [.move(pos(288.0 / 1024, 832.0 / 3 / 512)), press(middle), release(middle)])
    }

    @Test mutating func threeFingerPanDoesNothing() {
        _ = m.began([t(1, 256, 256), t(2, 320, 256), t(3, 288, 320)], at: 0)
        #expect(m.moved([t(1, 256, 200), t(2, 320, 200), t(3, 288, 264)], at: 0.1) == [])
        #expect(m.ended([t(1, 256, 200), t(2, 320, 200), t(3, 288, 264)], at: 0.2) == [])
    }

    @Test mutating func twoFingerLeftOverFingerDoesNotDrag() {
        _ = m.began([t(1, 256, 256), t(2, 320, 256)], at: 0)
        _ = m.ended([t(1, 256, 256)], at: 0.05)
        #expect(m.moved([t(2, 320, 400)], at: 0.2) == [])
        #expect(m.update(at: 1) == [])
        #expect(m.ended([t(2, 320, 400)], at: 1.1) == [])
    }

    @Test mutating func extraFingersAreIgnoredOnceCommitted() {
        _ = m.began([t(1, 256, 128)], at: 0)
        _ = m.moved([t(1, 256, 192)], at: 0.2)  // dragging
        #expect(m.began([t(2, 512, 128)], at: 0.3) == [])
        #expect(m.moved([t(2, 600, 128)], at: 0.35) == [])
        #expect(m.moved([t(1, 256, 256)], at: 0.4) == [.move(pos(0.25, 0.5))])
        #expect(m.ended([t(2, 600, 128)], at: 0.45) == [])
        #expect(m.ended([t(1, 256, 256)], at: 0.5) == [release(left)])
        // Back to idle: a fresh tap works.
        _ = m.began([t(3, 512, 256)], at: 1)
        #expect(m.ended([t(3, 512, 256)], at: 1.1) == [.move(pos(0.5, 0.5)), press(left), release(left)])
    }

    @Test mutating func thirdFingerDuringAScrollIsIgnored() {
        _ = m.began([t(1, 256, 256), t(2, 320, 256)], at: 0)
        _ = m.moved([t(1, 256, 232), t(2, 320, 232)], at: 0.05)
        #expect(m.began([t(3, 500, 500)], at: 0.1) == [])
        #expect(m.moved([t(3, 500, 300)], at: 0.15) == [])
        #expect(m.moved([t(1, 256, 208), t(2, 320, 208)], at: 0.2) == [.scroll(horizontal: 0, vertical: 1)])
        #expect(m.ended([t(1, 256, 208), t(2, 320, 208), t(3, 500, 300)], at: 0.3) == [])
    }

    @Test mutating func resetReleasesAndForgets() {
        _ = m.began([t(1, 256, 128)], at: 0)
        _ = m.moved([t(1, 256, 192)], at: 0.2)
        #expect(m.reset() == [release(left)])
        #expect(m.reset() == [])
        #expect(m.moved([t(1, 300, 300)], at: 0.3) == [])
        #expect(m.ended([t(1, 300, 300)], at: 0.4) == [])
    }

    @Test mutating func resetCancelsAPendingLongPress() {
        _ = m.began([t(1, 256, 128)], at: 0)
        #expect(m.reset() == [])
        #expect(m.nextDeadline == nil)
        #expect(m.update(at: 1) == [])
    }
}

@Suite("Touch to pointer: trackpad mode")
struct TrackpadTouchTests {
    var m = Mapper(mode: .trackpad, mapping: fullView)

    @Test mutating func oneFingerMovesTheCursorRelatively() {
        #expect(m.cursor == pos(0.5, 0.5))
        _ = m.began([t(1, 100, 100)], at: 0)
        #expect(m.nextDeadline == nil)
        #expect(m.moved([t(1, 104, 100)], at: 0.15) == [])  // under the slop
        // 64 pt right x 1.5 / 1024 pt = 0.09375, counted from touch-down.
        #expect(m.moved([t(1, 164, 100)], at: 0.2) == [.move(pos(0.59375, 0.5))])
        // 32 pt up x 1.5 / 512 pt = 0.09375.
        #expect(m.moved([t(1, 164, 68)], at: 0.25) == [.move(pos(0.59375, 0.40625))])
        #expect(m.ended([t(1, 164, 68)], at: 0.3) == [])
        #expect(m.cursor == pos(0.59375, 0.40625))
    }

    @Test mutating func cursorClampsAtTheEdges() {
        _ = m.began([t(1, 900, 100)], at: 0)
        #expect(m.moved([t(1, 0, 500)], at: 0.2) == [.move(pos(0, 1))])
        // Back the other way it leaves the edge at once.
        #expect(m.moved([t(1, 64, 500)], at: 0.3) == [.move(pos(0.09375, 1))])
        #expect(m.moved([t(1, 64, 600)], at: 0.35) == [])  // already at the bottom
    }

    @Test mutating func tapClicksAtTheCursor() {
        _ = m.began([t(1, 800, 400)], at: 0)
        #expect(m.ended([t(1, 803, 402)], at: 0.1) == [press(left), release(left)])
        #expect(m.cursor == pos(0.5, 0.5))
    }

    @Test mutating func doubleTapIsTwoClicks() {
        _ = m.began([t(1, 800, 400)], at: 0)
        #expect(m.ended([t(1, 800, 400)], at: 0.1) == [press(left), release(left)])
        _ = m.began([t(2, 100, 100)], at: 0.2)
        #expect(m.ended([t(2, 100, 100)], at: 0.3) == [press(left), release(left)])
    }

    @Test mutating func longHoldDoesNothing() {
        _ = m.began([t(1, 800, 400)], at: 0)
        #expect(m.nextDeadline == nil)
        #expect(m.update(at: 2) == [])
        #expect(m.ended([t(1, 800, 400)], at: 2) == [])
    }

    @Test mutating func holdThenMovePoints() {
        _ = m.began([t(1, 100, 100)], at: 0)
        _ = m.update(at: 1)
        #expect(m.moved([t(1, 164, 100)], at: 1.1) == [.move(pos(0.59375, 0.5))])
    }

    @Test mutating func tapAndDragHoldsTheLeftButton() {
        _ = m.began([t(1, 100, 100)], at: 0)
        _ = m.ended([t(1, 100, 100)], at: 0.1)
        _ = m.began([t(2, 100, 100)], at: 0.3)
        #expect(m.moved([t(2, 164, 100)], at: 0.35) == [])  // grace
        #expect(m.nextDeadline == 0.4)
        #expect(m.update(at: 0.4) == [press(left), .move(pos(0.59375, 0.5))])
        #expect(m.moved([t(2, 164, 132)], at: 0.5) == [.move(pos(0.59375, 0.59375))])
        #expect(m.ended([t(2, 164, 132)], at: 0.6) == [release(left)])
    }

    @Test mutating func cancelledTapAndDragReleases() {
        _ = m.began([t(1, 100, 100)], at: 0)
        _ = m.ended([t(1, 100, 100)], at: 0.1)
        _ = m.began([t(2, 100, 100)], at: 0.2)
        #expect(m.moved([t(2, 164, 100)], at: 0.4) == [press(left), .move(pos(0.59375, 0.5))])
        #expect(m.cancelled([t(2, 164, 100)], at: 0.5) == [release(left)])
    }

    @Test mutating func lateTouchAfterATapOnlyPoints() {
        _ = m.began([t(1, 100, 100)], at: 0)
        _ = m.ended([t(1, 100, 100)], at: 0.1)
        _ = m.began([t(2, 100, 100)], at: 0.5)
        #expect(m.moved([t(2, 164, 100)], at: 0.7) == [.move(pos(0.59375, 0.5))])
        #expect(m.ended([t(2, 164, 100)], at: 0.8) == [])
    }

    @Test mutating func twoAndThreeFingerTaps() {
        _ = m.began([t(1, 100, 100), t(2, 200, 100)], at: 0)
        #expect(m.ended([t(1, 100, 100), t(2, 200, 100)], at: 0.1) == [press(right), release(right)])
        _ = m.began([t(3, 100, 100), t(4, 200, 100), t(5, 150, 150)], at: 1)
        #expect(m.ended([t(3, 100, 100), t(4, 200, 100), t(5, 150, 150)], at: 1.1) == [press(middle), release(middle)])
        #expect(m.cursor == pos(0.5, 0.5))
    }

    @Test mutating func twoFingerPanScrollsWithoutMoving() {
        _ = m.began([t(1, 100, 100), t(2, 200, 100)], at: 0)
        #expect(m.moved([t(1, 100, 52), t(2, 200, 52)], at: 0.1) == [.scroll(horizontal: 0, vertical: 2)])
        #expect(m.moved([t(1, 124, 52), t(2, 224, 52)], at: 0.2) == [.scroll(horizontal: -1, vertical: 0)])
        #expect(m.ended([t(1, 124, 52), t(2, 224, 52)], at: 0.3) == [])
        #expect(m.cursor == pos(0.5, 0.5))
    }

    @Test mutating func flickInsideTheGraceStillMovesTheCursor() {
        _ = m.began([t(1, 100, 100)], at: 0)
        #expect(m.ended([t(1, 164, 100)], at: 0.05) == [.move(pos(0.59375, 0.5))])
    }

    @Test mutating func modeSwitchMidDragKeepsTheCursor() {
        m.mode = .direct
        _ = m.began([t(1, 256, 128)], at: 0)
        _ = m.moved([t(1, 256, 256)], at: 0.2)
        m.mode = .trackpad
        #expect(m.reset() == [release(left)])
        #expect(m.cursor == pos(0.25, 0.5))
        _ = m.began([t(2, 100, 100)], at: 1)
        #expect(m.moved([t(2, 164, 100)], at: 1.2) == [.move(pos(0.34375, 0.5))])
    }
}

@Suite("Touch to pointer: invariants")
struct TouchInvariantTests {
    /// Random touch storms in both modes: every press is matched by one
    /// release, never a release without a press, and nothing stays held
    /// once every finger is up.
    @Test(arguments: Mapper.Mode.allCases)
    func buttonsAlwaysBalance(mode: Mapper.Mode) {
        var rng = SplitMix(seed: 0x5eed)
        var m = Mapper(mode: mode, mapping: fullView)
        var down: [Int: CGPoint] = [:]
        var held: [UInt32: Bool] = [:]
        var nextID = 0
        var time: TimeInterval = 0
        func check(_ actions: [Action]) {
            for a in actions {
                guard case .button(let b, let pressed) = a else { continue }
                #expect(held[b, default: false] != pressed)
                held[b] = pressed
            }
        }
        for _ in 0..<20_000 {
            time += Double(rng.next() % 200) / 1000
            let roll = rng.next() % 10
            switch roll {
            case 0...1 where down.count < 4:
                nextID += 1
                let p = CGPoint(x: CGFloat(rng.next() % 1024), y: CGFloat(rng.next() % 512))
                down[nextID] = p
                check(m.began([t(nextID, p.x, p.y)], at: time))
            case 2...6 where !down.isEmpty:
                let ids = down.keys.sorted().filter { _ in rng.next() % 2 == 0 }
                let moved = ids.map { id -> Mapper.Touch in
                    let p = down[id]!
                    let q = CGPoint(x: p.x + CGFloat(Int(rng.next() % 41) - 20), y: p.y + CGFloat(Int(rng.next() % 41) - 20))
                    down[id] = q
                    return t(id, q.x, q.y)
                }
                check(m.moved(moved, at: time))
            case 7...8 where !down.isEmpty:
                let id = down.keys.sorted()[Int(rng.next() % UInt64(down.count))]
                let p = down.removeValue(forKey: id)!
                check(rng.next() % 8 == 0 ? m.cancelled([t(id, p.x, p.y)], at: time) : m.ended([t(id, p.x, p.y)], at: time))
            case 9:
                if let d = m.nextDeadline, d <= time { check(m.update(at: time)) }
                if rng.next() % 50 == 0 { check(m.reset()); down = [:] }
            default:
                break
            }
            if down.isEmpty { #expect(held.values.allSatisfy { !$0 }) }
            #expect((0...1).contains(m.cursor.x) && (0...1).contains(m.cursor.y))
        }
        check(m.reset())
        #expect(held.values.allSatisfy { !$0 })
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
