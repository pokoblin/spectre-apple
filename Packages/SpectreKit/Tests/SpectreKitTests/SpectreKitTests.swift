import CoreVideo
import Foundation
import GDPKit
import Metal
import Synchronization
import Testing
@testable import SpectreKit

@Suite("Annex B")
struct AnnexBTests {
    @Test func splitsThreeAndFourByteStartCodes() {
        let bytes: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6]
        let units = AnnexB.nalUnits(in: bytes)
        #expect(units.map { Array(bytes[$0]) } == [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5, 6]])
    }

    @Test func ignoresLeadingGarbageAndTrailingZeros() {
        let bytes: [UInt8] = [9, 9, 0, 0, 1, 0x41, 7, 0, 0]
        #expect(AnnexB.nalUnits(in: bytes).map { Array(bytes[$0]) } == [[0x41, 7]])
    }

    @Test func nalKinds() {
        #expect(VideoCodec.h264.kind(ofNALHeader: 0x67) == .parameterSet(index: 0))
        #expect(VideoCodec.h264.kind(ofNALHeader: 0x68) == .parameterSet(index: 1))
        #expect(VideoCodec.h264.kind(ofNALHeader: 0x65) == .keyframeSlice)
        #expect(VideoCodec.h264.kind(ofNALHeader: 0x41) == .other)
        #expect(VideoCodec.h265.kind(ofNALHeader: 0x40) == .parameterSet(index: 0)) // VPS
        #expect(VideoCodec.h265.kind(ofNALHeader: 0x42) == .parameterSet(index: 1)) // SPS
        #expect(VideoCodec.h265.kind(ofNALHeader: 0x44) == .parameterSet(index: 2)) // PPS
        #expect(VideoCodec.h265.kind(ofNALHeader: 0x26) == .keyframeSlice)          // IDR_W_RADL
        #expect(VideoCodec.h265.kind(ofNALHeader: 0x02) == .other)                  // TRAIL_R
    }
}

@Suite("Colour (gdp-spec.md §7.3)")
struct ColorTests {
    let bt601 = ColorDescription.blockCodecDefault

    @Test func limitedRangeEndpoints() {
        #expect(bt601.rgb(y: 16, cb: 128, cr: 128) == SIMD3(0, 0, 0))
        #expect(bt601.rgb(y: 235, cb: 128, cr: 128) == SIMD3(255, 255, 255))
        #expect(bt601.rgb(y: 126, cb: 128, cr: 128) == SIMD3(128, 128, 128))
    }

    /// The test pattern's RGB -> Y'CbCr (BT.601 limited) followed by the
    /// presenter's matrix lands back on the same RGB, within rounding.
    @Test(arguments: TestPatternGenerator.bars)
    func barsRoundTrip(rgb: SIMD3<UInt8>) {
        let r = Double(rgb.x) / 255, g = Double(rgb.y) / 255, b = Double(rgb.z) / 255
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let code = { (v: Double) in UInt8((v).rounded()) }
        let out = bt601.rgb(y: code(16 + 219 * y), cb: code(128 + 224 * (b - y) / 1.772),
                            cr: code(128 + 224 * (r - y) / 1.402))
        for i in 0..<3 { #expect(abs(Int(out[i]) - Int(rgb[i])) <= 2) }
    }

    @Test func chromaSiting() {
        #expect(bt601.chromaOffset(lumaWidth: 1920, lumaHeight: 1080) == SIMD2(0.5 / 1920, 0.5 / 1080))
        #expect(ColorDescription.pyrowaveDefault.chromaOffset(lumaWidth: 1920, lumaHeight: 1080) == .zero)
    }

    @Test func fitViewportLetterboxes() {
        let v = VideoRenderer.fitViewport(video: CGSize(width: 1920, height: 1080), drawable: CGSize(width: 1000, height: 1000))
        #expect(v.width == 1000 && v.height == 563 && v.originX == 0 && v.originY == 219)
    }
}

/// Everything at once: synthetic picture -> VideoToolbox encode -> Annex B
/// -> VideoDecoder -> zero-copy textures -> video shader -> read back.
@Suite("Decode and present", .serialized)
struct PipelineTests {
    /// Sizes a session can be resized to (§7.2): any even width, not only
    /// multiples of the codecs' 16-pixel blocks, whose padding the decoder crops.
    static let sizes = [(1920, 1080), (824, 460), (856, 460)]

