import CoreMedia
import VideoToolbox

/// The codecs a session can negotiate (gdp-spec.md §6.6), by their wire
/// tokens (libgdp's gdp/video_codec.hpp).
public enum VideoCodec: String, Sendable, CaseIterable, Identifiable {
    case h264
    case h265
    /// AV1's low-overhead bitstream format, not Annex B (``AV1``).
    case av1
    /// The intra-only wavelet codec, decoded on the GPU (``PyroWaveDecoder``), not by VideoToolbox.
    case pyrowave

    public var id: String { rawValue }

    /// VideoToolbox's codec type; nil for PyroWave, which it doesn't know.
    var coreMediaType: CMVideoCodecType? {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .h265: kCMVideoCodecType_HEVC
        case .av1: kCMVideoCodecType_AV1
        case .pyrowave: nil
        }
    }

    /// Whether this device decodes the codec in hardware. AV1 is offered
    /// only then (Apple M3 and A17 Pro onward): decoding it in software
    /// would cost more than it saves. PyroWave decodes on the GPU, given
    /// an Apple7 GPU (A14, M1) or later.
    public var isHardwareDecodable: Bool {
        guard let coreMediaType else { return PyroWaveDevice.isSupported }
        return VTIsHardwareDecodeSupported(coreMediaType)
    }

    /// What SessionHello offers, most preferred first (gdp-spec.md §6.6):
    /// AV1 where it decodes in hardware (the better picture for the bits,
    /// where the host can encode it), then HEVC, then H.264, the floor.
    public static var offered: [VideoCodec] {
        (VideoCodec.av1.isHardwareDecodable ? [.av1] : []) + [.h265, .h264]
    }

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .h265: "HEVC"
        case .av1: "AV1"
        case .pyrowave: "PyroWave"
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
        case .av1, .pyrowave:
            .other // not NAL units
        }
    }

    var parameterSetCount: Int {
        switch self {
        case .h264: 2
        case .h265: 3
        case .av1: 1 // the sequence header
        case .pyrowave: 0 // every frame stands alone
        }
    }
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
