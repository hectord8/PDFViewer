import AVFoundation
import Foundation
import Security

enum LectureTranscriptionProvider: String, CaseIterable, Identifiable {
    case onDevice
    case groq
    case openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: return "On-device (free)"
        case .groq: return "Groq Whisper (free tier)"
        case .openAI: return "OpenAI Whisper"
        }
    }

    var endpoint: URL? {
        switch self {
        case .onDevice:
            return nil
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")
        case .openAI:
            return URL(string: "https://api.openai.com/v1/audio/transcriptions")
        }
    }

    var model: String? {
        switch self {
        case .onDevice: return nil
        case .groq: return "whisper-large-v3-turbo"
        case .openAI: return "whisper-1"
        }
    }

    var keyAccount: String? {
        switch self {
        case .onDevice: return nil
        case .groq: return "groq.apiKey"
        case .openAI: return "openAI.apiKey"
        }
    }

    var helpText: String {
        switch self {
        case .onDevice:
            return "Apple Speech runs on this Mac. Free and private, but needs macOS 26 for long lectures."
        case .groq:
            return "Groq offers a free tier with rate limits. Create a key at console.groq.com."
        case .openAI:
            return "OpenAI Whisper is billed per minute of audio."
        }
    }
}

enum LectureTranscriptionSettings {
    private static let providerKey = "lectureTranscriptionProvider"

    static var provider: LectureTranscriptionProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: providerKey)
            return raw.flatMap(LectureTranscriptionProvider.init(rawValue:)) ?? .onDevice
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
        }
    }

    static func apiKey(for provider: LectureTranscriptionProvider) -> String? {
        guard let account = provider.keyAccount else { return nil }
        return KeychainStore.read(account: account)
    }

    static func setAPIKey(_ key: String, for provider: LectureTranscriptionProvider) {
        guard let account = provider.keyAccount else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account: account)
        } else {
            KeychainStore.save(trimmed, account: account)
        }
    }
}

enum LectureTranscriptionService {
    static func transcribe(
        audioURL: URL,
        provider: LectureTranscriptionProvider
    ) async throws -> [TranscriptCue] {
        switch provider {
        case .onDevice:
            return try await LectureTranscriber.transcribe(url: audioURL)
        case .groq, .openAI:
            return try await transcribeInCloud(audioURL: audioURL, provider: provider)
        }
    }

    static func transcribeInCloud(
        audioURL: URL,
        provider: LectureTranscriptionProvider
    ) async throws -> [TranscriptCue] {
        guard provider.endpoint != nil, provider.model != nil else {
            throw LectureTranscriptionError.unsupportedProvider
        }
        guard let key = LectureTranscriptionSettings.apiKey(for: provider), !key.isEmpty else {
            throw LectureTranscriptionError.missingAPIKey(provider)
        }

        let normalized = try normalizeTo16kMonoWAV(audioURL)
        defer {
            if normalized.isTemporary {
                try? FileManager.default.removeItem(at: normalized.url)
            }
        }

        let size =
            (try? FileManager.default.attributesOfItem(atPath: normalized.url.path)[.size] as? Int) ?? 0
        if size <= maxUploadBytes {
            return try await transcribeFile(
                normalized.url,
                provider: provider,
                key: key,
                offset: 0,
                idOffset: 0
            )
        }
        return try await transcribeChunks(normalized.url, provider: provider, key: key)
    }

    private static let maxUploadBytes = 20 * 1024 * 1024
    private static let chunkSeconds: Double = 300

    private static func transcribeFile(
        _ audioURL: URL,
        provider: LectureTranscriptionProvider,
        key: String,
        offset: TimeInterval,
        idOffset: Int
    ) async throws -> [TranscriptCue] {
        guard let endpoint = provider.endpoint, let model = provider.model else {
            throw LectureTranscriptionError.unsupportedProvider
        }

        let audio = try Data(contentsOf: audioURL)
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = multipartBody(
            boundary: boundary,
            audio: audio,
            filename: audioURL.lastPathComponent,
            model: model,
            includeSegmentGranularity: provider == .openAI
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LectureTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LectureTranscriptionError.http(
                http.statusCode,
                serverMessage(from: data) ?? "Transcription failed."
            )
        }

        let parsed = try parseTranscription(data)
        return parsed.map { cue in
            TranscriptCue(
                id: idOffset + cue.id,
                start: cue.start + offset,
                end: cue.end + offset,
                text: cue.text
            )
        }
    }

