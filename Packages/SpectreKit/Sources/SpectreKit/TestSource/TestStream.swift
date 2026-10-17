import CoreMedia
import Foundation
import Synchronization
import VideoToolbox

/// One coded frame as a GDP video frame carries it (gdp-spec.md §9.4): an
/// Annex B access unit, parameter sets in-band on keyframes.
public struct AccessUnit: Sendable {
    public let bytes: [UInt8]
    public let keyframe: Bool
}

/// A pre-encoded stream standing in for what wraith would send, until the
/// client talks to a real host.
public struct TestStream: Sendable {
    public let codec: VideoCodec
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let accessUnits: [AccessUnit]

    public init(codec: VideoCodec, width: Int, height: Int, framesPerSecond: Int, accessUnits: [AccessUnit]) {
        self.codec = codec
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.accessUnits = accessUnits
    }

    public var totalBytes: Int { accessUnits.reduce(0) { $0 + $1.bytes.count } }
    public var averageBitrate: Double {
        Double(totalBytes * 8) * Double(framesPerSecond) / Double(max(accessUnits.count, 1))
    }

    /// The whole stream as one Annex B byte stream (a `.h264` / `.h265` file).
    public var annexB: Data { Data(accessUnits.flatMap(\.bytes)) }

    /// Splits an Annex B byte stream into access units: a new one starts at
    /// each first slice of a picture (H.264 `first_mb_in_slice == 0`, H.265
    /// `first_slice_segment_in_pic_flag`), and the parameter sets, SEI and
    /// delimiters before it belong to it.
    public init(annexB data: Data, codec: VideoCodec, width: Int, height: Int, framesPerSecond: Int) {
        let bytes = [UInt8](data)
        let units = AnnexB.nalUnits(in: bytes)
        var aus: [AccessUnit] = []
        var auStart: Int? = nil  // byte offset (start code included) of the current access unit
        var pendingStart: Int? = nil  // first non-VCL unit since the last picture's slices
        var sawSlice = false
        var keyframe = false

        func startCodeOffset(_ r: Range<Int>) -> Int {
            var s = r.lowerBound - 3
            if s > 0, bytes[s - 1] == 0 { s -= 1 }
            return s
        }
        func flush(upTo end: Int) {
            if let s = auStart, end > s {
                aus.append(AccessUnit(bytes: Array(bytes[s..<end]), keyframe: keyframe))
            }
        }

        for r in units {
            let header = bytes[r.lowerBound]
            let kind = codec.kind(ofNALHeader: header)
            let isSlice: Bool
            let firstSliceOfPicture: Bool
            switch codec {
            case .h264:
                let type = header & 0x1f
                isSlice = (1...5).contains(type)
                firstSliceOfPicture = isSlice && r.count > 1 && bytes[r.lowerBound + 1] & 0x80 != 0
            case .h265:
                let type = (header >> 1) & 0x3f
                isSlice = type < 32
                firstSliceOfPicture = isSlice && r.count > 2 && bytes[r.lowerBound + 2] & 0x80 != 0
            case .av1:
                // Not Annex B: an AV1 stream is split by its temporal delimiters instead.
                isSlice = false
                firstSliceOfPicture = false
            }
            if !isSlice {
                if sawSlice, pendingStart == nil { pendingStart = startCodeOffset(r) }
                if auStart == nil { auStart = startCodeOffset(r) }
                continue
            }
            if firstSliceOfPicture, sawSlice {
                let boundary = pendingStart ?? startCodeOffset(r)
                flush(upTo: boundary)
                auStart = boundary
                keyframe = false
            }
            if auStart == nil { auStart = startCodeOffset(r) }
            pendingStart = nil
            sawSlice = true
            if kind == .keyframeSlice { keyframe = true }
        }
        flush(upTo: bytes.count)
        self.init(codec: codec, width: width, height: height, framesPerSecond: framesPerSecond, accessUnits: aus)
    }
}

extension TestStream {
    /// The bundled AV1 test stream (1280×720, 60 frames at 60 fps, the first
    /// a keyframe with the sequence header), one temporal unit per access
    /// unit as gdp-spec.md §9.4 carries them. Nil if the resource is missing.
    public static func av1() -> TestStream? {
        guard let url = Bundle.module.url(forResource: "av1-test-720p", withExtension: "obu"),
              let data = try? Data(contentsOf: url),
              let obus = try? AV1.obus(in: [UInt8](data)) else { return nil }
        let bytes = [UInt8](data)
        var units: [AccessUnit] = []
        var start: Int?
        var keyframe = false
        func flush(upTo end: Int) {
            if let start, end > start { units.append(AccessUnit(bytes: Array(bytes[start..<end]), keyframe: keyframe)) }
        }
        for obu in obus {
            switch obu.type {
            case AV1.OBUType.temporalDelimiter.rawValue:
                flush(upTo: obu.bytes.lowerBound)
                start = obu.bytes.lowerBound
                keyframe = false
            case AV1.OBUType.sequenceHeader.rawValue:
                keyframe = true // what a keyframe's temporal unit carries (§9.4)
            default:
                break
            }
        }
        flush(upTo: bytes.count)
        return TestStream(codec: .av1, width: 1280, height: 720, framesPerSecond: 60, accessUnits: units)
    }
}

