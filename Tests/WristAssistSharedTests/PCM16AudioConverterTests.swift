import Testing
@testable import WristAssistShared

struct PCM16AudioConverterTests {
    @Test func float32ToPCM16UsesLittleEndianClippedSamples() {
        let data = PCM16AudioConverter.pcm16Data(fromFloat32Samples: [-2.0, 0.0, 2.0])

        let values = data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) })
        }

        #expect(values == [-32_768, 0, 32_767])
    }

    @Test func pcm16RoundTripToFloat32Samples() {
        let source: [Float] = [-0.5, 0.0, 0.5]
        let data = PCM16AudioConverter.pcm16Data(fromFloat32Samples: source)
        let decoded = PCM16AudioConverter.float32Samples(fromPCM16Data: data)

        #expect(decoded.count == source.count)
        #expect(abs(decoded[0] - -0.5) < 0.001)
        #expect(abs(decoded[1] - 0.0) < 0.001)
        #expect(abs(decoded[2] - 0.5) < 0.001)
    }
}