    @Test(arguments: VideoCodec.allCases, sizes)
    func decodedBarsRenderTheirColours(codec: VideoCodec, size: (Int, Int)) throws {
        let (width, height) = size
        let stream = try TestStreamEncoder.encode(codec: codec, width: width, height: height, frameCount: 10,
                                                  bitrate: 20_000_000)
        #expect(stream.accessUnits.count == 10)
        #expect(stream.accessUnits[0].keyframe)
        #expect(stream.accessUnits.dropFirst().allSatisfy { !$0.keyframe })

        // The Annex B byte stream splits back into the same access units.
        let reparsed = TestStream(annexB: stream.annexB, codec: codec, width: width, height: height, framesPerSecond: 60)
        #expect(reparsed.accessUnits.map(\.bytes) == stream.accessUnits.map(\.bytes))
        #expect(reparsed.accessUnits.map(\.keyframe) == stream.accessUnits.map(\.keyframe))

        let frames = Mutex<[DecodedFrame]>([])
        let decoder = VideoDecoder(codec: codec, onFrame: { f in frames.withLock { $0.append(f) } })
        for (i, au) in stream.accessUnits.enumerated() {
            try au.bytes.withUnsafeBytes { try decoder.decode($0, pts: UInt32(i * 16_667)) }
        }
        decoder.flush()
        let decoded = frames.withLock { $0 }
        #expect(decoded.count == 10)
        let first = try #require(decoded.first)
        #expect(CVPixelBufferGetWidth(first.pixelBuffer) == width)
        #expect(CVPixelBufferGetHeight(first.pixelBuffer) == height)
        print("\(codec.displayName): hardware decoder \(decoder.isHardwareAccelerated), "
            + String(format: "first frame decode %.2f ms", first.decodeDuration * 1000))

        let renderer = try VideoRenderer()
        let textures = try renderer.textures(for: first)
        #expect(textures.isZeroCopy, "textures must be views of the decoder's IOSurface")

        let target = try #require(renderer.device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: VideoRenderer.colorPixelFormat, width: width,
                                                             height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            return d
        }()))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        let cb = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.encode(textures, color: .blockCodecDefault, displaySize: CGSize(width: width, height: height),
                        viewport: VideoRenderer.fitViewport(
            video: CGSize(width: width, height: height), drawable: CGSize(width: width, height: height)),
            pass: pass, into: cb)
        cb.commit()
        cb.waitUntilCompleted()

        // Sample the middle of each bar, away from its edges, near the top
        // and the bottom of the bars: rows read with the wrong stride would
        // drift sideways from one to the other.
        let barsBottom = Double(height) * TestPatternGenerator.barsHeightFraction
        for (i, expected) in TestPatternGenerator.bars.enumerated() {
            for y in [Int(barsBottom * 0.1), Int(barsBottom * 0.9)] {
            let x = (2 * i + 1) * width / 16
            var bgra = [UInt8](repeating: 0, count: 4)
            target.getBytes(&bgra, bytesPerRow: 4 * width, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            let got = SIMD3(bgra[2], bgra[1], bgra[0])
            for c in 0..<3 {
                #expect(abs(Int(got[c]) - Int(expected[c])) <= 6, "bar \(i) row \(y): got \(got), expected \(expected)")
            }
            }
        }
    }
}

