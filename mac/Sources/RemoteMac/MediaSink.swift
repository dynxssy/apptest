import Foundation

/// Stream ids used in binary video messages.
enum StreamID: UInt8 {
    case screen = 0
    case camera = 1
}

/// Something that receives encoded media (a connected phone). Called from capture/encoder threads.
protocol MediaSink: AnyObject {
    func videoConfig(_ stream: StreamID, _ config: H264Encoder.Config)
    func videoFrame(_ stream: StreamID, _ frame: H264Encoder.Frame)
    func audioPacket(_ packet: Data)
}

/// Binary message layouts (see docs/PROTOCOL.md).
enum Wire {
    /// [0x01][stream][flags: bit0 = keyframe][u64 BE timestamp µs][AVCC data]
    static func video(_ stream: StreamID, _ frame: H264Encoder.Frame) -> Data {
        var d = Data(capacity: frame.data.count + 11)
        d.append(0x01)
        d.append(stream.rawValue)
        d.append(frame.isKey ? 1 : 0)
        var ts = frame.timestampMicros.bigEndian
        withUnsafeBytes(of: &ts) { d.append(contentsOf: $0) }
        d.append(frame.data)
        return d
    }

    /// [0x02][channels][u32 BE sample rate][int16 LE interleaved PCM]
    static func audio(channels: Int, sampleRate: Int, samples: [Int16]) -> Data {
        var d = Data(capacity: samples.count * 2 + 6)
        d.append(0x02)
        d.append(UInt8(channels))
        var sr = UInt32(sampleRate).bigEndian
        withUnsafeBytes(of: &sr) { d.append(contentsOf: $0) }
        // Every Mac is little-endian, so the samples go out as they sit in memory.
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    static func config(_ stream: StreamID, _ c: H264Encoder.Config) -> [String: Any] {
        ["t": "vconfig", "s": Int(stream.rawValue), "codec": c.codec, "w": c.width, "h": c.height,
         "desc": c.avcC.base64EncodedString()]
    }
}

/// Weak references so a disconnected phone never keeps a capture running.
struct WeakSink {
    weak var sink: MediaSink?
}
