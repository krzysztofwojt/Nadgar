import Testing
@testable import WristAssistShared

struct RealtimeServerEventTests {
    @Test func decodesSessionCreated() throws {
        let data = #"{"type":"session.created"}"#.data(using: .utf8)!
        #expect(try RealtimeServerEvent(data: data) == .sessionCreated)
    }

    @Test func decodesAudioDelta() throws {
        let data = #"{"type":"response.audio.delta","delta":"YWJj"}"#.data(using: .utf8)!
        #expect(try RealtimeServerEvent(data: data) == .audioDelta("YWJj"))
    }

    @Test func decodesNestedErrorMessage() throws {
        let data = #"{"type":"error","error":{"message":"bad token"}}"#.data(using: .utf8)!
        #expect(try RealtimeServerEvent(data: data) == .error("bad token"))
    }

    @Test func unknownEventPreservesType() throws {
        let data = #"{"type":"rate_limits.updated"}"#.data(using: .utf8)!
        #expect(try RealtimeServerEvent(data: data) == .unknown("rate_limits.updated"))
    }
}
