import Foundation
import WristAssistShared

try testRealtimeSessionEncoding()
try testMessageRoundTrip()
try testServerEventDecoding()
testPCM16Conversion()
print("WristAssistShared smoke tests passed.")

private func testRealtimeSessionEncoding() throws {
    let settings = ProviderSettings(hasAPIKey: true)
    let data = try RealtimeClientEvent
        .sessionUpdate(RealtimeSession(settings: settings))
        .encodedData()
    let object = try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    try require(object["type"] as? String == "session.update")
    let session = try require(object["session"] as? [String: Any])
    try require(session["model"] as? String == ProviderSettings.defaultModel)
}

private func testMessageRoundTrip() throws {
    let request = WatchToPhoneMessage.requestConfiguration
    let requestEnvelope = try MessageEnvelope(dictionary: request.envelope().dictionary())
    let decodedRequest = try WatchToPhoneMessage(envelope: requestEnvelope)
    try require(decodedRequest == request)

    let configuration = WatchConfiguration(settings: .default, hasAPIKey: true)
    let response = PhoneToWatchMessage.configurationChanged(configuration)
    let responseEnvelope = try MessageEnvelope(dictionary: response.envelope().dictionary())
    let decodedResponse = try PhoneToWatchMessage(envelope: responseEnvelope)
    try require(decodedResponse == response)

    let sync = PhoneToWatchMessage.syncAPIKey("sk-test")
    let syncEnvelope = try MessageEnvelope(dictionary: sync.envelope().dictionary())
    let decodedSync = try PhoneToWatchMessage(envelope: syncEnvelope)
    try require(decodedSync == sync)

    let status = WatchToPhoneMessage.keyStatusResponse(hasKey: true)
    let statusEnvelope = try MessageEnvelope(dictionary: status.envelope().dictionary())
    let decodedStatus = try WatchToPhoneMessage(envelope: statusEnvelope)
    try require(decodedStatus == status)
}

private func testServerEventDecoding() throws {
    let data = #"{"type":"response.output_audio.delta","delta":"YWJj","item_id":"item_123","response_id":"resp_123","content_index":0}"#.data(using: .utf8)!
    let event = try RealtimeServerEvent(data: data)
    try require(
        event == .audioDelta(
            RealtimeOutputAudioDelta(
                base64Audio: "YWJj",
                metadata: RealtimeOutputAudioMetadata(
                    itemID: "item_123",
                    responseID: "resp_123",
                    contentIndex: 0
                )
            )
        )
    )
}

private func testPCM16Conversion() {
    let data = PCM16AudioConverter.pcm16Data(fromFloat32Samples: [-2.0, 0.0, 2.0])
    let values = data.withUnsafeBytes { rawBuffer in
        Array(rawBuffer.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) })
    }
    precondition(values == [-32_768, 0, 32_767])
}

@discardableResult
private func require<T>(_ value: T?) throws -> T {
    guard let value else {
        throw SmokeTestError.failedRequirement
    }
    return value
}

private func require(_ condition: Bool) throws {
    guard condition else {
        throw SmokeTestError.failedRequirement
    }
}

enum SmokeTestError: Error {
    case failedRequirement
}
