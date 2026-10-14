import CoreMedia

/// The block-based codecs a session can negotiate (gdp-spec.md §6.6), by
/// their wire tokens (libgdp's gdp/video_codec.hpp).
public enum VideoCodec: String, Sendable, CaseIterable, Identifiable {
    case h264
    case h265

    public var id: String { rawValue }

    var coreMediaType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .h265: kCMVideoCodecType_HEVC
        }
    }

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .h265: "HEVC"
        }
    }

    /// What one NAL unit is, for splitting an access unit into parameter sets and picture data.
    enum NALKind: Equatable {
        case parameterSet(index: Int) // h264: SPS 0, PPS 1; h265: VPS 0, SPS 1, PPS 2
        case accessUnitDelimiter
        case keyframeSlice
        case other // slices, SEI, ...
    }

    func kind(ofNALHeader byte: UInt8) -> NALKind {
        switch self {
        case .h264:
            switch byte & 0x1f {
            case 7: .parameterSet(index: 0)
            case 8: .parameterSet(index: 1)
            case 9: .accessUnitDelimiter
            case 5: .keyframeSlice
            default: .other
            }
        case .h265:
            switch (byte >> 1) & 0x3f {
            case 32: .parameterSet(index: 0)
            case 33: .parameterSet(index: 1)
            case 34: .parameterSet(index: 2)
            case 35: .accessUnitDelimiter
            case 16...21: .keyframeSlice // BLA, IDR, CRA
            default: .other
            }
        }
    }

    var parameterSetCount: Int { self == .h264 ? 2 : 3 }
}

/// Annex B byte streams (ITU-T H.264/H.265 Annex B): what a GDP video frame
/// carries for h264/h265 (gdp-spec.md §9.4) -- start codes, then NAL units.
public enum AnnexB {
    public static let startCode: [UInt8] = [0, 0, 0, 1]

    /// The NAL units in `bytes`, as ranges without their start codes. Accepts
    /// 3- and 4-byte start codes; a 4-byte one's leading zero is not counted
    /// as part of the previous unit.
    public static func nalUnits(in bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        var units: [Range<Int>] = []
        let n = bytes.count
        var i = 0
        var start: Int? = nil
        while i + 2 < n {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    var end = i
                    while end > s, bytes[end - 1] == 0 { end -= 1 }
                    if end > s { units.append(s..<end) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < n {
            var end = n
            while end > s, bytes[end - 1] == 0 { end -= 1 }
            if end > s { units.append(s..<end) }
        }
        return units
    }

    public static func nalUnits(in bytes: [UInt8]) -> [Range<Int>] {
        bytes.withUnsafeBytes { nalUnits(in: $0) }
    }
}
