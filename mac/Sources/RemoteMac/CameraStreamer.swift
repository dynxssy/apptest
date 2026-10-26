import Foundation
import AVFoundation
import CoreMedia

/// Streams a Mac camera (built-in, external, or an iPhone via Continuity Camera) to phones.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "remotemac.camera", qos: .userInteractive)
    private var session: AVCaptureSession?
    private var encoder: H264Encoder?
    private var sinks: [ObjectIdentifier: WeakSink] = [:]
    private var lastConfig: H264Encoder.Config?
    private var deviceID: String?
    var onError: ((String) -> Void)?

    static func devices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    static func list() -> [[String: Any]] {
        devices().map { ["id": $0.uniqueID, "name": $0.localizedName] }
    }

    func subscribe(_ sink: MediaSink, deviceID: String?) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                self.onError?("Camera permission is off for RemoteMac (System Settings > Privacy & Security > Camera).")
                return
            }
            self.queue.async {
                self.sinks[ObjectIdentifier(sink)] = WeakSink(sink: sink)
                if self.session == nil || (deviceID != nil && deviceID != self.deviceID) {
                    self.start(deviceID: deviceID)
                } else {
                    if let cfg = self.lastConfig { sink.videoConfig(.camera, cfg) }
                    self.encoder?.requestKeyframe()
                }
            }
        }
    }

    func unsubscribe(_ sink: MediaSink) {
        queue.async {
            self.sinks.removeValue(forKey: ObjectIdentifier(sink))
            if self.liveSinks().isEmpty { self.stop() }
        }
    }

    func requestKeyframe() { queue.async { self.encoder?.requestKeyframe() } }

    private func liveSinks() -> [MediaSink] {
        sinks = sinks.filter { $0.value.sink != nil }
        return sinks.values.compactMap { $0.sink }
    }

    private func start(deviceID: String?) {
        stop()
        let all = Self.devices()
        guard let device = all.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .video) ?? all.first,
              let input = try? AVCaptureDeviceInput(device: device) else {
            onError?("No camera found on this Mac.")
            return
        }
        let s = AVCaptureSession()
        s.beginConfiguration()
        if s.canSetSessionPreset(.hd1280x720) { s.sessionPreset = .hd1280x720 }
        guard s.canAddInput(input) else { onError?("Camera is busy."); return }
        s.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(output) else { onError?("Camera output unavailable."); return }
        s.addOutput(output)
        s.commitConfiguration()
        s.startRunning()
        session = s
        self.deviceID = device.uniqueID
        Log.info("camera started: \(device.localizedName)")
    }

    private func stop() {
        session?.stopRunning()
        session = nil
        encoder?.invalidate()
        encoder = nil
        lastConfig = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if encoder == nil || encoder?.width != w || encoder?.height != h {
            let enc = H264Encoder(width: w, height: h, fps: 30, bitrate: 2_500_000)
            enc?.onConfig = { [weak self] c in
                guard let self else { return }
                self.queue.async {
                    self.lastConfig = c
                    for s in self.liveSinks() { s.videoConfig(.camera, c) }
                }
            }
            enc?.onFrame = { [weak self] f in
                guard let self else { return }
                self.queue.async { for s in self.liveSinks() { s.videoFrame(.camera, f) } }
            }
            encoder?.invalidate()
            encoder = enc
        }
        encoder?.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sample))
    }
}
