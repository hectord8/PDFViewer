import AVFoundation
import CoreMedia
import Foundation
import Speech

/// On-device lecture transcription. Uses the modern Speech framework APIs when
/// available (macOS 26+) and reports a clear error on older systems.
enum LectureTranscriber {
    static var isAvailable: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    static func transcribe(url: URL) async throws -> [TranscriptCue] {
        guard #available(macOS 26, *) else {
            throw LectureTranscriberError.requiresNewerMacOS
        }
        return try await transcribeModern(url: url)
    }

    @available(macOS 26, *)
    private static func transcribeModern(url: URL) async throws -> [TranscriptCue] {
        guard SpeechTranscriber.isAvailable else {
            throw LectureTranscriberError.unavailable
        }

        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if locale == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-NZ"))
        }
        guard let locale else {
            throw LectureTranscriberError.noSupportedLocale
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        async let analysis: Void = analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var cues: [TranscriptCue] = []
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                cues.append(
                    TranscriptCue(
                        id: cues.count,
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        text: text
                    ))
            }
            try await analysis
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }

        return cues
    }
}

enum LectureTranscriberError: LocalizedError {
    case requiresNewerMacOS
    case unavailable
    case noSupportedLocale

    var errorDescription: String? {
        switch self {
        case .requiresNewerMacOS:
            return
                "On-device transcription requires macOS 26 or later. Choose Groq or OpenAI in transcription settings, or import an Echo360 transcript."
        case .unavailable:
            return "Speech transcription is not available on this Mac right now."
        case .noSupportedLocale:
            return "No speech-recognition model is available for your language."
        }
    }
}
