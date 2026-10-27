import Foundation
import Synchronization
import Testing
@testable import GDPKit

/// What a session reported, collected from its handlers (on the session queue).
final class Recorder: Sendable {
    struct Frame: Sendable {
        let id: UInt32
        let keyframe: Bool
        let pts: UInt32
        let data: [UInt8]
        var layer: Layer?
    }

    /// A frame's lossless layer (§9.5), copied out of the handler.
    struct Layer: Sendable, Equatable {
        let reset: Bool
        let clears: [GDPSession.RefineRect]
        let tiles: [GDPSession.RefineRect]
        let bgra: [UInt8]
    }

    struct State: Sendable {
        var accept: GDPSession.Accept?
        var ending: GDPSession.Ending?
        var frames: [Frame] = []
        var displays: [[GDPSession.Output]] = []
        var cursors: [GDPSession.CursorShape] = []
        var positions: [(Double, Double)] = []
        var profiles: [GDPSession.NetworkProfile] = []
        var diagnosticsRequests = 0
        var audio: [(UInt16, UInt32, [UInt8])] = []
        var clipboards: [String] = []
        var desktopStates: [Bool] = []
        var filesAccepted: [UInt64] = []
        var fileProgress: [UInt64: [UInt64]] = [:]
        var filesFinished: [UInt64: GDPSession.FileOutcome] = [:]
        /// File outcomes in the order they came, and whether the session had already ended by then.
        var fileFinishOrder: [(UInt64, Bool)] = []
        /// Copied files (§7.12): every list, and each fetch's header and bytes so far.
        var fileLists: [(UInt64, [GDPSession.FileListEntry])] = []
        var fetchHeaders: [UInt64: (name: String, size: UInt64)] = [:]
        var fetched: [UInt64: [UInt8]] = [:]
        var fetchRanges: [UInt64: (offset: UInt64, fileSize: UInt64)] = [:]
        /// file-clipboard: each listing request's batches.
        var listings: [UInt64: [(firstIndex: UInt32, files: [GDPSession.FileListEntry])]] = [:]
        /// file-clipboard: what the host read of this side's files (offset, size), by id.
        var served: [UInt64: (offset: UInt64, size: UInt64)] = [:]
    }

    /// Where served files' bytes go (file-clipboard): set once the session
    /// exists. `hold`: keep them back, the descriptors open.
    final class ServeTarget: @unchecked Sendable {
        weak var session: GDPSession?
        var hold = false
        var held: [UInt64: FileHandle] = [:]
    }
    let serveTarget = Mutex(ServeTarget())

    let state = Mutex(State())
    var snapshot: State { state.withLock { $0 } }

