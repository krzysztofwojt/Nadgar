import Foundation

public struct AssistantSpeechChunker: Equatable, Sendable {
    private var buffer = ""
    private let minimumChunkLength: Int
    private let maximumChunkLength: Int

    public init(minimumChunkLength: Int = 120, maximumChunkLength: Int = 360) {
        self.minimumChunkLength = max(1, minimumChunkLength)
        self.maximumChunkLength = max(self.minimumChunkLength, maximumChunkLength)
    }

    public mutating func append(_ delta: String) -> [String] {
        guard !delta.isEmpty else { return [] }
        buffer += delta
        return drain(allowPartial: false)
    }

    public mutating func flush() -> [String] {
        drain(allowPartial: true)
    }

    private mutating func drain(allowPartial: Bool) -> [String] {
        var chunks: [String] = []

        while true {
            buffer = buffer.trimmingPrefixWhitespaceAndNewlines()
            guard !buffer.isEmpty else { return chunks }

            if let endIndex = firstSentenceBoundary() {
                chunks.append(removeChunk(through: endIndex))
                continue
            }

            if buffer.count >= maximumChunkLength {
                chunks.append(removeChunk(through: forcedBoundary()))
                continue
            }

            if allowPartial {
                let chunk = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeAll(keepingCapacity: true)
                if !chunk.isEmpty {
                    chunks.append(chunk)
                }
            }

            return chunks
        }
    }

    private func firstSentenceBoundary() -> String.Index? {
        var characterCount = 0
        var previousCharacter: Character?

        for index in buffer.indices {
            let character = buffer[index]
            characterCount += 1
            defer { previousCharacter = character }

            guard characterCount <= maximumChunkLength else { return nil }
            guard characterCount >= minimumChunkLength else { continue }

            if character == "\n" {
                return index
            }

            guard Self.isSentenceTerminator(character) else { continue }

            let nextIndex = buffer.index(after: index)
            guard nextIndex == buffer.endIndex || buffer[nextIndex].isWhitespace || buffer[nextIndex].isNewline else {
                continue
            }

            if character == ".",
               previousCharacter?.isNumber == true,
               nextIndex < buffer.endIndex,
               buffer[nextIndex].isWhitespace
            {
                continue
            }

            return index
        }

        return nil
    }

    private func forcedBoundary() -> String.Index {
        var characterCount = 0
        var fallback = buffer.index(before: buffer.endIndex)
        var whitespaceCandidate: String.Index?

        for index in buffer.indices {
            characterCount += 1
            fallback = index

            if buffer[index].isWhitespace || buffer[index].isNewline {
                whitespaceCandidate = index
            }

            if characterCount >= maximumChunkLength {
                return whitespaceCandidate ?? fallback
            }
        }

        return fallback
    }

    private mutating func removeChunk(through endIndex: String.Index) -> String {
        let nextIndex = buffer.index(after: endIndex)
        let chunk = String(buffer[..<nextIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeSubrange(..<nextIndex)
        return chunk
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }
}

private extension String {
    mutating func trimmingPrefixWhitespaceAndNewlines() -> String {
        while let first = first, first.isWhitespace || first.isNewline {
            removeFirst()
        }
        return self
    }
}

public enum AssistantSpeechTextSanitizer {
    public static func spokenText(from text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<https?://[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```[A-Za-z0-9_-]*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "`", with: "")
        result = result.replacingOccurrences(
            of: #"[*_~#>\[\]\|]"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
