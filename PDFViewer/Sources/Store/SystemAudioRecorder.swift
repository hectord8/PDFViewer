import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures PDFViewer's own audio (including the embedded Echo360 player) to a
/// 16 kHz mono WAV file. Other apps' audio is deliberately excluded.
final class SystemAudioRecorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var fileURL: URL?
    private var startDate: Date?
    private var timer: Timer?
    private var hasAudio = false
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var isCapturePaused = false
    private let audioQueue = DispatchQueue(label: "com.example.PDFViewer.systemAudio")
    private let videoQueue = DispatchQueue(label: "com.example.PDFViewer.systemAudio.video")

    func start() async throws {
        guard !isRecording else { return }

        // The ad-hoc signature changes on every rebuild, which invalidates an
        // existing Screen Recording grant. Ask again explicitly so the error is
        // accurate instead of assuming permission is missing.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard CGPreflightScreenCaptureAccess() else {
                throw SystemAudioRecorderError.permissionDenied
            }
        }

        var content: SCShareableContent?
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                break
            } catch {
                lastError = error
                if !CGPreflightScreenCaptureAccess() {
                    throw SystemAudioRecorderError.permissionDenied
                }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        guard let content else {
            if !CGPreflightScreenCaptureAccess() {
                throw SystemAudioRecorderError.permissionDenied
            }
            throw SystemAudioRecorderError.captureFailed(
                lastError?.localizedDescription ?? "Screen capture is unavailable."
            )
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.PDFViewer"
        let filter: SCContentFilter
        if let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == bundleID
        }) {
            // ScreenCaptureKit's audio filtering is app-level: a window filter
            // captures audio from the owning app, not the whole system.
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display = content.displays.first,
            let application = content.applications.first(where: {
                $0.bundleIdentifier == bundleID
            })
        {
            filter = SCContentFilter(
                display: display,
                including: [application],
                exceptingWindows: []
            )
        } else {
            throw SystemAudioRecorderError.audioSourceNotFound
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // Consume the 2x2, 1 fps video pipeline so ScreenCaptureKit doesn't log
        // dropped frames; audio is the only output we use.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-recording-\(UUID().uuidString).wav")
        fileURL = url
        hasAudio = false
        pausedAt = nil
        pausedDuration = 0
        isCapturePaused = false
        audioQueue.sync {
            audioFile = nil
            converter = nil
            outputFormat = nil
        }

        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            throw SystemAudioRecorderError.captureFailed(error.localizedDescription)
        }

        self.stream = stream
        await MainActor.run {
            isRecording = true
            isPaused = false
            duration = 0
            startDate = Date()
            errorMessage = nil
            timer?.invalidate()
            timer = Timer.scheduledTimer(
                timeInterval: 0.25,
                target: self,
                selector: #selector(tick),
                userInfo: nil,
                repeats: true
            )
        }
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        audioQueue.sync { isCapturePaused = true }
        isPaused = true
        pausedAt = Date()
    }

    func resume() {
        guard isRecording, isPaused else { return }
        audioQueue.sync { isCapturePaused = false }
        if let pausedAt {
            pausedDuration += Date().timeIntervalSince(pausedAt)
        }
        pausedAt = nil
        isPaused = false
    }

    @objc private func tick() {
        guard let startDate else { return }
        var elapsed = Date().timeIntervalSince(startDate) - pausedDuration
        if let pausedAt {
            elapsed -= Date().timeIntervalSince(pausedAt)
        }
        duration = max(0, elapsed)
    }

    func stop() async throws -> URL {
        guard let stream, let url = fileURL else {
            throw SystemAudioRecorderError.notRecording
        }
        try? await stream.stopCapture()
        self.stream = nil

        let captured = audioQueue.sync { () -> Bool in
            flushAudio()
            audioFile = nil
            converter = nil
            outputFormat = nil
            return hasAudio
        }

        await MainActor.run {
            isRecording = false
            isPaused = false
            pausedAt = nil
            pausedDuration = 0
            timer?.invalidate()
            timer = nil
            startDate = nil
        }
        audioQueue.sync { isCapturePaused = false }
        fileURL = nil

        guard captured else {
            try? FileManager.default.removeItem(at: url)
            throw SystemAudioRecorderError.noAudioCaptured
        }
        return url
    }

    func cancel() {
        let pending = fileURL
        Task {
            if let recorded = try? await stop() {
                try? FileManager.default.removeItem(at: recorded)
            } else if let pending {
                try? FileManager.default.removeItem(at: pending)
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    /// Clears the stale TCC entry for this bundle so macOS can prompt again.
    /// Needed because ad-hoc builds get a new cdhash on every rebuild.
    @discardableResult
    static func resetScreenCapturePermission() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.PDFViewer"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard !isCapturePaused else { return }
        do {
            try write(sampleBuffer)
            hasAudio = true
        } catch {
            DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.isPaused = false
            self.pausedAt = nil
            self.pausedDuration = 0
            self.timer?.invalidate()
            self.timer = nil
            self.startDate = nil
            self.errorMessage = error.localizedDescription
        }
    }

    private func flushAudio() {
        guard let converter, let targetFormat = outputFormat, let file = audioFile else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else {
            return
        }
        for _ in 0..<4 {
            var error: NSError?
            buffer.frameLength = 0
            let status = converter.convert(to: buffer, error: &error) { _, outputStatus in
                outputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error || buffer.frameLength == 0 { break }
            try? file.write(from: buffer)
        }
    }

    private func write(_ sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
            let inputFormat = AVAudioFormat(streamDescription: description)
        else {
            return
        }

        if audioFile == nil, let url = fileURL {
            guard
                let desiredFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: true
                )
            else {
                return
            }
            // Create the file with the same processing format we write, so
            // AVAudioFile doesn't run its own converter on the audio thread.
            let file = try AVAudioFile(
                forWriting: url,
                settings: desiredFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            audioFile = file
            outputFormat = file.processingFormat
            converter = nil
        }
        guard let file = audioFile, let targetFormat = outputFormat else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return
        }
        inputBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw SystemAudioRecorderError.writeFailed
        }

        let formatsMatch =
            inputFormat.sampleRate == targetFormat.sampleRate
            && inputFormat.channelCount == targetFormat.channelCount
            && inputFormat.commonFormat == targetFormat.commonFormat
            && inputFormat.isInterleaved == targetFormat.isInterleaved

        if formatsMatch {
            try file.write(from: inputBuffer)
        } else {
            if converter == nil {
                converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(
                (Double(frameCount) * targetFormat.sampleRate / inputFormat.sampleRate).rounded(.up)
            )
            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: max(capacity, frameCount, 1)
                )
            else {
                return
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
                throw conversionError ?? SystemAudioRecorderError.writeFailed
            }
            guard outputBuffer.frameLength > 0 else { return }
            try file.write(from: outputBuffer)
        }

        hasAudio = true
    }
}

enum SystemAudioRecorderError: LocalizedError {
    case permissionDenied
    case noDisplay
    case audioSourceNotFound
    case captureFailed(String)
    case notRecording
    case noAudioCaptured
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return
                "Screen Recording permission is required. Enable PDFViewer in System Settings > Privacy & Security > Screen Recording, then restart PDFViewer and try again."
        case .noDisplay:
            return "No display is available for PDFViewer audio capture."
        case .audioSourceNotFound:
            return "Couldn’t find PDFViewer’s audio source. Open the lecture in the portal and try again."
        case .captureFailed(let message):
            return "Couldn’t start audio capture: \(message)"
        case .notRecording:
            return "No audio recording is in progress."
        case .noAudioCaptured:
            return "No audio was captured. Start the lecture before recording, or check Screen Recording permission."
        case .writeFailed:
            return "Couldn’t write the captured audio."
        }
    }
}
