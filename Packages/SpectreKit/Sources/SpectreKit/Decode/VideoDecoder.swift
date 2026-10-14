import CoreMedia
import CoreVideo
import QuartzCore
import VideoToolbox

/// One decoded picture, still where VideoToolbox put it: an IOSurface-backed
/// NV12 `CVPixelBuffer` the presenter samples directly (no copy).
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// The frame's pts on the host's session clock (gdp-spec.md §11).
    public let pts: UInt32
    /// The GDP frame_id it was decoded from (gdp-spec.md §9.1).
    public let frameID: UInt32
    public let sequence: UInt64
    /// `CACurrentMediaTime()` when the access unit went into the decoder and when the picture came out.
    public let submitTime: CFTimeInterval
    public let decodedTime: CFTimeInterval

    public var decodeDuration: CFTimeInterval { decodedTime - submitTime }
}

public enum VideoDecoderError: Error, CustomStringConvertible {
    /// A picture arrived before any parameter sets (no keyframe yet): skip until one comes.
    case waitingForKeyframe
    case malformedAccessUnit
    case formatDescription(OSStatus)
    case session(OSStatus)
    case blockBuffer(OSStatus)
    case decode(OSStatus)

    public var description: String {
        switch self {
        case .waitingForKeyframe: "waiting for a keyframe"
        case .malformedAccessUnit: "malformed access unit"
        case let .formatDescription(s): "CMVideoFormatDescriptionCreate failed (\(s))"
        case let .session(s): "VTDecompressionSessionCreate failed (\(s))"
        case let .blockBuffer(s): "CMBlockBuffer failed (\(s))"
        case let .decode(s): "VTDecompressionSessionDecodeFrame failed (\(s))"
        }
    }
}

/// Decodes one stream's Annex B access units (gdp-spec.md §9.4) with
/// VideoToolbox. Keyframes carry their parameter sets in-band; the session
/// is (re)created whenever they change. Output pictures are NV12 in video
/// range (`420v`), IOSurface-backed and Metal-compatible, so the presenter
/// can wrap their planes as textures without copying.
///
/// Not thread-safe: feed it from one queue (the session's receive queue).
/// `onFrame` runs on VideoToolbox's thread.
public final class VideoDecoder {
    public let codec: VideoCodec
    /// Whether VideoToolbox picked a hardware decoder for the current session.
    public private(set) var isHardwareAccelerated = false

    private let onFrame: @Sendable (DecodedFrame) -> Void
    private let onError: @Sendable (_ status: OSStatus, _ frameID: UInt32) -> Void
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [[UInt8]] = []
    private var sequence: UInt64 = 0