/// The real receive path: TestStream → GDP test host → QUIC loopback →
/// GDPSession → RemoteSession → VideoDecoder → mailbox, and StatsReport back.
@Suite("Loopback session", .serialized)
struct LoopbackSessionTests {
    @Test(arguments: VideoCodec.allCases)
    func framesFlowAndStatsReachTheHost(codec: VideoCodec) async throws {
        let stream = try TestStreamEncoder.encode(codec: codec, width: 1280, height: 720, frameCount: 60,
                                                  bitrate: 10_000_000)
        let loopback = try LoopbackHost(stream: stream, audio: false)
        let mailbox = FrameMailbox()
        let stats = PlaybackStats(mailbox: mailbox)
        let decoded = Mutex<[UInt32]>([])
        let pictures = Mutex<[RemoteSession.Picture]>([])
        let remote = RemoteSession(mailbox: mailbox, stats: stats) {
            if let f = mailbox.take() {
                decoded.withLock { $0.append(f.frameID) }
                // Stand in for the presenter: report the frame as shown.
                stats.recordPresented(frame: f, presentedTime: f.decodedTime + 0.008, gpuStart: 0, gpuEnd: 0,
                                      zeroCopy: true)
            }
        }
        remote.onPictureChange = { p in pictures.withLock { $0.append(p) } }
        try remote.connect(loopback.sessionConfiguration())
        loopback.start()
        defer { loopback.stop() }

        func until(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<500 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
        #expect(await until { decoded.withLock { $0.count } >= 45 })
        let ids = decoded.withLock { $0 }
        #expect(ids.first == 0)
        #expect(zip(ids, ids.dropFirst()).allSatisfy { $1 == $0 &+ 1 }, "frames out of order or missing: \(ids)")
        #expect(pictures.withLock { $0.first }?.size == CGSize(width: 1280, height: 720))
        #expect(pictures.withLock { $0.first }?.color == .blockCodecDefault)

        // The host sees what the client measured (§7.5).
        #expect(await until { loopback.host.observed.lastHighestFrameID >= 30 && loopback.host.observed.lastPresentMicroseconds > 0 })
        let o = loopback.host.observed
        #expect(o.acceptedCodec == codec.rawValue)
        #expect(o.decoders == ["videotoolbox"])
        #expect(o.lostFrameIDs.isEmpty)
        #expect(o.lastDecodeMicroseconds > 0)
        #expect((7_000...9_000).contains(o.lastPresentMicroseconds))
        #expect(stats.summary().decodeErrors == 0)
        let link = try #require(remote.linkStats())
        #expect(link.rttMicroseconds > 0 && link.recentLosses == 0)
        remote.close()
    }

    /// Files the viewer sends land in the loopback host's directory (§7.12).
    @Test func filesLandInTheLoopbackDirectory() async throws {
        let stream = try TestStreamEncoder.encode(codec: .h264, width: 640, height: 360, frameCount: 10,
                                                  bitrate: 2_000_000)
        let loopback = try LoopbackHost(stream: stream, audio: false)
        let accepted = Mutex(false)
        let ready = Mutex<UInt64?>(nil)
        let outcome = Mutex<GDPSession.FileOutcome?>(nil)
        var handlers = GDPSession.Handlers()
        handlers.accepted = { _ in accepted.withLock { $0 = true } }
        handlers.fileAccepted = { id in ready.withLock { $0 = id } }
        handlers.fileFinished = { _, o in outcome.withLock { $0 = o } }
        let session = GDPSession(handlers: handlers)
        var config = loopback.sessionConfiguration()
        config.capabilities = [GDPSession.Capability.file]
        try session.connect(config)
        func until(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<500 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
        #expect(await until { accepted.withLock { $0 } })
        let name = "loopback-test-\(UUID().uuidString).txt"
        let contents = Data("sent over loopback ✓".utf8)
        let id = try #require(session.offerFile(name: name, size: UInt64(contents.count), modified: nil))
        #expect(await until { ready.withLock { $0 } == id })
        session.sendFileData(id, contents)
        #expect(await until { outcome.withLock { $0 } != nil })
        #expect(outcome.withLock { $0 } == .saved(name: name))
        let file = loopback.fileDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == contents)
        #expect(loopback.host.receivedFiles.last?.path == file.path(percentEncoded: false))
        session.close()
    }

    /// iOS in the background: frames are acknowledged but not decoded (no
    /// loss for the host), and on return decoding starts again from a
    /// keyframe the client asks for.
    @Test func suspendedVideoIsDroppedAndResumesFromAKeyframe() async throws {
        let stream = try TestStreamEncoder.encode(codec: .h264, width: 640, height: 360, frameCount: 120,
                                                  bitrate: 2_000_000)
        let loopback = try LoopbackHost(stream: stream, audio: false)
        let mailbox = FrameMailbox()
        let stats = PlaybackStats(mailbox: mailbox)
        let decoded = Mutex<[UInt32]>([])
        let remote = RemoteSession(mailbox: mailbox, stats: stats) {
            if let f = mailbox.take() { decoded.withLock { $0.append(f.frameID) } }
        }
        try remote.connect(loopback.sessionConfiguration())
        loopback.start()
        defer { loopback.stop() }
        func until(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<500 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
        #expect(await until { decoded.withLock { $0.count } >= 10 })

        remote.suspendVideo()
        try await Task.sleep(for: .milliseconds(100)) // frames already queued drain
        let before = decoded.withLock { $0.count }
        let sentBefore = loopback.host.observed.framesSent
        let requestsBefore = loopback.host.observed.keyframeRequests
        try await Task.sleep(for: .milliseconds(500))
        #expect(loopback.host.observed.framesSent > sentBefore + 20) // the host kept sending
        #expect(decoded.withLock { $0.count } == before)           // nothing decoded
        #expect(loopback.host.observed.lostFrameIDs.isEmpty)      // and nothing reported lost

        remote.resumeVideo()
        #expect(await until { loopback.host.observed.keyframeRequests > requestsBefore })
        #expect(await until { decoded.withLock { $0.count } >= before + 10 })
        #expect(stats.summary().decodeErrors == 0) // no P-frame reached the fresh decoder before the keyframe
        remote.close()
    }
}
