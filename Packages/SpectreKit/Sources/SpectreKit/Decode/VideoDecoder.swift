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
        if codec == .av1 {
            try decodeAV1(accessUnit, pts: pts, frameID: frameID, submitTime: submitTime)
            return
        }
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
        guard formatDescription != nil else { throw .waitingForKeyframe }
        guard pictureBytes > 0 else { return }

        // One contiguous, length-prefixed (4-byte big-endian) sample.
        try submit(length: pictureBytes, pts: pts, frameID: frameID, submitTime: submitTime) { block throws(VideoDecoderError) in
            var offset = 0
            for r in pictureUnits {
                var length = UInt32(r.count).bigEndian
                var status = withUnsafeBytes(of: &length) {
                    CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: offset,
                                                  dataLength: 4)
                }
                guard status == noErr else { throw .blockBuffer(status) }
                status = CMBlockBufferReplaceDataBytes(with: accessUnit.baseAddress! + r.lowerBound, blockBuffer: block,
                                                       offsetIntoDestination: offset + 4, dataLength: r.count)
                guard status == noErr else { throw .blockBuffer(status) }
                offset += 4 + r.count
            }
        }
    }

    /// One temporal unit (gdp-spec.md §9.4): its OBUs, less the temporal
    /// delimiter (which an ISOBMFF sample, what VideoToolbox decodes, leaves
    /// out), as one sample. A sequence header that differs from the last
    /// (re)configures the decoder.
    private func decodeAV1(_ unit: UnsafeRawBufferPointer, pts: UInt32, frameID: UInt32,
                           submitTime: CFTimeInterval) throws(VideoDecoderError) {
        let obus: [AV1.OBU]
        do {
            obus = try AV1.obus(in: unit)
        } catch {
            throw .malformedAccessUnit
        }
        if let header = obus.first(where: { $0.type == AV1.OBUType.sequenceHeader.rawValue }) {
            let bytes = Array(unit[header.bytes])
            if [bytes] != parameterSets { try configureAV1(sequenceHeaderOBU: bytes, payload: Array(unit[header.payload])) }
        }
        guard formatDescription != nil else { throw .waitingForKeyframe }
        let kept = obus.filter { $0.type != AV1.OBUType.temporalDelimiter.rawValue }
        let length = kept.reduce(0) { $0 + $1.bytes.count }
        guard length > 0 else { return }
        try submit(length: length, pts: pts, frameID: frameID, submitTime: submitTime) { block throws(VideoDecoderError) in
            var offset = 0
            for obu in kept {
                let status = CMBlockBufferReplaceDataBytes(with: unit.baseAddress! + obu.bytes.lowerBound, blockBuffer: block,
                                                           offsetIntoDestination: offset, dataLength: obu.bytes.count)
                guard status == noErr else { throw .blockBuffer(status) }
                offset += obu.bytes.count
            }
        }
    }

    /// Decodes one sample of `length` bytes that `fill` writes into its block buffer.
    private func submit(length: Int, pts: UInt32, frameID: UInt32, submitTime: CFTimeInterval,
                        fill: (CMBlockBuffer) throws(VideoDecoderError) -> Void) throws(VideoDecoderError) {
        guard let session, let formatDescription else { throw .waitingForKeyframe }
        let pictureBytes = length
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pictureBytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: pictureBytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw .blockBuffer(status) }
        try fill(block)

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

    /// Drops the decompression session; the next keyframe (its parameter
    /// sets) makes a new one. For a decoder the system may have invalidated
    /// meanwhile, as iOS does to hardware decoders of an app in the background.
    public func reset() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        parameterSets = []
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
            case .av1:
                kCMFormatDescriptionError_InvalidParameter // configureAV1's
            }
        }
        guard status == noErr, let description else { throw .formatDescription(status) }
        parameterSets = sets
        try install(description)
    }

    /// The decoder for an AV1 sequence header: its codec configuration
    /// record ("av1C") rides in the format description's sample description
    /// atoms, as an ISOBMFF track's does.
    private func configureAV1(sequenceHeaderOBU: [UInt8], payload: [UInt8]) throws(VideoDecoderError) {
        let header: AV1.SequenceHeader
        do {
            header = try AV1.SequenceHeader(payload: payload)
        } catch {
            throw .malformedAccessUnit
        }
        let atoms: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:
                ["av1C": Data(header.codecConfiguration(sequenceHeaderOBU: sequenceHeaderOBU))] as CFDictionary,
        ]
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_AV1, width: Int32(header.maxFrameWidth),
            height: Int32(header.maxFrameHeight), extensions: atoms as CFDictionary, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw .formatDescription(status) }
        parameterSets = [sequenceHeaderOBU]
        try install(description)
    }

    /// Decodes with `description` from now on: in the current session if it
    /// takes it, else in a new one.
    private func install(_ description: CMVideoFormatDescription) throws(VideoDecoderError) {
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