public enum TestStreamEncoderError: Error, CustomStringConvertible {
    case session(OSStatus)
    case encode(OSStatus)
    case output(String)

    public var description: String {
        switch self {
        case let .session(s): "VTCompressionSessionCreate failed (\(s))"
        case let .encode(s): "VTCompressionSessionEncodeFrame failed (\(s))"
        case let .output(s): s
        }
    }
}

/// Encodes test pictures the way wraith's encoders are set up for a live
/// desktop: no B-frames, low-latency rate control, one keyframe at the start
/// (the host sends more only to repair loss, gdp-spec.md §9.3).
public enum TestStreamEncoder {
    public static func encode(codec: VideoCodec, width: Int = 1920, height: Int = 1080, framesPerSecond: Int = 60,
                              frameCount: Int = 600, bitrate: Int = 30_000_000,
                              progress: (@Sendable (Double) -> Void)? = nil) throws -> TestStream {
        // VideoToolbox encodes no AV1 on this hardware: AV1 test streams come prepared.
        guard codec != .av1 else { throw TestStreamEncoderError.output("VideoToolbox can't encode AV1") }
        let generator = try TestPatternGenerator(width: width, height: height)
        var session: VTCompressionSession?
        // Low-latency rate control where available; the simulator has no
        // hardware encoder and may not take it, so fall back.
        var status: OSStatus = noErr
        for spec in [[kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as [CFString: Any], [:]] {
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: codec.coreMediaType, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &session)
            if status == noErr { break }
        }
        guard status == noErr, let session else { throw TestStreamEncoderError.session(status) }
        defer { VTCompressionSessionInvalidate(session) }

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: codec == .h264
                ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: framesPerSecond,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: frameCount,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        let outputs = Mutex<[Int: AccessUnit]>([:])
        let failure = Mutex<String?>(nil)
        for i in 0..<frameCount {
            let pb = try generator.makeFrame(UInt32(i))
            let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(framesPerSecond))
            let frameProperties: CFDictionary? = i == 0
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let s = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                frameProperties: frameProperties, infoFlagsOut: nil
            ) { status, _, sample in
                guard status == noErr, let sample else {
                    failure.withLock { $0 = "encoder output \(status)" }
                    return
                }
                do {
                    let au = try accessUnit(from: sample, codec: codec)
                    outputs.withLock { $0[i] = au }
                } catch {
                    failure.withLock { $0 = String(describing: error) }
                }
            }
            guard s == noErr else { throw TestStreamEncoderError.encode(s) }
            if i % 30 == 0 { progress?(Double(i) / Double(frameCount)) }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        if let f = failure.withLock({ $0 }) { throw TestStreamEncoderError.output(f) }
        let aus = outputs.withLock { o in (0..<frameCount).compactMap { o[$0] } }
        guard aus.count == frameCount else {
            throw TestStreamEncoderError.output("encoder produced \(aus.count) of \(frameCount) frames")
        }
        progress?(1)
        return TestStream(codec: codec, width: width, height: height, framesPerSecond: framesPerSecond, accessUnits: aus)
    }

    /// AVCC/HVCC sample (length-prefixed NAL units) -> Annex B, with the
    /// parameter sets in front on a keyframe.
    static func accessUnit(from sample: CMSampleBuffer, codec: VideoCodec) throws -> AccessUnit {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else {
            throw TestStreamEncoderError.output("sample without format or data")
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var out: [UInt8] = []
        var headerLength: Int32 = 4
        if keyframe {
            var count = 0
            switch codec {
            case .h264:
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            case .h265:
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            case .av1:
                break
            }
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                switch codec {
                case .h264:
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil)
                case .h265:
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil)
                case .av1:
                    break
                }
                guard let pointer else { continue }
                out += AnnexB.startCode
                out += UnsafeBufferPointer(start: pointer, count: size)
            }
        }

        let length = CMBlockBufferGetDataLength(block)
        var data = [UInt8](repeating: 0, count: length)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
        var i = 0
        let n = Int(headerLength)
        while i + n <= length {
            var nalLength = 0
            for k in 0..<n { nalLength = nalLength << 8 | Int(data[i + k]) }
            i += n
            guard nalLength > 0, i + nalLength <= length else { throw TestStreamEncoderError.output("bad NAL length") }
            out += AnnexB.startCode
            out += data[i..<(i + nalLength)]
            i += nalLength
        }
        return AccessUnit(bytes: out, keyframe: keyframe)
    }
}
