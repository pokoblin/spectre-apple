import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import SpectreKit

@Suite("Playback statistics")
struct PlaybackStatsTests {
    /// The timing sink is called once per presented frame, from Core
    /// Animation's presented-handler thread (512 KB of stack). Reading it
    /// must not change it: a closure read back through Mutex.withLock's
    /// inout was re-wrapped in a reabstraction thunk on every call, one
    /// level per frame, until a session overflowed that stack after about
    /// two minutes at 60 fps.
    @Test func timingSinkDoesNotGrowPerFrame() async throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        let frame = DecodedFrame(pixelBuffer: try #require(pb), pts: 0, frameID: 0, sequence: 0, submitTime: 0,
                                 decodedTime: 1)
        let stats = PlaybackStats()
        let calls = Mutex(0)
        stats.setTimingSink { _, _ in calls.withLock { $0 += 1 } }
        let frames = 20_000 // over five minutes at 60 fps
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                for _ in 0..<frames {
                    stats.recordPresented(frame: frame, presentedTime: 2, gpuStart: 0, gpuEnd: 0, zeroCopy: true)
                }
                done.resume()
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
        #expect(calls.withLock { $0 } == frames)
    }
}