    func handlers(acceptFrames: Bool = true, onDiagnostics: (@Sendable () -> Void)? = nil) -> GDPSession.Handlers {
        var h = GDPSession.Handlers()
        h.accepted = { a in self.state.withLock { $0.accept = a } }
        h.closed = { e in self.state.withLock { $0.ending = e } }
        h.displaysChanged = { o in self.state.withLock { $0.displays.append(o) } }
        h.videoFrame = { f in
            let layer = f.refine.map { Layer(reset: $0.reset, clears: $0.clears, tiles: $0.tiles, bgra: Array($0.bgra)) }
            let frame = Frame(id: f.frameID, keyframe: f.keyframe, pts: f.pts, data: Array(f.data), layer: layer)
            self.state.withLock { $0.frames.append(frame) }
            return acceptFrames
        }
        h.audioPacket = { seq, pts, opus in
            let bytes = Array(opus)
            self.state.withLock { $0.audio.append((seq, pts, bytes)) }
        }
        h.cursorShape = { c in self.state.withLock { $0.cursors.append(c) } }
        h.cursorPosition = { x, y in self.state.withLock { $0.positions.append((x, y)) } }
        h.networkProfileChanged = { p in self.state.withLock { $0.profiles.append(p) } }
        h.diagnosticsRequested = {
            self.state.withLock { $0.diagnosticsRequests += 1 }
            onDiagnostics?()
        }
        h.clipboardText = { t in self.state.withLock { $0.clipboards.append(t) } }
        h.desktopState = { held in self.state.withLock { $0.desktopStates.append(held) } }
        h.fileAccepted = { id in self.state.withLock { $0.filesAccepted.append(id) } }
        h.fileProgress = { id, acked in self.state.withLock { $0.fileProgress[id, default: []].append(acked) } }
        h.fileList = { listID, files in self.state.withLock { $0.fileLists.append((listID, files)) } }
        h.fileSending = { id, name, size, _ in self.state.withLock { $0.fetchHeaders[id] = (name, size) } }
        h.fileRange = { id, offset, size in self.state.withLock { $0.fetchRanges[id] = (offset, size) } }
        h.fileListing = { id, first, files in self.state.withLock { $0.listings[id, default: []].append((first, files)) } }
        h.fileServe = { id, fd, offset, size in
            self.state.withLock { $0.served[id] = (offset, size) }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            self.serveTarget.withLock { target in
                if target.hold {
                    target.held[id] = file
                    return
                }
                try? file.seek(toOffset: offset)
                let data = (try? file.read(upToCount: Int(size))) ?? Data()
                target.session?.sendFileData(id, data)
            }
        }
        h.fileData = { id, bytes in
            let copy = Array(bytes)
            self.state.withLock { $0.fetched[id, default: []] += copy }
        }
        h.fileFinished = { id, outcome in
            self.state.withLock {
                $0.filesFinished[id] = outcome
                $0.fileFinishOrder.append((id, $0.ending != nil))
            }
        }
        return h
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

func randomFrame(_ size: Int) -> [UInt8] {
    var rng = SystemRandomNumberGenerator()
    return (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }
}

/// Connects a session to `host` and waits for SessionAccept.
func connected(_ host: GDPTestHost, _ rec: Recorder, codecs: [String] = ["h264"], acceptFrames: Bool = true,
               configure: (inout GDPSession.Configuration) -> Void = { _ in }) async throws -> GDPSession {
    let session = GDPSession(handlers: rec.handlers(acceptFrames: acceptFrames))
    rec.serveTarget.withLock { $0.session = session }
    var config = host.sessionConfiguration(codecs: codecs)
    configure(&config)
    try session.connect(config)
    #expect(await eventually { rec.snapshot.accept != nil || rec.snapshot.ending != nil })
    try #require(rec.snapshot.accept != nil, "not accepted: \(rec.snapshot.ending.map(String.init(describing:)) ?? "timeout")")
    return session
}

@Suite("Session establishment (§6)")
struct EstablishmentTests {
    @Test func helloAndAcceptCarryTheNegotiation() async throws {
        var hc = GDPTestHost.Configuration()
        hc.codecs = ["h264"]
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = try await connected(host, rec, codecs: ["h265", "h264"]) {
            $0.capabilities = ["clipboard"]
            $0.decoders = ["videotoolbox"]
            $0.clientName = "Kbys-Mac-mini"
            $0.display = .init(width: 2560, height: 1440, refreshMillihertz: 120_000, scale: 2)
            $0.networkProfile = .lan
        }
        let seen = host.observed
        #expect(seen.token == "test-token")
        #expect(seen.codecs == ["h265", "h264"])
        #expect(seen.capabilities == ["clipboard"])
        #expect(seen.decoders == ["videotoolbox"])
        #expect(seen.clientName == "Kbys-Mac-mini")
        #expect(!seen.takeOver && !seen.viaGateway)
        #expect(seen.networkProfile == 1)
        #expect(seen.requestedWidth == 2560 && seen.requestedHeight == 1440 && seen.requestedScale == 2)
        #expect(seen.requestedRefreshMillihertz == 120_000)

        let accept = try #require(rec.snapshot.accept)
        #expect(accept.codec == "h264") // the first offered codec the host can encode
        #expect(accept.capabilities.isEmpty) // the host supports none of them
        #expect(accept.outputs.count == 1)
        #expect(accept.outputs.first.map { ($0.width, $0.height, $0.matrix, $0.range) } ?? (0, 0, 0, 0) == (1920, 1080, 1, 1))
        #expect(accept.outputs.first?.scale == 2) // §6.2: the scale asked for, which the host set
        #expect(accept.outputs.first?.refreshMillihertz == 120_000) // and the frame rate
        #expect(accept.audio == nil)
        #expect(accept.networkProfile == .lan)
        #expect(accept.encoder == "test" && accept.hostUser == "tester" && accept.hostName == "loopback")
        // §6.5: the host's cursor right after accepting.
        #expect(await eventually { rec.snapshot.cursors.count == 1 })
        session.close()
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(rec.snapshot.ending?.code == 0)
    }

    @Test func wrongCertificateIsRefusedBeforeTheToken() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = GDPSession(handlers: rec.handlers())
        var config = host.sessionConfiguration()
        config.certificate = CertificateFingerprint(certificateDER: Array("someone else".utf8))
        try session.connect(config)
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(rec.snapshot.ending?.certificateRejected == true)
        #expect(rec.snapshot.accept == nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!host.observed.helloReceived, "the token must never reach an unpinned host")
    }

    @Test func badTokenIsAuthFailed() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = GDPSession(handlers: rec.handlers())
        try session.connect(host.sessionConfiguration(token: "wrong"))
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(rec.snapshot.ending?.code == 20)
        #expect(rec.snapshot.ending?.reason == "authentication failed")
        withExtendedLifetime(session) {}
    }

    @Test(arguments: [(UInt64(24), false), (UInt64(41), true)])
    func refusalsCarryTheHostsCode(code: UInt64, ordinary: Bool) async throws {
        var hc = GDPTestHost.Configuration()
        hc.refuseCode = code
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = GDPSession(handlers: rec.handlers())
        try session.connect(host.sessionConfiguration())
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(rec.snapshot.ending?.code == code)
        #expect(rec.snapshot.ending?.isOrdinaryEnd == ordinary)
        withExtendedLifetime(session) {}
    }

    @Test func unofferedCodecIsNoCommonCodec() async throws {
        var hc = GDPTestHost.Configuration()
        hc.forceCodec = "av1"
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = GDPSession(handlers: rec.handlers())
        try session.connect(host.sessionConfiguration(codecs: ["h264"]))
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(rec.snapshot.ending?.code == 13)
        #expect(rec.snapshot.accept == nil, "an accept with an unoffered codec must not establish the session")
        withExtendedLifetime(session) {}
    }

