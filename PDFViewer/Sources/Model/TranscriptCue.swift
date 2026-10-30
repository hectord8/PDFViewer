import Foundation

/// One timed block of transcript text.
struct TranscriptCue: Identifiable, Equatable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Parses Echo360 transcripts (WebVTT or plain text) into displayable cues.
enum LectureTranscriptParser {
    static func parse(_ raw: String) -> [TranscriptCue] {
        let text =
            raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var cues: [TranscriptCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeParts = lines[timeIndex].components(separatedBy: "-->")
            guard timeParts.count == 2 else { continue }

            let start = timestamp(from: timeParts[0])
            let endToken =
                timeParts[1]
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ")
                .first ?? ""
            let end = timestamp(from: endToken)

            let body = lines[(timeIndex + 1)...]
                .joined(separator: " ")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }

            cues.append(TranscriptCue(id: cues.count, start: start, end: end, text: body))
        }

        if cues.isEmpty {
            let paragraphs =
                text
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            cues = paragraphs.enumerated().map { index, paragraph in
                TranscriptCue(id: index, start: 0, end: 0, text: paragraph)
            }
        }

        return cues
    }

    static func plainText(_ cues: [TranscriptCue], includeTimestamps: Bool = true) -> String {
        cues.map { cue in
            let prefix = includeTimestamps && cue.start > 0 ? "[\(timestamp(cue.start))] " : ""
            return prefix + cue.text
        }
        .joined(separator: "\n")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private static func timestamp(from value: String) -> TimeInterval {
        let cleaned =
            value
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map { Double($0) ?? 0 }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }
}
