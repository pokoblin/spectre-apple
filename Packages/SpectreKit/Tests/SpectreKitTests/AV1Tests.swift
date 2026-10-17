import CoreVideo
import Synchronization
import Testing
@testable import SpectreKit

@Suite("AV1 bitstream (gdp-spec.md §9.4)")
struct AV1BitstreamTests {
    @Test func obusAreSplitBySizeField() throws {
        // A temporal delimiter, a padding OBU with an extension byte, and a 3-byte frame OBU.
        let bytes: [UInt8] = [0x12, 0x00,
                              0x7e, 0x00, 0x02, 0xaa, 0xbb,
                              0x32, 0x03, 1, 2, 3]
        let obus = try AV1.obus(in: bytes)
        #expect(obus.map(\.type) == [2, 15, 6])
        #expect(obus.map(\.bytes) == [0..<2, 2..<7, 7..<12])
        #expect(obus.map(\.payload) == [2..<2, 5..<7, 9..<12])
    }

    @Test func malformedOBUsAreRefused() {
        #expect(throws: AV1.ParseError.malformedOBU) { try AV1.obus(in: [0x10, 0x00]) }        // no size field
        #expect(throws: AV1.ParseError.malformedOBU) { try AV1.obus(in: [0x92, 0x00]) }        // forbidden bit
        #expect(throws: AV1.ParseError.malformedOBU) { try AV1.obus(in: [0x32, 0x05, 1, 2]) }  // size past the end
        #expect(throws: AV1.ParseError.malformedOBU) { try AV1.obus(in: [0x32, 0x80]) }        // size cut short
    }

    @Test func theFixturesSequenceHeaderIsRead() throws {
        let stream = try #require(TestStream.av1())
        #expect(stream.accessUnits.count == 60)
        #expect(stream.accessUnits.map(\.keyframe) == [true] + Array(repeating: false, count: 59))
        let first = stream.accessUnits[0].bytes
        let obus = try AV1.obus(in: first)
        #expect(obus.first?.type == AV1.OBUType.temporalDelimiter.rawValue)
        let header = try #require(obus.first { $0.type == AV1.OBUType.sequenceHeader.rawValue })
        let seq = try AV1.SequenceHeader(payload: Array(first[header.payload]))
        #expect(seq.profile == 0 && seq.bitDepth == 8 && !seq.monochrome)
        #expect(seq.subsamplingX && seq.subsamplingY) // 4:2:0, the baseline (§7.3)
        #expect(seq.maxFrameWidth == 1280 && seq.maxFrameHeight == 720)

        let headerOBU = Array(first[header.bytes])
        let config = seq.codecConfiguration(sequenceHeaderOBU: headerOBU)
        #expect(config[0] == 0x81)
        #expect(config[1] == seq.profile << 5 | seq.levelIndex0)
        #expect(config[2] & 0x0c == 0x0c) // chroma_subsampling_x, _y
        #expect(Array(config[4...]) == headerOBU)
        // Every other temporal unit: a delimiter and one frame, no header.
        for unit in stream.accessUnits.dropFirst() {
            #expect(try AV1.obus(in: unit.bytes).map(\.type) == [2, 6])
        }
    }

    @Test func av1IsOfferedFirstOnlyWithHardwareDecode() {
        let offered = VideoCodec.offered
        #expect(offered.suffix(2) == [.h265, .h264])
        #expect(offered.first == (VideoCodec.av1.isHardwareDecodable ? .av1 : .h265))
    }
}

@Suite("AV1 decoding", .enabled(if: VideoCodec.av1.isHardwareDecodable, "no AV1 hardware decoder here"))
struct AV1DecodeTests {
    @Test func everyTemporalUnitDecodesAtItsSize() throws {
        let stream = try #require(TestStream.av1())
        let frames = Mutex<[(UInt32, Int, Int)]>([])
        let decoder = VideoDecoder(codec: .av1) { f in
            frames.withLock {
                $0.append((f.frameID, CVPixelBufferGetWidth(f.pixelBuffer), CVPixelBufferGetHeight(f.pixelBuffer)))
            }
        }
        for (i, unit) in stream.accessUnits.enumerated() {
            try unit.bytes.withUnsafeBytes { try decoder.decode($0, pts: UInt32(i) * 16_667, frameID: UInt32(i)) }
        }
        decoder.flush()
        let got = frames.withLock { $0 }
        #expect(got.map(\.0) == Array(0..<60))
        #expect(got.allSatisfy { $0.1 >= 1280 && $0.2 >= 720 })
        #expect(decoder.isHardwareAccelerated)
    }

    @Test func framesBeforeTheKeyframeAndMalformedOnesAreRefused() throws {
        let stream = try #require(TestStream.av1())
        let decoder = VideoDecoder(codec: .av1) { _ in }
        #expect(throws: VideoDecoderError.self) {
            try stream.accessUnits[1].bytes.withUnsafeBytes { try decoder.decode($0, pts: 0) }
        }
        #expect(throws: VideoDecoderError.self) {
            try [UInt8]([0x12, 0x00, 0x32, 0x09, 1]).withUnsafeBytes { try decoder.decode($0, pts: 0) }
        }
        // The keyframe still starts it.
        try stream.accessUnits[0].bytes.withUnsafeBytes { try decoder.decode($0, pts: 0) }
        try stream.accessUnits[1].bytes.withUnsafeBytes { try decoder.decode($0, pts: 16_667) }
    }
}