    @Test func sessionRejectEndsWithItsReason() async throws {
        var hc = GDPTestHost.Configuration()
        hc.rejectReason = "maintenance"
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = GDPSession(handlers: rec.handlers())
        try session.connect(host.sessionConfiguration())
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(rec.snapshot.ending?.reason.contains("maintenance") == true)
        withExtendedLifetime(session) {}
    }

    @Test func pingBeforeAcceptIsIgnoredAfterIsAnswered() async throws {
        var hc = GDPTestHost.Configuration()
        hc.pingBeforeAccept = true
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = try await connected(host, rec)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(host.observed.pongs == 0) // §7.1: nothing counts before establishment
        host.sendPing(nonce: 0xfeed)
        #expect(await eventually { host.observed.pongs == 1 })
        #expect(host.observed.lastPongNonce == 0xfeed)
        withExtendedLifetime(session) {}
    }

    @Test func badConfigurationFailsToConnect() throws {
        let host = try GDPTestHost()
        let session = GDPSession(handlers: .init())
        #expect(throws: GDPSession.ConnectError.self) { try session.connect(host.sessionConfiguration(codecs: [])) }
    }

    @Test func inputBeforeAcceptIsNotSent() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = GDPSession(handlers: rec.handlers())
        try session.connect(host.sessionConfiguration())
        session.sendKey(hidUsage: 4, pressed: true) // racing the handshake
        #expect(await eventually { rec.snapshot.accept != nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!host.observed.inputBeforeAccept)
        #expect(host.observed.keyEvents == 0)
    }
}

@Suite("Video and StatsReport (§7.5, §9)")
struct VideoTests {
    @Test func framesArriveIntactAndAreAcked() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        var sent: [[UInt8]] = []
        for i in 0..<30 {
            let frame = randomFrame(i == 0 ? 80_000 : Int.random(in: 20_000...60_000))
            sent.append(frame)
            host.sendVideoFrame(frame, keyframe: i == 0)
        }
        #expect(await eventually { rec.snapshot.frames.count == 30 })
        let frames = rec.snapshot.frames
        #expect(frames.map(\.id) == Array(0..<30))
        #expect(frames.map(\.data) == sent)
        #expect(frames.map(\.keyframe) == [true] + Array(repeating: false, count: 29))
        #expect(zip(frames, frames.dropFirst()).allSatisfy { Int32(bitPattern: $1.pts &- $0.pts) >= 0 })

        session.recordFrameTiming(decodeMicroseconds: 3000, presentMicroseconds: 12_000)
        var maxTrains: UInt32 = 0
        #expect(await eventually {
            let o = host.observed
            maxTrains = max(maxTrains, o.lastTrains)
            return o.lastHighestFrameID == 29 && o.lastDecodeMicroseconds == 3000 && o.bytesReported >= UInt64(sent.joined().count)
        })
        let o = host.observed
        #expect(o.lastHasStream && o.lastLossBitmap == 0 && o.lostFrameIDs.isEmpty)
        #expect(o.lastPresentMicroseconds == 12_000)
        #expect((150_000...600_000).contains(o.lastIntervalMicroseconds), "interval \(o.lastIntervalMicroseconds)")
        #expect(o.lastRTT > 0)
        // Every 64 KB-ish frame is > 16 datagrams: trains were measured.
        #expect(maxTrains > 0 || o.lastTrains > 0)
        let link = try #require(session.linkStats())
        #expect(link.framesDelivered == 30 && link.framesDropped == 0)
        #expect(link.statsReportsSent >= 1)
        #expect(link.maxDatagramSize >= 1100)
    }

    @Test func delayAndTrainsAreMeasured() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        defer { withExtendedLifetime(session) {} }
        host.sendVideoFrame(randomFrame(40_000), keyframe: true, maxPayload: 1000) // 40 datagrams
        #expect(await eventually { host.observed.lastTrains > 0 })
        let o = host.observed
        #expect(o.lastTrainDatagrams == 40)
        #expect(o.lastTrainBytes == 39 * (1000 + 17)) // every datagram after the first, headers included
        #expect(o.lastDelaySamples >= 1)
        #expect(o.lastDelayMin <= o.lastDelayAvg)
    }

    @Test func lossIsReportedAndFramesDropUntilKeyframe() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        // 0 key, 1, 2 (a slice lost), 3, 4, 5 key, 6
        for i in 0..<7 {
            host.sendVideoFrame(randomFrame(5000), keyframe: i == 0 || i == 5, dropSlices: i == 2 ? [1] : [],
                                maxPayload: 1000)
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await eventually { rec.snapshot.frames.map(\.id) == [0, 1, 5, 6] })
        #expect(await eventually { Set(host.observed.lostFrameIDs) == [2, 3, 4] })
        #expect(host.takeKeyframeWanted())
        let link = try #require(session.linkStats())
        #expect(link.framesDropped == 2) // 3 and 4 completed but waited for the keyframe
    }

    @Test func decoderRejectionCountsAsLoss() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec, acceptFrames: false)
        host.sendVideoFrame(randomFrame(3000), keyframe: true)
        #expect(await eventually { host.observed.lostFrameIDs == [0] })
        // A rejected frame also asks for a keyframe (§7.6).
        #expect(await eventually { host.observed.keyframeRequests >= 1 })
        withExtendedLifetime(session) {}
    }

    @Test func frameIDsWrapAround() async throws {
        var hc = GDPTestHost.Configuration()
        hc.firstFrameID = 0xFFFF_FFFE
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = try await connected(host, rec)
        defer { withExtendedLifetime(session) {} }
        // 0xFFFFFFFE key, 0xFFFFFFFF lost entirely, 0 key, 1
        host.sendVideoFrame(randomFrame(3000), keyframe: true, maxPayload: 1000)
        host.sendVideoFrame(randomFrame(3000), keyframe: false, dropSlices: [0, 1, 2], maxPayload: 1000)
        host.sendVideoFrame(randomFrame(3000), keyframe: true, maxPayload: 1000)
        host.sendVideoFrame(randomFrame(3000), keyframe: false, maxPayload: 1000)
        #expect(await eventually { rec.snapshot.frames.map(\.id) == [0xFFFF_FFFE, 0, 1] })
        #expect(await eventually { host.observed.lastHighestFrameID == 1 })
        #expect(host.observed.lastLossBitmap == 0b100) // frame 1 - 2 = 0xFFFFFFFF
        #expect(host.observed.lostFrameIDs == [0xFFFF_FFFF])
    }
}

