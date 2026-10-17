import Foundation

/// AV1's low-overhead bitstream format (AV1 spec §5.2, "Low overhead
/// bitstream format"): what a GDP video frame carries for `av1`
/// (gdp-spec.md §9.4) -- one temporal unit, a sequence of OBUs, each with
/// its size field, starting with a temporal delimiter; a keyframe's
/// carries a sequence header.
public enum AV1 {
    /// OBU types (AV1 spec §6.2.2) this client tells apart.
    public enum OBUType: UInt8, Sendable {
        case sequenceHeader = 1
        case temporalDelimiter = 2
        case frameHeader = 3
        case tileGroup = 4
        case metadata = 5
        case frame = 6
        case redundantFrameHeader = 7
        case tileList = 8
        case padding = 15
    }

    /// One OBU: `bytes` covers the whole of it (header, size field and
    /// payload), `payload` just its payload.
    public struct OBU: Sendable, Equatable {
        public let type: UInt8
        public let bytes: Range<Int>
        public let payload: Range<Int>
    }

    public enum ParseError: Error, Equatable {
        /// The forbidden bit set, no size field, or a size past the end.
        case malformedOBU
        /// A sequence header this parser can't read.
        case malformedSequenceHeader
    }

    /// The OBUs of a temporal unit. Every one must carry its size field
    /// (gdp-spec.md §9.4: `obu_has_size_field` set).
    public static func obus(in bytes: UnsafeRawBufferPointer) throws(ParseError) -> [OBU] {
        var obus: [OBU] = []
        var i = 0
        while i < bytes.count {
            let header = bytes[i]
            guard header & 0x80 == 0, header & 0x02 != 0 else { throw .malformedOBU } // forbidden bit, has_size
            var at = i + 1 + (header & 0x04 != 0 ? 1 : 0) // the extension byte
            guard at <= bytes.count, let size = leb128(bytes, at: &at), size <= bytes.count - at else {
                throw .malformedOBU
            }
            obus.append(OBU(type: (header >> 3) & 0x0f, bytes: i..<at + size, payload: at..<at + size))
            i = at + size
        }
        return obus
    }

    public static func obus(in bytes: [UInt8]) throws(ParseError) -> [OBU] {
        do {
            return try bytes.withUnsafeBytes { try obus(in: $0) }
        } catch let error as ParseError {
            throw error
        } catch {
            throw .malformedOBU
        }
    }

    /// AV1 spec §4.10.5: up to 8 bytes, 7 bits each, little end first.
    static func leb128(_ bytes: UnsafeRawBufferPointer, at i: inout Int) -> Int? {
        var value = 0
        for n in 0..<8 {
            guard i < bytes.count else { return nil }
            let b = bytes[i]
            i += 1
            value |= Int(b & 0x7f) << (7 * n)
            if b & 0x80 == 0 { return value }
        }
        return nil
    }

    /// What a decoder is configured from (AV1 spec §5.5): the profile,
    /// level and tier of operating point 0, the colour config, and the
    /// largest frame size.
    public struct SequenceHeader: Sendable, Equatable {
        public var profile: UInt8 = 0
        public var levelIndex0: UInt8 = 0
        public var tier0: UInt8 = 0
        public var highBitdepth = false
        public var twelveBit = false
        public var monochrome = false
        public var subsamplingX = true
        public var subsamplingY = true
        public var chromaSamplePosition: UInt8 = 0
        public var maxFrameWidth = 0
        public var maxFrameHeight = 0

        public var bitDepth: Int { twelveBit ? 12 : highBitdepth ? 10 : 8 }

        /// Reads a sequence header OBU's payload.
        public init(payload: UnsafeRawBufferPointer) throws(ParseError) {
            var r = BitReader(payload)
            do {
                try read(&r)
            } catch {
                throw .malformedSequenceHeader
            }
        }

        public init(payload: [UInt8]) throws(ParseError) {
            var copy: SequenceHeader?
            var failure: ParseError?
            payload.withUnsafeBytes {
                do throws(ParseError) { copy = try SequenceHeader(payload: $0) } catch { failure = error }
            }
            if let failure { throw failure }
            self = copy!
        }

