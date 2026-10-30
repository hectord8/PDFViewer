import AVFoundation
import Foundation
import Testing

#if canImport(PDFViewer)
@testable import PDFViewer
#else
@testable import PDFViewerKit
#endif

struct LectureAudioTests {
    @Test func writesConvertedInt16MonoWAV() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-audio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            ),
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        else {
            Issue.record("Could not create audio formats")
            return
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: target.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 48_000)!
        source.frameLength = 48_000
        for buffer in UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        let converter = try #require(AVAudioConverter(from: sourceFormat, to: file.processingFormat))
        let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: source.frameLength)!
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outputStatus in
            if supplied {
                outputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outputStatus.pointee = .haveData
            return source
        }
        #expect(status != .error)
        #expect(output.frameLength > 0)

        try file.write(from: output)
        #expect(file.length > 0)
        #expect(file.processingFormat.sampleRate == 16_000)
        #expect(file.processingFormat.channelCount == 1)
    }

    @Test func streamsConvertedAudioAcrossBuffers() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-stream-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!

        let file = try AVAudioFile(
            forWriting: url,
            settings: target.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        let converter = try #require(AVAudioConverter(from: sourceFormat, to: file.processingFormat))

        for _ in 0..<2 {
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 48_000)!
            source.frameLength = 48_000
            for buffer in UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList) {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }

            let output = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: source.frameLength
            )!
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outputStatus in
                if supplied {
                    outputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outputStatus.pointee = .haveData
                return source
            }
            #expect(status != .error)
            if output.frameLength > 0 {
                try file.write(from: output)
            }
        }

        let tail = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var error: NSError?
        _ = converter.convert(to: tail, error: &error) { _, outputStatus in
            outputStatus.pointee = .endOfStream
            return nil
        }
        if tail.frameLength > 0 {
            try file.write(from: tail)
        }

        #expect(file.length > 0)
    }
}
