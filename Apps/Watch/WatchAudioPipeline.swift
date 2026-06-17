import AVFoundation
import Foundation
import WristAssistShared

final class WatchAudioPipeline {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var onInputAudio: (@Sendable (String) -> Void)?

    func start(onInputAudio: @escaping @Sendable (String) -> Void) async throws {
        guard await requestRecordPermission() else {
            throw WatchAudioPipelineError.microphoneDenied
        }

        self.onInputAudio = onInputAudio

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat)
        try session.setActive(true)

        configureOutput()
        try configureInput()

        try engine.start()
        playerNode.play()
    }

    func enqueueOutputAudio(_ pcm16Data: Data) {
        let samples = PCM16AudioConverter.float32Samples(fromPCM16Data: pcm16Data)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              )
        else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    channel.update(from: baseAddress, count: samples.count)
                }
            }
        }

        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        onInputAudio = nil
    }

    private func configureOutput() {
        if !engine.attachedNodes.contains(playerNode) {
            engine.attach(playerNode)
        }

        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
    }

    private func configureInput() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw WatchAudioPipelineError.converterUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
            self?.processInput(buffer, converter: converter, inputFormat: inputFormat)
        }
    }

    private func processInput(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat
    ) {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return
        }

        var error: NSError?
        var didProvideBuffer = false
        converter.convert(to: converted, error: &error) { _, status in
            if didProvideBuffer {
                status.pointee = .noDataNow
                return nil
            }

            didProvideBuffer = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil,
              let channel = converted.floatChannelData?[0],
              converted.frameLength > 0
        else {
            return
        }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        let base64Audio = PCM16AudioConverter.base64PCM16(fromFloat32Samples: samples)
        onInputAudio?(base64Audio)
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

enum WatchAudioPipelineError: LocalizedError, Equatable {
    case microphoneDenied
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone permission is required."
        case .converterUnavailable:
            return "Audio converter could not be created."
        }
    }
}
