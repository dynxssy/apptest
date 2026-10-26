import Foundation
import VideoToolbox
import CoreMedia

/// Hardware H.264 encoder tuned for latency: no B-frames, low-latency rate control,
/// keyframes on demand. Output is AVCC (length-prefixed) which WebCodecs decodes directly
/// when given the avcC record as `description`.
final class H264Encoder {
    struct Config {
        let codec: String // e.g. "avc1.640028"
        let avcC: Data
        let width: Int
        let height: Int
    }

    struct Frame {
        let data: Data
        let isKey: Bool
        let timestampMicros: UInt64
    }

    var onConfig: ((Config) -> Void)?
    var onFrame: ((Frame) -> Void)?

    let width: Int
    let height: Int
    private var session: VTCompressionSession?
    private var forceKeyframe = true
    private var lastDescription: CMFormatDescription?
    private let lock = NSLock()

    init?(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = width
        self.height = height
        var s: VTCompressionSession?
        let lowLatency: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: lowLatency as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        if status != noErr {
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard status == noErr, let session = s else {
            Log.info("VTCompressionSessionCreate failed: \(status)")
            return nil
        }
        self.session = session
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // Baseline has no frame reordering, so Safari's decoder outputs each frame right away instead
        // of holding several back.
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 5 as CFNumber)
        setBitrate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    private func set(_ key: CFString, _ value: CFTypeRef) {
        guard let session else { return }
        let st = VTSessionSetProperty(session, key: key, value: value)
        if st != noErr { Log.info("encoder property \(key) not applied (\(st))") }
    }

    func setBitrate(_ bitsPerSecond: Int) {
        set(kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond as CFNumber)
        // Cap bursts at 1.5x average over one second so a scene change doesn't flood a phone link.
        let bytesPerSecond = Double(bitsPerSecond) / 8 * 1.5
        set(kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond, 1.0] as CFArray)
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        lock.lock()
        let key = forceKeyframe
        forceKeyframe = false
        lock.unlock()
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, flags, sample in
            guard let self, status == noErr, !flags.contains(.frameDropped), let sample else { return }
            self.handle(sample)
        }
    }

    private func handle(_ sample: CMSampleBuffer) {
        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        if isKey, let desc = CMSampleBufferGetFormatDescription(sample) {
            let changed = lastDescription.map { !CMFormatDescriptionEqual($0, otherFormatDescription: desc) } ?? true
            if changed, let cfg = Self.config(from: desc) {
                lastDescription = desc
                onConfig?(cfg)
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
        onFrame?(Frame(data: data, isKey: isKey, timestampMicros: micros))
    }

    private static func config(from desc: CMFormatDescription) -> Config? {
        guard let atoms = CMFormatDescriptionGetExtension(
            desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let avcC = atoms["avcC"] as? Data, avcC.count > 4 else { return nil }
        let b = [UInt8](avcC)
        let codec = String(format: "avc1.%02X%02X%02X", b[1], b[2], b[3])
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        return Config(codec: codec, avcC: avcC, width: Int(dims.width), height: Int(dims.height))
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }
}
