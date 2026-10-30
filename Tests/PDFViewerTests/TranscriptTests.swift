import Foundation
import Testing

#if canImport(PDFViewer)
@testable import PDFViewer
#else
@testable import PDFViewerKit
#endif

struct TranscriptTests {
    @Test func parsesWebVTT() {
        let vtt = """
            WEBVTT

            00:00:01.000 --> 00:00:04.000
            Hello and welcome.

            00:01:05.500 --> 00:01:08.000
            <v Speaker 1>Second cue</v>
            continues here.
            """

        let cues = LectureTranscriptParser.parse(vtt)

        #expect(cues.count == 2)
        #expect(cues[0].start == 1)
        #expect(cues[0].end == 4)
        #expect(cues[0].text == "Hello and welcome.")
        #expect(cues[1].start == 65.5)
        #expect(cues[1].text == "Second cue continues here.")
    }

    @Test func parsesPlainTextAsParagraphs() {
        let cues = LectureTranscriptParser.parse("First paragraph.\n\nSecond paragraph.")

        #expect(cues.count == 2)
        #expect(cues.map(\.text) == ["First paragraph.", "Second paragraph."])
        #expect(cues.allSatisfy { $0.start == 0 })
    }

    @Test func formatsTimestamps() {
        #expect(LectureTranscriptParser.timestamp(5) == "0:05")
        #expect(LectureTranscriptParser.timestamp(65) == "1:05")
        #expect(LectureTranscriptParser.timestamp(3661) == "1:01:01")
    }

    @Test func plainTextCanIncludeTimestamps() {
        let cues = [TranscriptCue(id: 0, start: 65, end: 70, text: "Hello")]

        #expect(LectureTranscriptParser.plainText(cues) == "[1:05] Hello")
        #expect(LectureTranscriptParser.plainText(cues, includeTimestamps: false) == "Hello")
    }
}