@Suite("Session control and input (§7, §8)")
struct ControlTests {
    @Test func hostMessagesReachTheHandlers() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        #expect(await eventually { rec.snapshot.cursors.count == 1 })
        host.sendCursorShape(width: 4, height: 4, hotspotX: 1, hotspotY: 2, argb: [UInt8](repeating: 0x7f, count: 64))
        host.sendCursorShape(width: 4, height: 4, hotspotX: 0, hotspotY: 0, argb: [UInt8](repeating: 0, count: 10)) // bad length
        host.sendCursorShape(width: 0, height: 0, hotspotX: 0, hotspotY: 0, argb: []) // hidden
        host.sendCursorPosition(x: 0.25, y: 0.75)
        host.sendNetworkProfile(.mobile)
        host.sendDisplaysChanged(width: 2560, height: 1440)
        host.sendGatewayPath(upstreamRTTMicroseconds: 40_000)
        #expect(await eventually { rec.snapshot.cursors.count == 3 && !rec.snapshot.displays.isEmpty })
        let s = rec.snapshot
        #expect(s.cursors[1] == GDPSession.CursorShape(width: 4, height: 4, hotspotX: 1, hotspotY: 2,
                                                         bgra: [UInt8](repeating: 0x7f, count: 64)))
        #expect(s.cursors[2].width == 0 && s.cursors[2].bgra.isEmpty)
        #expect(s.positions.first.map { $0 == (0.25, 0.75) } == true)
        #expect(s.profiles == [.mobile])
        #expect(s.displays.last?.first?.width == 2560)
        // §6.10: the gateway leg is added to the RTT reported to the host.
        #expect(await eventually { host.observed.lastRTT >= 40_000 })
        #expect(session.linkStats()?.upstreamRTTMicroseconds == 40_000)
    }

    @Test func diagnosticsAreAnsweredOnceAndCapped() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let box = Mutex<GDPSession?>(nil)
        let session = GDPSession(handlers: rec.handlers(onDiagnostics: {
            let report = Data(repeating: 0x41, count: 600 * 1024)
            box.withLock { $0 }?.sendDiagnosticsReport(report)
            box.withLock { $0 }?.sendDiagnosticsReport(report) // a second answer is not sent
        }))
        box.withLock { $0 = session }
        try session.connect(host.sessionConfiguration())
        #expect(await eventually { rec.snapshot.accept != nil })
        host.sendDiagnosticsRequest()
        #expect(await eventually { host.observed.diagnosticsReportLength > 0 })
        #expect(host.observed.diagnosticsReportLength == 512 * 1024) // §7.11
        #expect(rec.snapshot.diagnosticsRequests == 1)
        box.withLock { $0 = nil }
    }

    @Test func everyDesktopStateIsHandedOn() async throws {
        // §7.13: no capability; each one replaces the last, repeats included.
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        host.sendDesktopState(idleInhibited: true)
        host.sendDesktopState(idleInhibited: true)
        host.sendDesktopState(idleInhibited: false)
        #expect(await eventually { rec.snapshot.desktopStates.count == 3 })
        #expect(rec.snapshot.desktopStates == [true, true, false])
        session.close()
    }

    @Test func aFrameRateGoesWithoutASizeAndStaysWithAResize() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        // §6.2: a 0x0 entry asks for no size, only the rate.
        let session = try await connected(host, rec) { $0.display = .init(width: 0, height: 0, refreshMillihertz: 120_000) }
        #expect(host.observed.requestedWidth == 0 && host.observed.requestedRefreshMillihertz == 120_000)
        #expect(rec.snapshot.accept?.outputs.first?.refreshMillihertz == 120_000)
        session.requestResolution(width: 2560, height: 1440, refreshMillihertz: 144_000)
        #expect(await eventually { rec.snapshot.displays.count == 1 })
        session.requestResolution(width: 1920, height: 1080) // §7.2: 0 keeps the rate
        #expect(await eventually { rec.snapshot.displays.count == 2 })
        #expect(host.observed.lastResolutionRefreshMillihertz == 0)
        #expect(rec.snapshot.displays.map { $0.first?.refreshMillihertz } == [144_000, 144_000])
        session.close()
    }

    @Test func noFrameRateIsTheHostsSixty() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.display = .init(width: 2560, height: 1440) }
        #expect(host.observed.requestedRefreshMillihertz == 0)
        #expect(rec.snapshot.accept?.outputs.first?.refreshMillihertz == 60_000)
        session.close()
    }

    @Test func commandsAndInputReachTheHost() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        session.requestKeyframe()
        session.requestResolution(width: 2560, height: 1440, scale: 2)
        session.requestResolution(width: 1001, height: 701) // odd: refused, answered with the current size
        session.sendKey(hidUsage: 0x04, pressed: true)
        session.sendKey(hidUsage: 0x04, pressed: false)
        session.sendPointerMotion(dx: 0.5, dy: 0.25, absolute: true)
        session.sendPointerButton(0x110, pressed: true)
        session.sendPointerAxis(horizontal: 0, vertical: 1.5)
        session.sendTouch(id: 1, phase: .down, x: 0.1, y: 0.2)
        #expect(await eventually { host.observed.touches == 1 && rec.snapshot.displays.count == 2 })
        let o = host.observed
        #expect(o.keyframeRequests == 1)
        #expect(o.resolutionRequests == 2 && o.lastResolution == (1001, 701) && o.lastResolutionScale == 0)
        #expect(rec.snapshot.displays.map { $0.first?.width } == [2560, 2560])
        #expect(rec.snapshot.displays.map { $0.first?.scale } == [2, 2]) // §7.2: the scale goes with the size
        #expect(o.keyEvents == 2 && o.lastKeyUsage == 0x04 && !o.lastKeyPressed)
        #expect(o.pointerMotions == 1 && o.lastMotion == (0.5, 0.25, true))
        #expect(o.buttonEvents == 1 && o.lastButton == 0x110 && o.lastButtonPressed)
        #expect(o.axisVerticalSum == 1.5)

        session.sendLogout()
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(host.observed.logoutRequested)
        #expect(rec.snapshot.ending?.code == 40) // SESSION_ENDED (§7.10)
        #expect(rec.snapshot.ending?.isOrdinaryEnd == true)
    }

    @Test func inputArrivesInOrder() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        defer { withExtendedLifetime(session) {} }
        session.sendKey(hidUsage: 0xE3, pressed: true)
        session.sendPointerMotion(dx: 3, dy: -2, absolute: false)
        session.sendPointerButton(0x111, pressed: true)
        session.sendPointerAxis(horizontal: -0.5, vertical: 0.25)
        session.sendTouch(id: 9, phase: .up, x: 0.5, y: 0.5)
        session.sendKey(hidUsage: 0xE3, pressed: false)
        #expect(await eventually { host.observed.inputEventCount == 6 })
        #expect(host.inputEvents() == [
            .key(usage: 0xE3, pressed: true), .motion(x: 3, y: -2, absolute: false), .button(0x111, pressed: true),
            .axis(horizontal: -0.5, vertical: 0.25), .touch(id: 9, phase: 3, x: 0.5, y: 0.5),
            .key(usage: 0xE3, pressed: false),
        ])
        #expect(host.inputEvents(from: 5) == [.key(usage: 0xE3, pressed: false)])
        #expect(host.observed.axisHorizontalSum == -0.5)
    }

    @Test func simulatedPointerReportsCursorPosition() async throws {
        var hc = GDPTestHost.Configuration()
        hc.width = 1000
        hc.height = 500
        hc.simulatePointer = true
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = try await connected(host, rec)
        defer { withExtendedLifetime(session) {} }
        session.sendPointerMotion(dx: 0.25, dy: 0.5, absolute: true) // placed: no CursorPosition (§7.4)
        session.sendPointerMotion(dx: 100, dy: -50, absolute: false)
        #expect(await eventually { rec.snapshot.positions.count >= 1 && host.observed.pointerMotions == 2 })
        let last = try #require(rec.snapshot.positions.last)
        #expect(abs(last.0 - 0.35) < 1e-9 && abs(last.1 - 0.4) < 1e-9)
        session.sendPointerMotion(dx: -5000, dy: 0, absolute: false) // clamped to the left edge
        #expect(await eventually { rec.snapshot.positions.last?.0 == 0 })
    }

    @Test func closeAndWaitClosesBeforeReturning() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        // Queued right before the close: all of it goes out first (key
        // releases before detaching, §8.2), not discarded by the close.
        for usage in UInt32(0x04)..<0x18 { session.sendKey(hidUsage: usage, pressed: false) }
        #expect(session.closeAndWait(timeout: 2))
        #expect(rec.snapshot.ending?.code == 0)
        // The host hears a normal close, not an idle timeout.
        #expect(await eventually(.seconds(2)) { host.observed.viewerClosed })
        #expect(host.observed.viewerCloseCode == 0)
        #expect(host.observed.keyEvents == 20)
        #expect(session.closeAndWait(timeout: 0.1)) // already closed: returns at once
    }

    @Test func audioPacketsAreHandedUp() async throws {
        var hc = GDPTestHost.Configuration()
        hc.audio = true
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = try await connected(host, rec)
        defer { withExtendedLifetime(session) {} }
        #expect(rec.snapshot.accept?.audio == GDPSession.AudioConfig(codec: "opus", sampleRate: 48000, channels: 2,
                                                                     frameMilliseconds: 10))
        host.sendAudioPacket(sequence: 7, pts: 1234, opus: [1, 2, 3, 4])
        #expect(await eventually { !rec.snapshot.audio.isEmpty })
        let packet = try #require(rec.snapshot.audio.first)
        #expect(packet.0 == 7 && packet.1 == 1234 && packet.2 == [1, 2, 3, 4])
    }

    /// The test host stamps audio as a host does (§10): seq from 0, pts from
    /// the session clock; and advertises the format it is configured with.
    @Test func hostStampedAudioAndOtherFormats() async throws {
        var hc = GDPTestHost.Configuration()
        hc.audio = true
        hc.audioFormat = GDPSession.AudioConfig(codec: "opus", sampleRate: 24000, channels: 1, frameMilliseconds: 20)
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = try await connected(host, rec)
        defer { withExtendedLifetime(session) {} }
        #expect(rec.snapshot.accept?.audio == hc.audioFormat)
        for i in 0..<3 {
            host.sendAudio(opus: [UInt8(i)])
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await eventually { rec.snapshot.audio.count == 3 })
        let packets = rec.snapshot.audio
        #expect(packets.map(\.0) == [0, 1, 2])
        #expect(packets.map(\.2) == [[0], [1], [2]])
        // Session-clock µs since SessionAccept: small, and increasing.
        #expect(packets[0].1 < 5_000_000)
        #expect(Int32(bitPattern: packets[2].1 &- packets[0].1) >= 10_000)
    }

    /// §10.1: under `microphone`, packets go out on channel 0x03 with seq
    /// from 0 and pts on the client's session clock; SessionAccept.microphone
    /// gives the format.
    @Test func microphonePacketsReachTheHost() async throws {
        var hc = GDPTestHost.Configuration()
        hc.capabilities = ["microphone"]
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = ["microphone"] }
        defer { withExtendedLifetime(session) {} }
        let accept = try #require(rec.snapshot.accept)
        #expect(accept.capabilities == ["microphone"])
        #expect(accept.microphone == GDPSession.AudioConfig(codec: "opus", sampleRate: 48000, channels: 1,
                                                            frameMilliseconds: 10))
        for i in 0..<3 {
            session.sendMicrophone(opus: [0x70, UInt8(i), 0xAA])
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await eventually { host.observed.microphonePackets == 3 })
        let packets = host.microphonePackets()
        #expect(packets.map(\.sequence) == [0, 1, 2])
        #expect(packets.map(\.opus) == [[0x70, 0, 0xAA], [0x70, 1, 0xAA], [0x70, 2, 0xAA]])
        #expect(packets[0].pts < 5_000_000) // µs since SessionAccept
        #expect(Int32(bitPattern: packets[2].pts &- packets[0].pts) >= 20_000)
        #expect(host.microphonePackets(from: 2).map(\.sequence) == [2])
        #expect(host.latestMicrophonePacket == packets.last)
        #expect(host.observed.microphoneDropped == 0)
        #expect(session.linkStats()?.microphoneSent == 3)
    }

    /// Without `microphone` in effect nothing is sent (§6.7, §10.1), whichever
    /// side lacks it; and a host's format comes only with the capability.
    @Test(arguments: [(true, false), (false, true)])
    func noMicrophoneWithoutTheCapability(clientOffers: Bool, hostSupports: Bool) async throws {
        var hc = GDPTestHost.Configuration()
        if hostSupports { hc.capabilities = ["microphone"] }
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = try await connected(host, rec) { if clientOffers { $0.capabilities = ["microphone"] } }
        defer { withExtendedLifetime(session) {} }
        #expect(rec.snapshot.accept?.microphone == nil)
        #expect(rec.snapshot.accept?.capabilities.isEmpty == true)
        session.sendMicrophone(opus: [1, 2, 3])
        #expect(await eventually { session.linkStats()?.microphoneDropped == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.observed.microphonePackets == 0 && host.observed.microphoneDropped == 0)
    }

    @Test func hostCloseEndsTheSession() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        defer { withExtendedLifetime(session) {} }
        host.close(code: 42) // TAKEN_OVER
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(rec.snapshot.ending?.code == 42)
        #expect(rec.snapshot.ending?.reason.isEmpty == false)
    }
}