        private mutating func read(_ r: inout BitReader) throws(BitReader.End) {
            profile = UInt8(try r.bits(3))
            _ = try r.bits(1) // still_picture
            let reduced = try r.bits(1) == 1
            var decoderModelInfo = false
            var bufferDelayLength = 0
            if reduced {
                levelIndex0 = UInt8(try r.bits(5))
            } else {
                if try r.bits(1) == 1 { // timing_info_present_flag
                    _ = try r.bits(32) // num_units_in_display_tick
                    _ = try r.bits(32) // time_scale
                    if try r.bits(1) == 1 { _ = try r.uvlc() } // equal_picture_interval
                    decoderModelInfo = try r.bits(1) == 1
                    if decoderModelInfo {
                        bufferDelayLength = Int(try r.bits(5)) + 1
                        _ = try r.bits(32) // num_units_in_decoding_tick
                        _ = try r.bits(5)  // buffer_removal_time_length_minus_1
                        _ = try r.bits(5)  // frame_presentation_time_length_minus_1
                    }
                }
                let initialDisplayDelay = try r.bits(1) == 1
                let operatingPoints = Int(try r.bits(5)) + 1
                for i in 0..<operatingPoints {
                    _ = try r.bits(12) // operating_point_idc
                    let level = UInt8(try r.bits(5))
                    let tier = level > 7 ? UInt8(try r.bits(1)) : 0
                    if i == 0 {
                        levelIndex0 = level
                        tier0 = tier
                    }
                    if decoderModelInfo, try r.bits(1) == 1 { // decoder_model_present_for_this_op
                        _ = try r.bits(bufferDelayLength) // decoder_buffer_delay
                        _ = try r.bits(bufferDelayLength) // encoder_buffer_delay
                        _ = try r.bits(1)                 // low_delay_mode_flag
                    }
                    if initialDisplayDelay, try r.bits(1) == 1 { _ = try r.bits(4) }
                }
            }
            let widthBits = Int(try r.bits(4)) + 1
            let heightBits = Int(try r.bits(4)) + 1
            maxFrameWidth = Int(try r.bits(widthBits)) + 1
            maxFrameHeight = Int(try r.bits(heightBits)) + 1
            if !reduced, try r.bits(1) == 1 { // frame_id_numbers_present_flag
                _ = try r.bits(4)
                _ = try r.bits(3)
            }
            _ = try r.bits(3) // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
            if !reduced {
                _ = try r.bits(4) // interintra_compound, masked_compound, warped_motion, dual_filter
                let orderHint = try r.bits(1) == 1
                if orderHint { _ = try r.bits(2) } // jnt_comp, ref_frame_mvs
                let forceScreenContentTools = try r.bits(1) == 1 ? 2 : try r.bits(1) // seq_choose_screen_content_tools
                if forceScreenContentTools > 0, try r.bits(1) == 0 { _ = try r.bits(1) } // seq_choose_integer_mv
                if orderHint { _ = try r.bits(3) } // order_hint_bits_minus_1
            }
            _ = try r.bits(3) // enable_superres, enable_cdef, enable_restoration
            try readColorConfig(&r)
        }

        /// AV1 spec §5.5.2.
        private mutating func readColorConfig(_ r: inout BitReader) throws(BitReader.End) {
            highBitdepth = try r.bits(1) == 1
            if profile == 2, highBitdepth { twelveBit = try r.bits(1) == 1 }
            monochrome = profile == 1 ? false : try r.bits(1) == 1
            var primaries: UInt32 = 2, transfer: UInt32 = 2, matrix: UInt32 = 2 // unspecified
            if try r.bits(1) == 1 { // color_description_present_flag
                primaries = try r.bits(8)
                transfer = try r.bits(8)
                matrix = try r.bits(8)
            }
            if monochrome {
                _ = try r.bits(1) // color_range
                subsamplingX = true
                subsamplingY = true
                chromaSamplePosition = 0
                return
            }
            if primaries == 1, transfer == 13, matrix == 0 { // BT.709, sRGB, identity: 4:4:4 RGB
                subsamplingX = false
                subsamplingY = false
            } else {
                _ = try r.bits(1) // color_range
                switch profile {
                case 0:
                    subsamplingX = true
                    subsamplingY = true
                case 1:
                    subsamplingX = false
                    subsamplingY = false
                default:
                    if bitDepth == 12 {
                        subsamplingX = try r.bits(1) == 1
                        subsamplingY = subsamplingX ? try r.bits(1) == 1 : false
                    } else {
                        subsamplingX = true
                        subsamplingY = false
                    }
                }
                if subsamplingX, subsamplingY { chromaSamplePosition = UInt8(try r.bits(2)) }
            }
        }

        /// The AV1CodecConfigurationRecord ("av1C", AV1 ISOBMFF binding §2.3)
        /// for `sequenceHeaderOBU`, the whole OBU this header came from.
        public func codecConfiguration(sequenceHeaderOBU: [UInt8]) -> [UInt8] {
            let b0: UInt8 = 0x81 // marker 1, version 1
            let b1 = profile << 5 | levelIndex0 & 0x1f
            var b2: UInt8 = tier0 << 7
            if highBitdepth { b2 |= 0x40 }
            if twelveBit { b2 |= 0x20 }
            if monochrome { b2 |= 0x10 }
            if subsamplingX { b2 |= 0x08 }
            if subsamplingY { b2 |= 0x04 }
            b2 |= chromaSamplePosition & 0x03
            return [b0, b1, b2, 0] + sequenceHeaderOBU // no initial_presentation_delay
        }
    }
}

/// Reads bits most significant first (AV1 spec §4.10: f(n)).
struct BitReader {
    struct End: Error {}

    private let bytes: UnsafeRawBufferPointer
    private var position = 0

    init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    mutating func bits(_ n: Int) throws(End) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<n {
            guard position < bytes.count * 8 else { throw End() }
            let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
            value = value << 1 | UInt32(bit)
            position += 1
        }
        return value
    }

    /// AV1 spec §4.10.3.
    mutating func uvlc() throws(End) -> UInt32 {
        var leadingZeros = 0
        while try bits(1) == 0 {
            leadingZeros += 1
            if leadingZeros >= 32 { return UInt32.max }
        }
        return leadingZeros == 0 ? 0 : try bits(leadingZeros) + (1 << leadingZeros) - 1
    }
}
