import Foundation

public enum SecretRedactor {
    public static func redact(_ value: String) -> String {
        var redacted = value
        redacted = replacing(pattern: #"sk-proj-[A-Za-z0-9_\-]{4,}"#, in: redacted, with: "[redacted-api-key]")
        redacted = replacing(pattern: #"sk-[A-Za-z0-9_\-]{4,}"#, in: redacted, with: "[redacted-api-key]")
        redacted = replacing(pattern: #"Bearer\s+[A-Za-z0-9._\-]+"#, in: redacted, with: "Bearer [redacted-token]")
        return redacted
    }

    private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}
