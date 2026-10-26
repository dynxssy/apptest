import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

/// Captures one display plus system audio with ScreenCaptureKit and fans the encoded
/// stream out to every phone that's watching. Runs only while someone is watching.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Quality: Equatable {
        let name: String
        let maxWidth: Int
        let fps: Int
        let bitrate: Int
        let audioRate: Int

        static let low = Quality(name: "low", maxWidth: 1280, fps: 30, bitrate: 1_500_000, audioRate: 24_000)
        static let medium = Quality(name: "medium", maxWidth: 1920, fps: 30, bitrate: 4_000_000, audioRate: 48_000)
        static let high = Quality(name: "high", maxWidth: 2560, fps: 60, bitrate: 10_000_000, audioRate: 48_000)

        static func named(_ s: String?) -> Quality {
            switch s {
            case "low": return .low
            case "high": return .high
            default: return .medium
            }
        }
    }

    private let queue = DispatchQueue(label: "remotemac.screen", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "remotemac.screen.audio", qos: .userInteractive)
    private var stream: SCStream?
    private var encoder: H264Encoder?
    private var sinks: [ObjectIdentifier: WeakSink] = [:]
    private var audioSinks: Set<ObjectIdentifier> = []
    private var lastConfig: H264Encoder.Config?
    private var lastPixelBuffer: CVPixelBuffer?
    private var quality = Quality.medium
    private var displayIndex = 0
    private var starting = false
    private(set) var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

    /// Called on the main queue when streaming starts or stops (keep-awake uses it).
    var onActiveChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - Subscribers

    func subscribe(_ sink: MediaSink, display: Int, quality q: Quality, audio: Bool) {
        queue.async {
            let id = ObjectIdentifier(sink)
            let wasEmpty = self.liveSinks().isEmpty
            self.sinks[id] = WeakSink(sink: sink)
            if audio { self.audioSinks.insert(id) } else { self.audioSinks.remove(id) }
            let needsRestart = self.stream == nil || q != self.quality || display != self.displayIndex
            self.quality = q
            self.displayIndex = display
            if needsRestart {
                self.restart()
            } else if let cfg = self.lastConfig {
                sink.videoConfig(.screen, cfg)
                self.refreshKeyframe()
            }
            if wasEmpty { DispatchQueue.main.async { self.onActiveChanged?(true) } }
        }
    }

    func setAudio(_ sink: MediaSink, enabled: Bool) {
        queue.async {
            let id = ObjectIdentifier(sink)
            if enabled { self.audioSinks.insert(id) } else { self.audioSinks.remove(id) }
        }
    }

    func unsubscribe(_ sink: MediaSink) {
        queue.async {
            let id = ObjectIdentifier(sink)
            self.sinks.removeValue(forKey: id)
            self.audioSinks.remove(id)
            if self.liveSinks().isEmpty { self.stop() }
        }
    }

    func requestKeyframe() {
        queue.async { self.refreshKeyframe() }
    }

    /// Bounds of the display being streamed, in global CoreGraphics coordinates (points, top-left origin).
    var displayBounds: CGRect { CGDisplayBounds(activeDisplayID) }

    private func liveSinks() -> [MediaSink] {
        sinks = sinks.filter { $0.value.sink != nil }
        return sinks.values.compactMap { $0.sink }
    }

    // MARK: - Capture

    private func restart() {
        guard !starting else { return }
        starting = true
        let oldStream = stream
        stream = nil
        encoder = nil
        lastConfig = nil
        lastPixelBuffer = nil
        let q = quality
        let index = displayIndex
        Task {
            if let oldStream { try? await oldStream.stopCapture() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let displays = content.displays.sorted { a, b in
                    // Main display first so index 0 is always the primary screen.
                    if a.displayID == CGMainDisplayID() { return true }
                    if b.displayID == CGMainDisplayID() { return false }
                    return a.frame.minX < b.frame.minX
                }
                guard !displays.isEmpty else { throw NSError(domain: "RemoteMac", code: 1) }
                let display = displays[min(max(index, 0), displays.count - 1)]
                let mode = CGDisplayCopyDisplayMode(display.displayID)
                let nativeW = mode?.pixelWidth ?? display.width * 2
                let nativeH = mode?.pixelHeight ?? display.height * 2
                let scale = min(1.0, Double(q.maxWidth) / Double(nativeW))
                let w = Int(Double(nativeW) * scale) & ~1
                let h = Int(Double(nativeH) * scale) & ~1

                let cfg = SCStreamConfiguration()
                cfg.width = w
                cfg.height = h
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(q.fps))
                cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                cfg.colorSpaceName = CGColorSpace.sRGB
                cfg.queueDepth = 6
                // The phone draws its own pointer with no delay; a second, lagging one in the video confuses.
                cfg.showsCursor = false
                cfg.capturesAudio = true
                cfg.sampleRate = 48_000
                cfg.channelCount = 2
                cfg.excludesCurrentProcessAudio = true

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                try await s.startCapture()

                self.queue.async {
                    self.starting = false
                    self.activeDisplayID = display.displayID
                    guard !self.liveSinks().isEmpty else {
                        Task { try? await s.stopCapture() }
                        return
                    }
                    let enc = H264Encoder(width: w, height: h, fps: q.fps, bitrate: q.bitrate)
                    enc?.onConfig = { [weak self] c in
                        guard let self else { return }
                        self.queue.async {
                            self.lastConfig = c
                            for sink in self.liveSinks() { sink.videoConfig(.screen, c) }
                        }
                    }
                    enc?.onFrame = { [weak self] f in
                        guard let self else { return }
                        self.queue.async {
                            for sink in self.liveSinks() { sink.videoFrame(.screen, f) }
                        }
                    }
                    self.encoder = enc
                    self.stream = s
                    // Settings changed while starting: apply them now.
                    if self.quality != q || self.displayIndex != index { self.restart() }
                    Log.info("screen capture started: \(w)x\(h) @\(q.fps)fps \(q.bitrate / 1000)kbps")
                }
            } catch {
                self.queue.async {
                    self.starting = false
                    let msg = CGPreflightScreenCaptureAccess()
                        ? "Screen capture failed: \(error.localizedDescription)"
                        : "Screen Recording permission is off for RemoteMac (System Settings > Privacy & Security)."
                    Log.info(msg)
                    DispatchQueue.main.async { self.onError?(msg) }
                }
            }
        }
    }

    private func stop() {
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        encoder?.invalidate()
        encoder = nil
        lastConfig = nil
        lastPixelBuffer = nil
        DispatchQueue.main.async { self.onActiveChanged?(false) }
        Log.info("screen capture stopped")
    }

    /// The screen only produces frames when something changes, so a new viewer would see
    /// nothing on a still screen. Re-encode the last frame as a keyframe instead.
    private func refreshKeyframe() {
        guard let encoder else { return }
        encoder.requestKeyframe()
        if let pb = lastPixelBuffer {
            encoder.encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen: handleVideo(sample)
        case .audio: handleAudio(sample)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("screen stream stopped: \(error.localizedDescription)")
        queue.async {
            guard self.stream === stream else { return }
            self.stream = nil
            // Usually the display went to sleep or changed resolution; try again shortly.
            self.queue.asyncAfter(deadline: .now() + 2) {
                if !self.liveSinks().isEmpty && self.stream == nil { self.restart() }
            }
        }
    }

    private func handleVideo(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus), status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sample),
              let encoder else { return }
        lastPixelBuffer = pb
        encoder.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    // MARK: - Audio

    private func handleAudio(_ sample: CMSampleBuffer) {
        let targets: [MediaSink] = queue.sync {
            liveSinks().filter { audioSinks.contains(ObjectIdentifier($0)) }
        }
        guard !targets.isEmpty,
              let fmt = CMSampleBufferGetFormatDescription(sample),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        let channels = Int(asbd.mChannelsPerFrame)
        guard frames > 0, channels > 0 else { return }

        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        func sampleAt(_ frame: Int, _ ch: Int) -> Float {
            if nonInterleaved {
                let b = buffers[min(ch, buffers.count - 1)]
                return b.mData!.assumingMemoryBound(to: Float.self)[frame]
            }
            return buffers[0].mData!.assumingMemoryBound(to: Float.self)[frame * channels + min(ch, channels - 1)]
        }

        let outChannels = min(channels, 2)
        let sourceRate = Int(asbd.mSampleRate)
        let targetRate = queue.sync { quality.audioRate }
        let step = max(1, sourceRate / targetRate) // 48k -> 24k averages pairs
        let outFrames = frames / step
        var out = [Int16](repeating: 0, count: outFrames * outChannels)
        for f in 0..<outFrames {
            for c in 0..<outChannels {
                var acc: Float = 0
                for k in 0..<step { acc += sampleAt(f * step + k, c) }
                let v = max(-1, min(1, acc / Float(step)))
                out[f * outChannels + c] = Int16(v * 32767)
            }
        }
        let packet = Wire.audio(channels: outChannels, sampleRate: sourceRate / step, samples: out)
        for t in targets { t.audioPacket(packet) }
    }
}
