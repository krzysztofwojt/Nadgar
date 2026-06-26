import AVFoundation
import Foundation
import os
import WristAssistShared

final class WatchAudioPipeline {
    private static let playbackPrerollMilliseconds = 180
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kwojt.WristAssist.watchkitapp",
        category: "WatchAudioPipeline"
    )

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private let playbackQueue = DispatchQueue(label: "com.kwojt.WristAssist.watch.output-playback")
    private var pendingOutputBuffers = 0
    private var playedOutputFrames = 0
    private var playbackGeneration = 0
    private var outputPlaybackStartedAt: Date?
    private var recentInputRMS: Float = 0
    private var recentOutputRMS: Float = 0
    private var lastInputMetricsLogAt = Date.distantPast
    private var outputDrainContinuations: [CheckedContinuation<Void, Never>] = []
    private var onInputAudio: (@Sendable (WatchInputAudioChunk) -> Void)?
    private var onOutputPlaybackDrained: (@Sendable () -> Void)?

    func start(
        onInputAudio: @escaping @Sendable (WatchInputAudioChunk) -> Void,
        onOutputPlaybackDrained: @escaping @Sendable () -> Void = {}
    ) async throws {
        guard await requestRecordPermission() else {
            throw WatchAudioPipelineError.microphoneDenied
        }

        self.onInputAudio = onInputAudio
        self.onOutputPlaybackDrained = onOutputPlaybackDrained

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat)
        try session.setActive(true)
        Self.logger.info("audio session active category=playAndRecord mode=voiceChat")

        configureVoiceProcessing()
        configureOutput()
        try configureInput()

        try engine.start()
        playerNode.play()
        Self.logger.info("audio engine started")
    }

    func startPlayback(honorsSilentMode: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if honorsSilentMode {
            try session.setCategory(.ambient, mode: .default)
        } else {
            try session.setCategory(.playback, mode: .voicePrompt)
        }
        try session.setActive(true)

        configureOutput()
        if !engine.isRunning {
            try engine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        let category = honorsSilentMode ? "ambient" : "playback"
        let mode = honorsSilentMode ? "default" : "voicePrompt"
        Self.logger.info("audio playback engine started category=\(category, privacy: .public) mode=\(mode, privacy: .public) route=\(Self.audioRouteDescription(session.currentRoute), privacy: .public)")
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

        let frameCount = Int(buffer.frameLength)
        let prerollBuffer = Self.silentPrerollBuffer(format: outputFormat)
        let prerollFrameCount = Int(prerollBuffer?.frameLength ?? 0)
        let outputRMS = Self.rootMeanSquare(samples)
        let tracking = playbackQueue.sync {
            let isStartingPlayback = pendingOutputBuffers == 0
            if isStartingPlayback {
                outputPlaybackStartedAt = Date()
                Self.logger.info("output playback started")
            }
            pendingOutputBuffers += isStartingPlayback && prerollBuffer != nil ? 2 : 1
            recentOutputRMS = max(recentOutputRMS * 0.8, outputRMS)
            return (
                generation: playbackGeneration,
                shouldSchedulePreroll: isStartingPlayback && prerollBuffer != nil
            )
        }

        if tracking.shouldSchedulePreroll, let prerollBuffer {
            playerNode.scheduleBuffer(prerollBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.markOutputBufferPlayed(frameCount: prerollFrameCount, generation: tracking.generation)
            }
        }

        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.markOutputBufferPlayed(frameCount: frameCount, generation: tracking.generation)
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func waitForOutputPlaybackToDrain() async {
        await withCheckedContinuation { continuation in
            let shouldResumeNow = playbackQueue.sync {
                guard pendingOutputBuffers > 0 else {
                    return true
                }

                outputDrainContinuations.append(continuation)
                return false
            }

            if shouldResumeNow {
                continuation.resume()
            }
        }
    }

    func resetOutputPlaybackTracking() {
        let continuations = playbackQueue.sync {
            playbackGeneration += 1
            pendingOutputBuffers = 0
            playedOutputFrames = 0
            outputPlaybackStartedAt = nil
            recentOutputRMS = 0
            Self.logger.info("output tracking reset generation=\(self.playbackGeneration, privacy: .public)")
            return drainOutputWaiters()
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    func shouldSuppressSpeechStartForLikelyEcho(minimumPlaybackMilliseconds: Int) -> Bool {
        playbackQueue.sync {
            guard pendingOutputBuffers > 0 || outputPlaybackStartedAt != nil else {
                Self.logger.info("echo decision suppress=false reason=no_output_playback inputRMS=\(self.recentInputRMS, privacy: .public) outputRMS=\(self.recentOutputRMS, privacy: .public)")
                return false
            }

            let playedMilliseconds = Int((Double(playedOutputFrames) / outputFormat.sampleRate) * 1_000)
            if playedMilliseconds < minimumPlaybackMilliseconds {
                Self.logger.info("echo decision suppress=true reason=guard_window playedMs=\(playedMilliseconds, privacy: .public) inputRMS=\(self.recentInputRMS, privacy: .public) outputRMS=\(self.recentOutputRMS, privacy: .public)")
                return true
            }

            let minimumHumanSpeechRMS: Float = 0.035
            let echoRelativeToOutputThreshold: Float = 0.65
            let shouldSuppress = recentOutputRMS > 0.02
                && recentInputRMS < max(minimumHumanSpeechRMS, recentOutputRMS * echoRelativeToOutputThreshold)
            Self.logger.info("echo decision suppress=\(shouldSuppress, privacy: .public) reason=rms playedMs=\(playedMilliseconds, privacy: .public) inputRMS=\(self.recentInputRMS, privacy: .public) outputRMS=\(self.recentOutputRMS, privacy: .public)")
            return shouldSuppress
        }
    }

    func stopOutputPlaybackAndClearQueue() -> Int {
        let audioEndMilliseconds = playedOutputMilliseconds()

        playerNode.stop()
        resetOutputPlaybackTracking()

        if engine.isRunning {
            playerNode.play()
        }

        return audioEndMilliseconds
    }

    func stopPlaybackAndClearQueue() {
        playerNode.stop()
        resetOutputPlaybackTracking()
        if engine.isRunning {
            engine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false)
        Self.logger.info("audio playback stopped")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        let continuations = playbackQueue.sync {
            playbackGeneration += 1
            pendingOutputBuffers = 0
            playedOutputFrames = 0
            outputPlaybackStartedAt = nil
            recentInputRMS = 0
            recentOutputRMS = 0
            lastInputMetricsLogAt = .distantPast
            return drainOutputWaiters()
        }
        for continuation in continuations {
            continuation.resume()
        }
        onInputAudio = nil
        onOutputPlaybackDrained = nil
        Self.logger.info("audio pipeline stopped")
    }

    private func configureVoiceProcessing() {
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.isVoiceProcessingBypassed = false
            engine.inputNode.isVoiceProcessingAGCEnabled = true
            Self.logger.info("voice processing enabled bypassed=\(self.engine.inputNode.isVoiceProcessingBypassed, privacy: .public) agc=\(self.engine.inputNode.isVoiceProcessingAGCEnabled, privacy: .public)")
        } catch {
            Self.logger.error("voice processing failed error=\(SecretRedactor.redact(error.localizedDescription), privacy: .public)")
            return
        }
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
        let inputRMS = Self.rootMeanSquare(samples)
        let metrics = playbackQueue.sync {
            recentInputRMS = (recentInputRMS * 0.65) + (inputRMS * 0.35)
            let now = Date()
            let playedMilliseconds = Int((Double(playedOutputFrames) / outputFormat.sampleRate) * 1_000)
            let isOutputPlaybackActive = pendingOutputBuffers > 0 || outputPlaybackStartedAt != nil
            guard now.timeIntervalSince(lastInputMetricsLogAt) >= 0.5 else {
                return (
                    shouldLog: false,
                    pending: pendingOutputBuffers,
                    playedMs: playedMilliseconds,
                    input: recentInputRMS,
                    output: recentOutputRMS,
                    isOutputPlaybackActive: isOutputPlaybackActive
                )
            }

            lastInputMetricsLogAt = now
            return (
                shouldLog: true,
                pending: pendingOutputBuffers,
                playedMs: playedMilliseconds,
                input: recentInputRMS,
                output: recentOutputRMS,
                isOutputPlaybackActive: isOutputPlaybackActive
            )
        }
        if metrics.shouldLog {
            Self.logger.info("input metrics inputRMS=\(metrics.input, privacy: .public) outputRMS=\(metrics.output, privacy: .public) pendingOutput=\(metrics.pending, privacy: .public) playedMs=\(metrics.playedMs, privacy: .public)")
        }
        let base64Audio = PCM16AudioConverter.base64PCM16(fromFloat32Samples: samples)
        onInputAudio?(
            WatchInputAudioChunk(
                base64PCM16: base64Audio,
                durationMilliseconds: Int((Double(converted.frameLength) / outputFormat.sampleRate) * 1_000),
                inputRMS: metrics.input,
                outputRMS: metrics.output,
                outputPlayedMilliseconds: metrics.playedMs,
                isOutputPlaybackActive: metrics.isOutputPlaybackActive
            )
        )
    }

    private func markOutputBufferPlayed(frameCount: Int, generation: Int) {
        let result = playbackQueue.sync {
            guard generation == playbackGeneration else {
                return (didDrain: false, continuations: [] as [CheckedContinuation<Void, Never>])
            }

            if pendingOutputBuffers > 0 {
                pendingOutputBuffers -= 1
            }

            playedOutputFrames += frameCount
            let didDrain = pendingOutputBuffers == 0
            if didDrain {
                outputPlaybackStartedAt = nil
                recentOutputRMS = 0
                Self.logger.info("output playback drained playedMs=\(Int((Double(self.playedOutputFrames) / self.outputFormat.sampleRate) * 1_000), privacy: .public)")
            }
            return (didDrain: didDrain, continuations: didDrain ? drainOutputWaiters() : [])
        }

        for continuation in result.continuations {
            continuation.resume()
        }

        if result.didDrain {
            onOutputPlaybackDrained?()
        }
    }

    private func drainOutputWaiters() -> [CheckedContinuation<Void, Never>] {
        let continuations = outputDrainContinuations
        outputDrainContinuations.removeAll()
        return continuations
    }

    private func playedOutputMilliseconds() -> Int {
        playbackQueue.sync {
            Int((Double(playedOutputFrames) / outputFormat.sampleRate) * 1_000)
        }
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Double(0)) { partialResult, sample in
            partialResult + Double(sample * sample)
        }
        return Float(sqrt(sumOfSquares / Double(samples.count)))
    }

    private static func silentPrerollBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(
            (format.sampleRate * Double(playbackPrerollMilliseconds) / 1_000).rounded()
        )
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            return nil
        }

        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) {
                channel[index] = 0
            }
        }
        return buffer
    }

    private static func audioRouteDescription(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "inputs=[\(inputs)] outputs=[\(outputs)]"
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(watchOS 10.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
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

struct WatchInputAudioChunk: Sendable {
    var base64PCM16: String
    var durationMilliseconds: Int
    var inputRMS: Float
    var outputRMS: Float
    var outputPlayedMilliseconds: Int
    var isOutputPlaybackActive: Bool
}