@Suite("Clipboard (§7.9)")
struct ClipboardTests {
    func clipboardHost(_ text: String? = nil) throws -> GDPTestHost {
        var hc = GDPTestHost.Configuration()
        hc.capabilities = ["clipboard"]
        hc.clipboard = text
        return try GDPTestHost(hc)
    }

    @Test func hostClipboardArrivesRightAfterAccept() async throws {
        let host = try clipboardHost("from the desktop")
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = [GDPSession.Capability.clipboard] }
        defer { withExtendedLifetime(session) {} }
        #expect(rec.snapshot.accept?.capabilities == ["clipboard"])
        #expect(await eventually { rec.snapshot.clipboards == ["from the desktop"] })
        host.sendClipboard("über ✓ 剪贴板")
        #expect(await eventually { rec.snapshot.clipboards.count == 2 })
        #expect(rec.snapshot.clipboards.last == "über ✓ 剪贴板")
    }

    @Test func invalidHostClipboardIsDropped() async throws {
        let host = try clipboardHost()
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = ["clipboard"] }
        defer { withExtendedLifetime(session) {} }
        let largest = [UInt8](repeating: UInt8(ascii: "a"), count: GDPSession.maxClipboardBytes)
        host.sendClipboard(Array("<b>html</b>".utf8), mimeType: "text/html")
        host.sendClipboard([UInt8]())
        host.sendClipboard(largest + [UInt8(ascii: "a")])
        host.sendClipboard([0x66, 0xff, 0xfe]) // not UTF-8
        host.sendClipboard(largest)
        host.sendClipboard("last")
        #expect(await eventually { rec.snapshot.clipboards.last == "last" })
        #expect(rec.snapshot.clipboards.map(\.utf8.count) == [GDPSession.maxClipboardBytes, 4])
    }

    @Test func nothingCrossesWithoutTheCapability() async throws {
        // The host supports it, the client doesn't offer it.
        let host = try clipboardHost("secret")
        let rec = Recorder()
        let session = try await connected(host, rec)
        defer { withExtendedLifetime(session) {} }
        #expect(rec.snapshot.accept?.capabilities.isEmpty == true)
        host.sendClipboard("ignored")
        session.sendClipboardText("not sent")
        host.sendPing(nonce: 5) // round trip: whatever was sent before it has arrived
        #expect(await eventually { host.observed.pongs == 1 })
        #expect(rec.snapshot.clipboards.isEmpty)
        #expect(host.observed.clipboardMessages == 0)

        // The client offers it, the host doesn't support it.
        let other = try GDPTestHost()
        let rec2 = Recorder()
        let session2 = try await connected(other, rec2) { $0.capabilities = ["clipboard"] }
        defer { withExtendedLifetime(session2) {} }
        session2.sendClipboardText("not sent")
        other.sendPing(nonce: 6)
        #expect(await eventually { other.observed.pongs == 1 })
        #expect(other.observed.clipboardMessages == 0)
    }

    @Test func clientClipboardReachesTheHost() async throws {
        let host = try clipboardHost()
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = ["clipboard"] }
        session.sendClipboardText("")
        session.sendClipboardText(String(repeating: "é", count: GDPSession.maxClipboardBytes / 2 + 1)) // 2 bytes each
        session.sendClipboardText("copied on the Mac ⌘")
        #expect(await eventually { host.observed.clipboardMessages > 0 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(host.observed.clipboardMessages == 1) // the empty and the oversized one were not sent
        #expect(host.observed.lastClipboardMime == "text/plain")
        #expect(host.lastClipboard == Array("copied on the Mac ⌘".utf8))
        #expect(rec.snapshot.clipboards.isEmpty) // a host without a clipboard sends nothing on attach

        // It is now the host's clipboard, which the next viewer gets on attach.
        session.close()
        #expect(await eventually { rec.snapshot.ending != nil })
        let rec2 = Recorder()
        let session2 = try await connected(host, rec2) { $0.capabilities = ["clipboard"] }
        defer { withExtendedLifetime(session2) {} }
        #expect(await eventually { rec2.snapshot.clipboards == ["copied on the Mac ⌘"] })
    }
}

