import Foundation
import Testing
@testable import WristAssistShared

struct WAVAudioFileBuilderTests {
    @Test func wavDataBuildsPCM16MonoHeaderAndPayload() throws {
        let pcm = Data([0x01, 0x00, 0xff, 0x7f])
        let wav = WAVAudioFileBuilder.wavData(pcm16Data: pcm, sampleRate: 24_000, channels: 1)

        #expect(wav.count == 48)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(readUInt32LE(wav, offset: 4) == 40)
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
        #expect(readUInt16LE(wav, offset: 20) == 1)
        #expect(readUInt16LE(wav, offset: 22) == 1)
        #expect(readUInt32LE(wav, offset: 24) == 24_000)
        #expect(readUInt32LE(wav, offset: 28) == 48_000)
        #expect(readUInt16LE(wav, offset: 32) == 2)
        #expect(readUInt16LE(wav, offset: 34) == 16)
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(readUInt32LE(wav, offset: 40) == 4)
        #expect(wav[44..<48] == pcm[0..<4])
    }

    private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
