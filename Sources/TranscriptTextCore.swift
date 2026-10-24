import Foundation
import os.log

private let transcriptTextLog = OSLog(
    subsystem: "com.zachlatta.freeflow",
    category: "Transcription"
)

enum TranscriptionResponseParsingError: Error, Equatable {
    case invalidResponse
}

enum TranscriptionResponseParser {
    // Whisper can emit these stock phrases for silence or background noise.
    // Only suppress them when segment metadata independently reports a high
    // probability of no speech, which protects genuine short dictations.
    private static let hallucinationPhrases: Set<String> = [
        "thank you",
        "thank you for watching",
        "thank you very much",
        "thank you so much",
        "thanks for watching",
        "please subscribe",
        "like and subscribe",
        "subtitles by",
        "subtitles by the amara.org community",
        "you"
    ]

    // Tuned conservatively against roughly 500 quiet, noisy, and real-speech
    // samples to minimize the chance of filtering genuine short dictations.
    private static let hallucinationNoSpeechThreshold = 0.1

    static func parse(_ data: Data) throws -> String {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranscriptionResponseParsingError.invalidResponse
        }

        if let json = object as? [String: Any],
           let text = json["text"] as? String {
            if isHallucination(text: text, json: json) {
                return ""
            }
            return text
        }

        let plainText = String(data: data, encoding: .utf8) ?? ""
        let text = plainText
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionResponseParsingError.invalidResponse
        }

        return text
    }

    private static func isHallucination(text: String, json: [String: Any]) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        guard hallucinationPhrases.contains(normalized) else {
            return false
        }

        guard let segments = json["segments"] as? [[String: Any]] else {
            os_log(
                .info,
                log: transcriptTextLog,
                "Skipping hallucination filter for '%{public}@': provider response has no segments/no_speech metadata",
                normalized
            )
            return false
        }

        guard let noSpeechProb = segments.first?["no_speech_prob"] as? Double else {
            os_log(
                .info,
                log: transcriptTextLog,
                "Skipping hallucination filter for '%{public}@': provider response omitted no_speech_prob",
                normalized
            )
            return false
        }
        return noSpeechProb >= hallucinationNoSpeechThreshold
    }
}

enum TranscriptOutputSanitizer {
    // Verbatim translation deliberately preserves the cleanup prompt's EMPTY
    // sentinel because "empty" can be legitimate translated speech here.
    static func verbatimTranslation(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func postProcessedTranscript(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if result == "EMPTY" {
            return ""
        }

        return joiningHardLineBreaks(removingDashes(normalizingHyphens(result)))
    }

    /// The cleanup model sometimes writes "peut‑être" or "c'est‑à‑dire" with
    /// a Unicode hyphen (U+2010) or non-breaking hyphen (U+2011). They look
    /// identical but a search for the typed word misses them, so fold both
    /// back to the ASCII hyphen-minus. Dashes (– —) are handled by
    /// `removingDashes`.
    static func normalizingHyphens(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{2010}", with: "-")
            .replacingOccurrences(of: "\u{2011}", with: "-")
    }

    /// The speaker never types em or en dashes, and the cleanup model keeps
    /// adding them whatever the prompt says. A dash opening a line becomes a
    /// "- " list marker, an en dash between numbers a hyphen, and any other
    /// dash a comma.
    static func removingDashes(_ value: String) -> String {
        let rewrites: [(pattern: String, template: String)] = [
            ("(?m)^[ \\t]*[—–][ \\t]+", "- "),
            ("(\\d)[ \\t]*–[ \\t]*(\\d)", "$1-$2"),
            (",?[ \\t]*[—–][ \\t]*", ", ")
        ]
        return rewrites.reduce(value) { text, rewrite in
            text.replacingOccurrences(of: rewrite.pattern, with: rewrite.template, options: .regularExpression)
        }
    }

    /// Asked for paragraphs, the cleanup model often also puts every sentence
    /// on its own line, ending each with a markdown hard break (two trailing
    /// spaces). Rejoin those lines so paragraphs read as prose. Only that
    /// marker joins lines: list items and email sign-offs end without it and
    /// keep their line breaks. Trailing spaces never survive the paste.
    static func joiningHardLineBreaks(_ value: String) -> String {
        var output: [String] = []
        var joinsNextLine = false
        for line in value.components(separatedBy: "\n") {
            let endsWithHardBreak = line.hasSuffix("  ")
            let trimmed = String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
            if joinsNextLine, !trimmed.isEmpty, let previous = output.popLast() {
                output.append(previous + " " + trimmed.drop(while: { $0 == " " }))
            } else {
                output.append(trimmed)
            }
            joinsNextLine = endsWithHardBreak && !trimmed.isEmpty
        }
        return output.joined(separator: "\n")
    }

    static func commandModeTranscript(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func appearsToHaveExecutedInstruction(
        rawTranscript: String,
        cleanedTranscript: String,
        outputLanguage: String
    ) -> Bool {
        guard outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let rawTokens = significantTokens(in: rawTranscript)
        let cleanedTokens = significantTokens(in: cleanedTranscript)
        guard !rawTokens.isEmpty, !cleanedTokens.isEmpty else { return false }

        let instructionMarkers: Set<String> = [
            "ask", "answer", "compose", "create", "draft", "email", "generate", "make",
            "message", "prompt", "reply", "respond", "response", "summarize", "tell",
            "translate", "write", "claude", "chatgpt", "ai", "llm"
        ]
        let rawMarkers = rawTokens.intersection(instructionMarkers)
        guard !rawMarkers.isEmpty else { return false }

        let preservedMarkers = rawMarkers.intersection(cleanedTokens)
        let overlap = rawTokens.intersection(cleanedTokens)
        let overlapRatio = Double(overlap.count) / Double(max(rawTokens.count, 1))
        let assistantPreamblePattern = #"(?i)^\s*(sure|certainly|absolutely|here(?:'s| is)|i(?:'d| would) be happy to|i can)\b"#
        let cleanedHasAssistantPreamble = cleanedTranscript.range(
            of: assistantPreamblePattern,
            options: .regularExpression
        ) != nil
        let rawHasSamePreamble = rawTranscript.range(
            of: assistantPreamblePattern,
            options: .regularExpression
        ) != nil

        return (cleanedHasAssistantPreamble && !rawHasSamePreamble)
            || (preservedMarkers.isEmpty && overlapRatio < 0.35)
    }

    private static func significantTokens(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could",
            "for", "from", "had", "has", "have", "he", "her", "him", "his", "i", "if",
            "in", "into", "is", "it", "its", "just", "me", "my", "of", "on", "or", "our",
            "please", "she", "so", "that", "the", "their", "them", "then", "there", "this",
            "to", "um", "uh", "was", "we", "were", "what", "when", "where", "who", "with",
            "would", "you", "your"
        ]

        let normalized = text.lowercased()
        let parts = normalized.split { character in
            !character.isLetter && !character.isNumber
        }

        return Set(parts.map(String.init).filter { token in
            token.count > 1 && !stopWords.contains(token)
        })
    }
}
