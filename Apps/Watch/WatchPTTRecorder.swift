import AVFoundation
import Foundation
import os
import WristAssistShared

struct WatchRecordedAudioFile: Sendable {
    var url: URL
    var durationMilliseconds: Int
}

@MainActor
final class WatchPTTRecorder {
    private static let temporaryFilePrefix = "wristassist-ptt-"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kwojt.WristAssist.watchkitapp",
        category: "WatchPTTRecorder"
    )

    private var activeRecorder: AVAudioRecorder?
    private var activeRecordingURL: URL?
    private var activeStartID: UUID?
    private var hasRecordPermission = false
    private var isAudioSessionActive = false
    private var isRecording = false

    func prewarm() async throws {
        try await prewarm(startID: nil)
    }

    private func prewarm(startID: UUID?) async throws {
        guard !isRecording else { return }
        guard activeRecorder == nil else { return }

        guard await requestRecordPermission() else {
            throw WatchPTTRecorderError.microphoneDenied
        }

        guard !isRecording else { return }
        guard activeRecorder == nil else { return }
        try ensureStartIsCurrent(startID)

        do {
            try activateAudioSessionIfNeeded()
            try prepareRecorder()
            Self.logger.info("ptt recorder prewarmed sampleRate=\(StandalonePTTDefaults.audioSampleRate, privacy: .public)")
        } catch {
            resetRecorderState(deactivateSession: true)
            throw error
        }
    }

    func start() async throws {
        guard !isRecording else { return }

        let startID = UUID()
        activeStartID = startID
        defer {
            clearStartIfCurrent(startID)
        }

        try await prewarm(startID: startID)
        try ensureStartIsCurrent(startID)

        guard let recorder = activeRecorder else {
            throw WatchPTTRecorderError.recordingStartFailed
        }

        if !recorder.record() {
            deleteTemporaryFile(at: activeRecordingURL)
            resetRecorderState(deactivateSession: false)
            try activateAudioSessionIfNeeded()
            try prepareRecorder()
            guard let restartedRecorder = activeRecorder, restartedRecorder.record() else {
                deleteTemporaryFile(at: activeRecordingURL)
                resetRecorderState(deactivateSession: true)
                throw WatchPTTRecorderError.recordingStartFailed
            }
            activeRecorder = restartedRecorder
        }

        isRecording = true
        Self.logger.info("ptt recorder started sampleRate=\(StandalonePTTDefaults.audioSampleRate, privacy: .public)")
    }

    func finish() throws -> WatchRecordedAudioFile {
        guard isRecording else {
            throw WatchPTTRecorderError.notRecording
        }

        guard let recorder = activeRecorder,
              let url = activeRecordingURL
        else {
            resetRecorderState(deactivateSession: true)
            throw WatchPTTRecorderError.noAudioCaptured
        }

        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)
        recorder.stop()
        resetRecorderState(deactivateSession: false)

        let audioFile = try AVAudioFile(forReading: url)
        let durationMilliseconds = Int((Double(audioFile.length) / audioFile.fileFormat.sampleRate) * 1_000)
        let fileByteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0

        guard audioFile.length > 0, fileByteCount > 44 else {
            throw WatchPTTRecorderError.noAudioCaptured
        }

        Self.logger.info(
            "ptt recorder wrote url=\(url.lastPathComponent, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public) fileBytes=\(fileByteCount, privacy: .public) averagePower=\(averagePower, privacy: .public) peakPower=\(peakPower, privacy: .public)"
        )

        return WatchRecordedAudioFile(url: url, durationMilliseconds: durationMilliseconds)
    }

    func cancel() {
        let url = activeRecordingURL
        activeStartID = nil
        if activeRecorder?.isRecording == true {
            activeRecorder?.stop()
        }
        resetRecorderState(deactivateSession: true)
        deleteTemporaryFile(at: url)
    }

    func deleteTemporaryFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func cleanupTemporaryFiles() {
        let directory = FileManager.default.temporaryDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in urls where url.lastPathComponent.hasPrefix(Self.temporaryFilePrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func activateAudioSessionIfNeeded() throws {
        guard !isAudioSessionActive else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat)
        try session.setActive(true)
        isAudioSessionActive = true
        Self.logger.info("ptt audio session active category=playAndRecord mode=voiceChat")
    }

    private func prepareRecorder() throws {
        let url = Self.temporaryFileURL()
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            activeRecorder = recorder
            activeRecordingURL = url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func resetRecorderState(deactivateSession: Bool) {
        activeRecorder = nil
        activeRecordingURL = nil
        isRecording = false

        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false)
            isAudioSessionActive = false
            Self.logger.info("ptt recorder stopped")
        }
    }

    private func ensureStartIsCurrent(_ startID: UUID?) throws {
        guard let startID else { return }
        guard activeStartID == startID else {
            throw WatchPTTRecorderError.recordingStartCancelled
        }
    }

    private func clearStartIfCurrent(_ startID: UUID) {
        if activeStartID == startID {
            activeStartID = nil
        }
    }

    private func requestRecordPermission() async -> Bool {
        guard !hasRecordPermission else { return true }

        let granted = await withCheckedContinuation { continuation in
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
        hasRecordPermission = granted
        return granted
    }

    private static func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryFilePrefix)\(UUID().uuidString)")
            .appendingPathExtension("wav")
    }

    private static var recordingSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Double(StandalonePTTDefaults.audioSampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
    }
}

enum WatchPTTRecorderError: LocalizedError, Equatable {
    case microphoneDenied
    case recordingStartFailed
    case recordingStartCancelled
    case notRecording
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone permission is required."
        case .recordingStartFailed:
            return "Recording could not be started."
        case .recordingStartCancelled:
            return "Recording start was cancelled."
        case .notRecording:
            return "Recording was not active."
        case .noAudioCaptured:
            return "No audio was captured."
        }
    }
}