    private static func transcribeChunks(
        _ audioURL: URL,
        provider: LectureTranscriptionProvider,
        key: String
    ) async throws -> [TranscriptCue] {
        let input = try AVAudioFile(forReading: audioURL)
        let format = input.processingFormat
        let chunkFrames = AVAudioFramePosition(format.sampleRate * chunkSeconds)
        var offsetFrames: AVAudioFramePosition = 0
        var cues: [TranscriptCue] = []

        while offsetFrames < input.length {
            let remaining = input.length - offsetFrames
            let frames = AVAudioFrameCount(min(chunkFrames, remaining))
            input.framePosition = offsetFrames
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                break
            }
            try input.read(into: buffer, frameCount: frames)

            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lecture-chunk-\(UUID().uuidString).wav")
            let output = try AVAudioFile(forWriting: chunkURL, settings: format.settings)
            try output.write(from: buffer)

            let offset = Double(offsetFrames) / format.sampleRate
            let chunkCues = try await transcribeFile(
                chunkURL,
                provider: provider,
                key: key,
                offset: offset,
                idOffset: cues.count
            )
            cues.append(contentsOf: chunkCues)
            try? FileManager.default.removeItem(at: chunkURL)
            offsetFrames += AVAudioFramePosition(frames)
        }

        return cues
    }

    private static func normalizeTo16kMonoWAV(_ url: URL) throws -> (url: URL, isTemporary: Bool) {
        let input = try AVAudioFile(forReading: url)
        let source = input.processingFormat
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        else {
            throw LectureTranscriptionError.audioConversionFailed
        }

        let matches =
            source.sampleRate == target.sampleRate
            && source.channelCount == target.channelCount
            && source.commonFormat == target.commonFormat
            && source.isInterleaved == target.isInterleaved
        if matches {
            return (url, false)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-upload-\(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: outputURL, settings: target.settings)
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw LectureTranscriptionError.audioConversionFailed
        }

        let bufferFrames = AVAudioFrameCount(max(source.sampleRate, 1))
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: bufferFrames) else {
            throw LectureTranscriptionError.audioConversionFailed
        }

        while true {
            inputBuffer.frameLength = 0
            try input.read(into: inputBuffer)
            guard inputBuffer.frameLength > 0 else { break }

            let capacity = AVAudioFrameCount(
                (Double(inputBuffer.frameLength) * target.sampleRate / source.sampleRate).rounded(.up)
            )
            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: target,
                    frameCapacity: max(capacity, inputBuffer.frameLength, 1)
                )
            else {
                throw LectureTranscriptionError.audioConversionFailed
            }

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                _, outputStatus in
                if supplied {
                    outputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outputStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error {
                throw conversionError ?? LectureTranscriptionError.audioConversionFailed
            }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
            }
        }

        // Drain any samples still buffered by the sample-rate converter.
        for _ in 0..<4 {
            guard let tail = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
                break
            }
            var conversionError: NSError?
            let status = converter.convert(to: tail, error: &conversionError) { _, outputStatus in
                outputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error || tail.frameLength == 0 { break }
            try output.write(from: tail)
        }

        return (outputURL, true)
    }

    static func parseTranscription(_ data: Data) throws -> [TranscriptCue] {
        struct Response: Decodable {
            struct Segment: Decodable {
                let start: Double
                let end: Double
                let text: String
            }

            let text: String?
            let segments: [Segment]?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        if let segments = response.segments, !segments.isEmpty {
            return segments.enumerated().compactMap { index, segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptCue(id: index, start: segment.start, end: segment.end, text: text)
            }
        }
        if let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LectureTranscriptParser.parse(text)
        }
        throw LectureTranscriptionError.emptyResponse
    }

    private static func multipartBody(
        boundary: String,
        audio: Data,
        filename: String,
        model: String,
        includeSegmentGranularity: Bool
    ) -> Data {
        var body = Data()
        func add(_ string: String) {
            body.append(Data(string.utf8))
        }

        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        add("\(model)\r\n")

        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        add("verbose_json\r\n")

        if includeSegmentGranularity {
            add("--\(boundary)\r\n")
            add("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n")
            add("segment\r\n")
        }

        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        add("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        add("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return object["message"] as? String
    }
}

enum LectureTranscriptionError: LocalizedError {
    case unsupportedProvider
    case missingAPIKey(LectureTranscriptionProvider)
    case invalidResponse
    case http(Int, String)
    case emptyResponse
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "That transcription service isn’t supported."
        case .missingAPIKey(let provider):
            return "Add an API key for \(provider.title) in the transcription settings."
        case .invalidResponse:
            return "The transcription service returned an invalid response."
        case .audioConversionFailed:
            return "Couldn’t convert the recording to a format the transcription service accepts."
        case .http(let status, let message):
            switch status {
            case 401:
                return "The transcription API key was rejected. Check it in the portal settings."
            case 429:
                return
                    "The transcription service is rate-limiting requests. Try again later or use on-device transcription."
            default:
                return "Transcription failed (HTTP \(status)): \(message)"
            }
        case .emptyResponse:
            return "The transcription service returned an empty transcript."
        }
    }
}

private enum KeychainStore {
    private static let service = "com.example.PDFViewer.lecture-transcription"

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
