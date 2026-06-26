import Foundation
import Testing
@testable import WristAssistShared

struct AssistantSpeechChunkerTests {
    @Test func defaultChunkerGroupsShortSentencesForNaturalSpeech() {
        var chunker = AssistantSpeechChunker()

        #expect(chunker.append("Dzień dobry. ") == [])
        #expect(chunker.append("Jasne, pomogę w tym. ") == [])
        #expect(chunker.append("Zacznijmy od krótkiego podsumowania i dopiero wtedy przeczytajmy całość jednym bardziej naturalnym fragmentem.") == [
            "Dzień dobry. Jasne, pomogę w tym. Zacznijmy od krótkiego podsumowania i dopiero wtedy przeczytajmy całość jednym bardziej naturalnym fragmentem."
        ])
    }

    @Test func chunkerEmitsCompletedSentencesInOrder() {
        var chunker = AssistantSpeechChunker(minimumChunkLength: 8, maximumChunkLength: 80)

        #expect(chunker.append("First ") == [])
        #expect(chunker.append("sentence. Second") == ["First sentence."])
        #expect(chunker.append(" sentence?") == ["Second sentence?"])
        #expect(chunker.flush() == [])
    }

    @Test func chunkerDoesNotHoldUnpunctuatedTextForever() {
        var chunker = AssistantSpeechChunker(minimumChunkLength: 8, maximumChunkLength: 18)

        let chunks = chunker.append("This fragment has no sentence terminator yet")

        #expect(chunks == ["This fragment has", "no sentence"])
        #expect(chunker.flush() == ["terminator yet"])
    }

    @Test func chunkerCapsLongSentencesBeforeLateTerminator() {
        var chunker = AssistantSpeechChunker(minimumChunkLength: 8, maximumChunkLength: 18)

        let chunks = chunker.append("This fragment has no terminator until very late.")

        #expect(chunks == ["This fragment has", "no terminator", "until very late."])
        #expect(chunks.allSatisfy { $0.count <= 18 })
        #expect(chunker.flush() == [])
    }

    @Test func chunkerFlushesFinalPartialText() {
        var chunker = AssistantSpeechChunker(minimumChunkLength: 20, maximumChunkLength: 80)

        #expect(chunker.append("Short final answer") == [])
        #expect(chunker.flush() == ["Short final answer"])
    }

    @Test func sanitizerRemovesMarkdownArtifactsForSpeech() {
        let spokenText = AssistantSpeechTextSanitizer.spokenText(
            from: "## Title with [OpenAI](https://openai.com) and `inline code` plus <https://example.com>."
        )

        #expect(spokenText == "Title with OpenAI and inline code plus .")
    }
}