@Suite("Gamepads (§8.5)")
struct GamepadTests {
    func gamepadHost() throws -> GDPTestHost {
        var hc = GDPTestHost.Configuration()
        hc.capabilities = [GDPSession.Capability.gamepad]
        return try GDPTestHost(hc)
    }

    /// Sends a key as a marker and waits for it: input arrives in order, so
    /// everything sent before it has arrived (or was never sent).
    func flush(_ session: GDPSession, _ host: GDPTestHost) async -> [GDPTestHost.InputEvent] {
        session.sendKey(hidUsage: 0x04, pressed: true)
        _ = await eventually { host.inputEvents().contains(.key(usage: 0x04, pressed: true)) }
        return host.inputEvents().filter { $0 != .key(usage: 0x04, pressed: true) }
    }

    @Test func connectStateAndDisconnectReachTheHost() async throws {
        let host = try gamepadHost()
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = [GDPSession.Capability.gamepad] }
        defer { withExtendedLifetime(session) {} }
        #expect(rec.snapshot.accept?.capabilities == ["gamepad"])

        var state = GamepadState()
        state[.leftX] = 0.5
        state[.leftY] = -1
        state[.rightTrigger] = 0.25
        state[.south] = true
        state[.guide] = true
        state[.misc6] = true
        session.sendGamepadConnect(slot: 3, name: "Xbox Wireless Controller")
        session.sendGamepadState(slot: 3, state)
        session.sendGamepadDisconnect(slot: 3)
        let events = await flush(session, host)
        #expect(events == [
            .gamepadConnect(slot: 3, name: "Xbox Wireless Controller"),
            // Always every axis and every button, in the spec's order.
            .gamepadState(slot: 3, axisCount: 6, buttonCount: 26, axes: [0.5, -1, 0, 0, 0, 0.25],
                          buttons: 1 << 0 | 1 << 5 | 1 << 25),
            .gamepadDisconnect(slot: 3),
        ])
    }

    @Test func axesAreClampedToTheirRanges() async throws {
        let host = try gamepadHost()
        let session = try await connected(host, Recorder()) { $0.capabilities = ["gamepad"] }
        defer { withExtendedLifetime(session) {} }
        var state = GamepadState()
        state[.leftX] = .nan
        state[.leftY] = 0.25
        state[.rightX] = 2
        state[.rightY] = -2
        state[.leftTrigger] = -0.5 // triggers are 0...1
        state[.rightTrigger] = .infinity
        session.sendGamepadState(slot: 0, state)
        let events = await flush(session, host)
        #expect(events == [.gamepadState(slot: 0, axisCount: 6, buttonCount: 26, axes: [0, 0.25, 1, -1, 0, 1], buttons: 0)])
    }

    @Test(arguments: [(true, false), (false, true)])
    func nothingIsSentWithoutTheCapability(hostSupports: Bool, clientOffers: Bool) async throws {
        var hc = GDPTestHost.Configuration()
        hc.capabilities = hostSupports ? ["gamepad"] : []
        let host = try GDPTestHost(hc)
        let session = try await connected(host, Recorder()) { $0.capabilities = clientOffers ? ["gamepad"] : [] }
        defer { withExtendedLifetime(session) {} }
        session.sendGamepadConnect(slot: 0, name: "pad")
        session.sendGamepadState(slot: 0, GamepadState())
        session.sendGamepadDisconnect(slot: 0)
        #expect(await flush(session, host).isEmpty)
    }

    @Test func slotsBeyondFourAreNotSent() async throws {
        let host = try gamepadHost()
        let session = try await connected(host, Recorder()) { $0.capabilities = ["gamepad"] }
        defer { withExtendedLifetime(session) {} }
        session.sendGamepadConnect(slot: 4, name: "fifth")
        session.sendGamepadState(slot: 4, GamepadState())
        session.sendGamepadDisconnect(slot: 4)
        #expect(await flush(session, host).isEmpty)
    }

    @Test func wireOrderMatchesTheSpec() {
        // §8.5's tables: 6 axes, 26 buttons, a few spot checks of the order.
        #expect(GamepadState.Axis.allCases.count == 6)
        #expect(GamepadState.Button.allCases.count == 26)
        #expect(GamepadState.Axis.leftTrigger.rawValue == 4)
        #expect(GamepadState.Button.guide.rawValue == 5)
        #expect(GamepadState.Button.dpadUp.rawValue == 11)
        #expect(GamepadState.Button.misc1.rawValue == 15)
        #expect(GamepadState.Button.rightPaddle1.rawValue == 16)
        #expect(GamepadState.Button.leftPaddle1.rawValue == 17)
        #expect(GamepadState.Button.touchpad.rawValue == 20)
        #expect(GamepadState.Button.misc6.rawValue == 25)
    }
}

