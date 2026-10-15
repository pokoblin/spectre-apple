import CoreGraphics
import Testing
@testable import SpectreKit

typealias Follower = ResolutionFollower
typealias OutputSize = ResolutionFollower.Size

private func size(_ w: UInt32, _ h: UInt32) -> OutputSize { OutputSize(width: w, height: h) }
private func view(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w, height: h) }

@Suite("Resolution: the size to ask for")
struct ResolutionSizeTests {
    @Test func pointsIgnoreTheScale() {
        #expect(Follower.outputSize(viewSize: view(1512, 945), scale: 2, units: .points) == size(1512, 944))
    }

    @Test func pixelsMultiplyByTheScale() {
        #expect(Follower.outputSize(viewSize: view(1512, 945), scale: 2, units: .pixels) == size(3024, 1890))
        #expect(Follower.outputSize(viewSize: view(430, 932), scale: 3, units: .pixels) == size(1290, 2796))
    }

    @Test func roundsDownToEvenWholePixels() {
        // §7.2: subsampled chroma needs even sizes.
        #expect(Follower.outputSize(viewSize: view(1023.7, 701.2), scale: 1, units: .points) == size(1022, 700))
        #expect(Follower.outputSize(viewSize: view(683.5, 512.5), scale: 2, units: .pixels) == size(1366, 1024))
    }

    @Test func clampsToTheHostsLimits() {
        #expect(Follower.outputSize(viewSize: view(200, 100), scale: 1, units: .points) == size(320, 320))
        #expect(Follower.outputSize(viewSize: view(5000, 1200), scale: 2, units: .pixels) == size(8192, 2400))
    }

    @Test func nothingForAnEmptyView() {
        #expect(Follower.outputSize(viewSize: .zero, scale: 2, units: .points) == nil)
        #expect(Follower.outputSize(viewSize: view(800, 600), scale: 0, units: .pixels) == nil)
    }
}

@Suite("Resolution: following the view")
struct ResolutionFollowerTests {
    var f = Follower(isEnabled: true, units: .points)

    @Test mutating func asksOnceTheViewSettles() {
        f.outputChanged(size(1920, 1080))
        f.viewChanged(view(1280, 800), scale: 2, at: 10)
        #expect(f.nextDeadline == 10 + Follower.settleDelay)
        #expect(f.update(at: 10.2) == nil) // still settling
        f.viewChanged(view(1300, 810), scale: 2, at: 10.3) // a drag goes on: the wait starts over
        #expect(f.update(at: 10.6) == nil)
        #expect(f.update(at: 10.8) == size(1300, 810))
        #expect(f.nextDeadline == nil)
        #expect(f.update(at: 20) == nil) // asked once
    }

    @Test mutating func doesNotAskForTheSizeTheOutputHas() {
        f.outputChanged(size(1280, 800))
        f.viewChanged(view(1280, 800), scale: 2, at: 0)
        #expect(f.update(at: 1) == nil)
    }

    @Test mutating func doesNotAskAgainForARefusedSize() {
        f.outputChanged(size(1920, 1080))
        f.viewChanged(view(1280, 800), scale: 2, at: 0)
        #expect(f.update(at: 1) == size(1280, 800))
        f.outputChanged(size(1920, 1080)) // the host couldn't resize
        f.viewChanged(view(1280, 800), scale: 2, at: 2) // the same size again (a relayout)
        #expect(f.update(at: 3) == nil)
        f.viewChanged(view(1024, 768), scale: 2, at: 4) // a new size is worth asking for
        #expect(f.update(at: 5) == size(1024, 768))
    }

    @Test mutating func goingBackToAnEarlierSizeAsksForIt() {
        f.outputChanged(size(1920, 1080))
        f.viewChanged(view(1280, 800), scale: 2, at: 0)
        #expect(f.update(at: 1) == size(1280, 800))
        f.outputChanged(size(1280, 800))
        f.viewChanged(view(1920, 1080), scale: 2, at: 2)
        #expect(f.update(at: 3) == size(1920, 1080))
    }

    @Test mutating func offAsksNothing() {
        f.setEnabled(false, at: 0)
        f.outputChanged(size(1920, 1080))
        f.viewChanged(view(1280, 800), scale: 2, at: 0)
        #expect(f.nextDeadline == nil)
        #expect(f.update(at: 1) == nil)
        #expect(f.sizeForConnection() == nil)
    }

    @Test mutating func turningOnAsksForTheCurrentView() {
        f.setEnabled(false, at: 0)
        f.outputChanged(size(1920, 1080))
        f.viewChanged(view(1280, 800), scale: 2, at: 0)
        f.setEnabled(true, at: 5)
        #expect(f.update(at: 5 + Follower.settleDelay) == size(1280, 800))
    }

    @Test mutating func switchingUnitsAsksAgain() {
        f.outputChanged(size(1280, 800))
        f.viewChanged(view(1280, 800), scale: 2, at: 0)
        #expect(f.update(at: 1) == nil)
        f.setUnits(.pixels, at: 2)
        #expect(f.update(at: 2 + Follower.settleDelay) == size(2560, 1600))
        f.outputChanged(size(2560, 1600))
        f.setUnits(.points, at: 3)
        #expect(f.update(at: 3 + Follower.settleDelay) == size(1280, 800))
    }

    @Test mutating func aNewScaleIsANewSize() {
        // The window moved to a display with another scale.
        f = Follower(isEnabled: true, units: .pixels)
        f.outputChanged(size(2560, 1600))
        f.viewChanged(view(1280, 800), scale: 2, at: 0)
        #expect(f.update(at: 1) == nil)
        f.viewChanged(view(1280, 800), scale: 1, at: 2)
        #expect(f.update(at: 3) == size(1280, 800))
    }

    @Test mutating func theConnectionCarriesTheSize() {
        // SessionHello asks for it (§6.2), so nothing more is sent for it.
        f.viewChanged(view(1280, 800), scale: 2, at: 0)
        #expect(f.sizeForConnection() == size(1280, 800))
        #expect(f.nextDeadline == nil)
        f.outputChanged(size(1920, 1080)) // the host kept its size
        #expect(f.update(at: 1) == nil)
    }

    @Test mutating func noViewYetMeansNoSize() {
        #expect(f.sizeForConnection() == nil)
        #expect(f.update(at: 1) == nil)
    }
}