    public init(codec: VideoCodec, onFrame: @escaping @Sendable (DecodedFrame) -> Void,
                onError: @escaping @Sendable (_ status: OSStatus, _ frameID: UInt32) -> Void = { _, _ in }) {
        self.codec = codec
        self.onFrame = onFrame
        self.onError = onError
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Decodes one access unit. The bytes are copied into a CMBlockBuffer
    /// (compressed data only, length-prefixed instead of start codes), so
    /// they need only live for the call.
    public func decode(_ accessUnit: UnsafeRawBufferPointer, pts: UInt32, frameID: UInt32 = 0) throws(VideoDecoderError) {
        let submitTime = CACurrentMediaTime()
        let units = AnnexB.nalUnits(in: accessUnit)
        guard !units.isEmpty else { throw .malformedAccessUnit }

        var newParameterSets = [[UInt8]](repeating: [], count: codec.parameterSetCount)
        var pictureUnits: [Range<Int>] = []
        var pictureBytes = 0
        for r in units {
            switch codec.kind(ofNALHeader: accessUnit[r.lowerBound]) {
            case let .parameterSet(index):
                newParameterSets[index] = Array(accessUnit[r])
            case .accessUnitDelimiter:
                break
            case .keyframeSlice, .other:
                pictureUnits.append(r)
                pictureBytes += 4 + r.count
            }
        }
        if newParameterSets.allSatisfy({ !$0.isEmpty }), newParameterSets != parameterSets {
            try configure(parameterSets: newParameterSets)
        }
        guard let session, let formatDescription else { throw .waitingForKeyframe }
        guard pictureBytes > 0 else { return }

        // One contiguous, length-prefixed (4-byte big-endian) sample.
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pictureBytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: pictureBytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw .blockBuffer(status) }
        var offset = 0
        for r in pictureUnits {
            var length = UInt32(r.count).bigEndian
            status = withUnsafeBytes(of: &length) {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: offset,
                                              dataLength: 4)
            }
            guard status == noErr else { throw .blockBuffer(status) }
            status = CMBlockBufferReplaceDataBytes(with: accessUnit.baseAddress! + r.lowerBound, blockBuffer: block,
                                                   offsetIntoDestination: offset + 4, dataLength: r.count)
            guard status == noErr else { throw .blockBuffer(status) }
            offset += 4 + r.count
        }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = pictureBytes
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                           formatDescription: formatDescription, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                           sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw .blockBuffer(status) }

        sequence += 1
        let seq = sequence
        let onFrame = onFrame
        let onError = onError
        // Synchronous decode (no kVTDecodeFrame_EnableAsynchronousDecompression):
        // a remote desktop wants each picture out as soon as possible, not a pipeline.
        status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._1xRealTimePlayback], infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                onError(status, frameID)
                return
            }
            onFrame(DecodedFrame(pixelBuffer: imageBuffer, pts: pts, frameID: frameID, sequence: seq,
                                 submitTime: submitTime, decodedTime: CACurrentMediaTime()))
        }
        guard status == noErr else { throw .decode(status) }
    }

    /// Waits until every frame submitted so far has come out.
    public func flush() {
        guard let session else { return }
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    private func configure(parameterSets sets: [[UInt8]]) throws(VideoDecoderError) {
        var description: CMVideoFormatDescription?
        let status: OSStatus = withPointers(to: sets) { pointers, sizes in
            switch codec {
            case .h264:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            case .h265:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                    formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { throw .formatDescription(status) }
        parameterSets = sets

        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            formatDescription = description
            return
        }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        formatDescription = description
        session = try makeSession(description)
    }

    private func makeSession(_ description: CMVideoFormatDescription) throws(VideoDecoderError) -> VTDecompressionSession {
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        // Prefer requiring the hardware decoder; fall back to letting VideoToolbox
        // choose (the iOS simulator, an unusual stream).
        let specifications: [[CFString: Any]] = [
            [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true],
            [:],
        ]
        var lastStatus: OSStatus = noErr
        for spec in specifications {
            var session: VTDecompressionSession?
            lastStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: description,
                decoderSpecification: spec as CFDictionary, imageBufferAttributes: imageAttributes as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &session)
            guard lastStatus == noErr, let session else { continue }
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            let hardware = UnsafeMutablePointer<CFBoolean?>.allocate(capacity: 1)
            hardware.initialize(to: nil)
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: kCFAllocatorDefault, valueOut: hardware)
            isHardwareAccelerated = hardware.pointee.map(CFBooleanGetValue) ?? false
            hardware.deinitialize(count: 1)
            hardware.deallocate()
            return session
        }
        throw .session(lastStatus)
    }
}

/// Calls `body` with C arrays of base pointers and sizes for `buffers`.
private func withPointers<R>(to buffers: [[UInt8]],
                             _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
    let sizes = buffers.map(\.count)
    // Copy into one stable allocation so every pointer stays valid for the call.
    let total = sizes.reduce(0, +)
    let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: max(total, 1))
    defer { storage.deallocate() }
    var pointers: [UnsafePointer<UInt8>] = []
    var offset = 0
    for b in buffers {
        b.withUnsafeBufferPointer { src in
            (storage + offset).initialize(from: src.baseAddress!, count: src.count)
        }
        pointers.append(UnsafePointer(storage + offset))
        offset += b.count
    }
    return pointers.withUnsafeBufferPointer { p in
        sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
    }
}
