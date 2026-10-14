import Foundation
import Testing
@testable import GDPKit

private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

@Suite("Fingerprints (§2.3)")
struct FingerprintTests {
    // FIPS 180-2 / NIST test vectors, as libgdp's cert_fingerprint_test uses.
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
    ])
    func sha256Vectors(input: String, expected: String) {
        #expect(hex(SHA256.digest(Array(input.utf8))) == expected)
        #expect(CertificateFingerprint(certificateDER: Array(input.utf8)).hex == expected)
    }

    @Test func sha256MillionA() {
        let digest = SHA256.digest([UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000))
        #expect(hex(digest) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func parsesOnlyWireForm() {
        let good = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(CertificateFingerprint(hex: good)?.hex == good)
        #expect(CertificateFingerprint(hex: good.uppercased()) == nil) // wire form is lowercase
        #expect(CertificateFingerprint(hex: String(good.dropLast())) == nil)
        #expect(CertificateFingerprint(hex: good + "0") == nil)
        #expect(CertificateFingerprint(hex: String(good.dropLast()) + "g") == nil)
        #expect(CertificateFingerprint(hex: "") == nil)
    }

    @Test func displayForm() throws {
        let fp = try #require(CertificateFingerprint(hex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        #expect(fp.displayString
            == "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD")
    }

    @Test func protocolConstants() {
        #expect(GDP.alpn == "gdp/1")
        #expect(GDP.wireVersion == 1)
    }
}

@Suite("Control-stream framing (§3.1)")
struct FramingTests {
    @Test func pingWireFormat() {
        // ControlEnvelope{ping{nonce: 1}}: field 5 (LEN) -> Ping, field 1 (VARINT) = 1.
        #expect(ControlFraming.ping(nonce: 1) == [4, 0, 0, 0, 0x2a, 0x02, 0x08, 0x01])
    }

    @Test func wholeFramesRoundTrip() throws {
        let reader = ControlFrameReader()
        let frames = try reader.feed(ControlFraming.ping(nonce: 42) + ControlFraming.keyframeRequest(streamID: 3))
        #expect(frames.map(\.message) == [.ping(nonce: 42), .keyframeRequest(streamID: 3)])
    }

    @Test func arbitraryChunkingYieldsTheSameFrames() throws {
        let nonces: [UInt64] = [0, 1, 300, .max, 0xdead_beef]
        let stream = nonces.flatMap { ControlFraming.pong(nonce: $0) }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let reader = ControlFrameReader()
            var got: [ControlFrame.Message] = []
            var i = 0
            while i < stream.count {
                let n = Int.random(in: 1...7, using: &rng)
                got += try reader.feed(stream[i..<min(i + n, stream.count)]).map(\.message)
                i += n
            }
            #expect(got == nonces.map { .pong(nonce: $0) })
        }
    }

    @Test func byteAtATime() throws {
        let reader = ControlFrameReader()
        let bytes = ControlFraming.ping(nonce: 7)
        for b in bytes.dropLast() {
            #expect(try reader.feed([b]).isEmpty)
        }
        #expect(try reader.feed([bytes.last!]).map(\.message) == [.ping(nonce: 7)])
    }

    @Test func oversizedLengthPrefixIsFrameTooLarge() {
        let reader = ControlFrameReader()
        let tooBig = UInt32(ControlFraming.maxFrameSize + 1)
        let prefix = withUnsafeBytes(of: tooBig.littleEndian, Array.init)
        #expect(throws: ControlFramingError.frameTooLarge(errorCode: 12)) { try reader.feed(prefix) }
    }

    @Test func preAuthenticationCap() {
        let reader = ControlFrameReader(maxFrameSize: 16 * 1024)
        let prefix = withUnsafeBytes(of: UInt32(16 * 1024 + 1).littleEndian, Array.init)
        #expect(throws: ControlFramingError.frameTooLarge(errorCode: 12)) { try reader.feed(prefix) }
    }

    @Test func garbageIsMalformed() {
        let reader = ControlFrameReader()
        // A 3-byte frame whose body is an invalid protobuf (field 0 is illegal).
        #expect(throws: ControlFramingError.malformed(errorCode: 11)) { try reader.feed([3, 0, 0, 0, 0x00, 0xff, 0xff]) }
    }
}