@Suite("Lost connections")
struct LostConnectionTests {
    @Test(arguments: [UInt64(0), 40, 42])
    func anEndingTheHostChoseIsNotLost(code: UInt64) async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        defer { withExtendedLifetime(session) {} }
        host.close(code: code)
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(rec.snapshot.ending?.code == code)
        #expect(rec.snapshot.ending?.connectionLost == false)
    }

    @Test func closingItOurselvesIsNotLost() async throws {
        let host = try GDPTestHost()
        let rec = Recorder()
        let session = try await connected(host, rec)
        session.close()
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(rec.snapshot.ending?.connectionLost == false)
    }

    @Test func aNetworkThatGoesAwayIsLost() async throws {
        let host = try GDPTestHost()
        let relay = try UDPRelay(to: host.port)
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.port = relay.port }
        defer { withExtendedLifetime(session) {} }
        // Gone without a word: no close reaches the client. Past the
        // handshake libgdp ignores ICMP errors (they could be spoofed to kill
        // a live session), so only QUIC's 30 s idle timeout notices, as on
        // a phone that slept: this test takes that long.
        relay.cut()
        let cut = ContinuousClock.now
        #expect(await eventually(.seconds(45)) { rec.snapshot.ending != nil })
        print("session connection lost after \(ContinuousClock.now - cut)")
        let ending = try #require(rec.snapshot.ending)
        #expect(ending.connectionLost)
        #expect(ending.code == 0)
        #expect(!ending.reason.isEmpty)
    }

    @Test func noHostThereIsLost() async throws {
        var config: GDPSession.Configuration
        do {
            let gone = try GDPTestHost()
            config = gone.sessionConfiguration()
        } // the host is gone: nothing listens on its port
        let rec = Recorder()
        let session = GDPSession(handlers: rec.handlers())
        try session.connect(config)
        #expect(await eventually(.seconds(40)) { rec.snapshot.ending != nil })
        #expect(rec.snapshot.ending?.connectionLost == true)
        #expect(rec.snapshot.accept == nil)
    }
}
