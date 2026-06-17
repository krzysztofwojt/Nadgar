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

    let configuration = WatchConfiguration(settings: .default, apiKey: "sk-test")
    let response = PhoneToWatchMessage.configurationChanged(configuration)
    let responseEnvelope = try MessageEnvelope(dictionary: response.envelope().dictionary())
    let decodedResponse = try PhoneToWatchMessage(envelope: responseEnvelope)
    try require(decodedResponse == response)
}

private func testServerEventDecoding() throws {
    let data = #"{"type":"response.audio.delta","delta":"YWJj"}"#.data(using: .utf8)!
    let event = try RealtimeServerEvent(data: data)
    try require(event == .audioDelta("YWJj"))
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
