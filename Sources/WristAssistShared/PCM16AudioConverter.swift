import Foundation

public enum PCM16AudioConverter {
    public static func pcm16Data(fromFloat32Samples samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)

        for sample in samples {
            let clipped = max(-1.0, min(1.0, sample))
            let scaled = clipped < 0 ? clipped * 32_768 : clipped * 32_767
            var littleEndian = Int16(scaled).littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        return data
    }

    public static func base64PCM16(fromFloat32Samples samples: [Float]) -> String {
        pcm16Data(fromFloat32Samples: samples).base64EncodedString()
    }

    public static func float32Samples(fromPCM16Data data: Data) -> [Float] {
        data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            return int16Buffer.map { sample in
                Float(Int16(littleEndian: sample)) / 32_768.0
            }
        }
    }
}