@Suite("Video datagrams (§9)")
struct VideoDatagramTests {
    @Test func headerWireLayout() throws {
        let header = VideoDatagramHeader(streamID: 2, frameID: 0x0403_0201, keyframe: true, pts: 0x0807_0605,
                                         hostLatencyMicroseconds: 1234)
        let datagrams = VideoDatagram.slice([0xaa, 0xbb], header: header, maxPayload: 1100)
        #expect(datagrams.count == 1)
        // channel, stream_id, frame_id LE, slice_idx, slice_count, flags, pts LE, host_lat (123 units of 10 µs), payload
        #expect(datagrams[0] == [0x01, 2, 1, 2, 3, 4, 0, 0, 1, 0, 0x01, 5, 6, 7, 8, 123, 0, 0xaa, 0xbb])
        let (decoded, payload) = try #require(VideoDatagram.decode(datagrams[0]))
        #expect(decoded.frameID == header.frameID && decoded.pts == header.pts && decoded.keyframe)
        #expect(decoded.hostLatencyMicroseconds == 1230)
        #expect(Array(datagrams[0][payload]) == [0xaa, 0xbb])
    }

    @Test func rejectsNonVideo() {
        #expect(VideoDatagram.decode([]) == nil)
        #expect(VideoDatagram.decode([0x02] + [UInt8](repeating: 0, count: 16)) == nil) // audio channel
        #expect(VideoDatagram.decode([0x01] + [UInt8](repeating: 0, count: 15)) == nil) // short header
    }

    @Test func slicePayloadFollowsMTU() {
        #expect(VideoDatagram.slicePayload(forMaxDatagramSize: 0) == VideoDatagram.fallbackPayload)
        #expect(VideoDatagram.slicePayload(forMaxDatagramSize: 1432) == 1432 - 1 - VideoDatagram.headerSize)
    }

    @Test func shuffledSlicesReassemble() throws {
        var rng = SystemRandomNumberGenerator()
        let frame = (0..<50_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let datagrams = VideoDatagram.slice(frame, header: VideoDatagramHeader(frameID: 9, keyframe: true, pts: 77),
                                            maxPayload: 1100)
        #expect(datagrams.count == (frame.count + 1099) / 1100)

        let reassembler = VideoFrameReassembler()
        let shuffled = datagrams.shuffled(using: &rng)
        for d in shuffled.dropLast() {
            #expect(reassembler.push(d) == nil)
            #expect(reassembler.push(d) == nil) // duplicates are ignored
        }
        let done = try #require(reassembler.push(shuffled.last!))
        #expect(done.data == frame && done.frameID == 9 && done.keyframe && done.pts == 77)
    }

    @Test func newerFrameDropsIncompleteOlder() {
        let reassembler = VideoFrameReassembler()
        let old = VideoDatagram.slice([UInt8](repeating: 1, count: 3000), header: VideoDatagramHeader(frameID: 1),
                                      maxPayload: 1000)
        let new = VideoDatagram.slice([UInt8](repeating: 2, count: 1500), header: VideoDatagramHeader(frameID: 2),
                                      maxPayload: 1000)
        #expect(reassembler.push(old[0]) == nil)
        #expect(reassembler.push(new[0]) == nil)
        #expect(reassembler.push(old[1]) == nil) // frame 1 was discarded; this restarts it
        #expect(reassembler.push(new[1]) == nil) // and that discarded frame 2
    }
}

@Suite("QUIC transport (ngtcp2 + OpenSSL)")
struct TransportTests {
    @Test(.timeLimit(.minutes(1))) func loopbackSession() throws {
        let report = try QUICSelfTest.run(timeout: .seconds(15))
        print(report)
        #expect(report.fingerprint != nil)
        #expect(report.datagramsReceived > 0)
        #expect(report.maxDatagramSize >= 1100)
    }
}
