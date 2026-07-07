import Foundation
import NadgarShared

try testRealtimeSessionEncoding()
try testMessageRoundTrip()
try testServerEventDecoding()
try testRichMockResponse()
testPCM16Conversion()
print("NadgarShared smoke tests passed.")

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

    let sync = PhoneToWatchMessage.syncAPIKey(profileID: "provider-1", apiKey: "sk-test")
    let syncEnvelope = try MessageEnvelope(dictionary: sync.envelope().dictionary())
    let decodedSync = try PhoneToWatchMessage(envelope: syncEnvelope)
    try require(decodedSync == sync)

    let status = WatchToPhoneMessage.keyStatusResponse(profileID: "provider-1", hasKey: true)
    let statusEnvelope = try MessageEnvelope(dictionary: status.envelope().dictionary())
    let decodedStatus = try WatchToPhoneMessage(envelope: statusEnvelope)
    try require(decodedStatus == status)

    let openURL = WatchToPhoneMessage.openURL("https://openai.com/news")
    let openURLEnvelope = try MessageEnvelope(dictionary: openURL.envelope().dictionary())
    let decodedOpenURL = try WatchToPhoneMessage(envelope: openURLEnvelope)
    try require(decodedOpenURL == openURL)

    let openURLResult = PhoneToWatchMessage.openURLResult(success: true, message: nil)
    let openURLResultEnvelope = try MessageEnvelope(dictionary: openURLResult.envelope().dictionary())
    let decodedOpenURLResult = try PhoneToWatchMessage(envelope: openURLResultEnvelope)
    try require(decodedOpenURLResult == openURLResult)

    let pendingOpenURLRequest = PhoneToWatchMessage.requestPendingOpenURL
    let pendingOpenURLRequestEnvelope = try MessageEnvelope(dictionary: pendingOpenURLRequest.envelope().dictionary())
    let decodedPendingOpenURLRequest = try PhoneToWatchMessage(envelope: pendingOpenURLRequestEnvelope)
    try require(decodedPendingOpenURLRequest == pendingOpenURLRequest)

    let noPendingOpenURL = WatchToPhoneMessage.noPendingOpenURL
    let noPendingOpenURLEnvelope = try MessageEnvelope(dictionary: noPendingOpenURL.envelope().dictionary())
    let decodedNoPendingOpenURL = try WatchToPhoneMessage(envelope: noPendingOpenURLEnvelope)
    try require(decodedNoPendingOpenURL == noPendingOpenURL)
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

private func testRichMockResponse() throws {
    let response = OpenAIMockResponses.richMarkdownCitationResponse(turnNumber: 1)
    try require(response.usedWebSearch)
    try require(response.text.contains("**bold**"))
    try require(response.text.contains("[OpenAI News](https://openai.com/news)"))
    try require(response.citations.count == 3)
    try require(citedText(in: response.text, citation: response.citations[0]) == "latest OpenAI product news")
    try require(citedText(in: response.text, citation: response.citations[1]) == "Warsaw weather alerts for Thursday")
    try require(citedText(in: response.text, citation: response.citations[2]) == "duplicate source")
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

private func citedText(in text: String, citation: ChatCitation) -> String {
    let start = text.index(text.startIndex, offsetBy: citation.startIndex)
    let end = text.index(text.startIndex, offsetBy: citation.endIndex)
    return String(text[start..<end])
}

enum SmokeTestError: Error {
    case failedRequirement
}
