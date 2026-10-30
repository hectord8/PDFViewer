import Foundation
import Testing

#if canImport(PDFViewer)
@testable import PDFViewer
#else
@testable import PDFViewerKit
#endif

struct LectureTranscriptionServiceTests {
    @Test func parsesSegmentResponse() throws {
        let json = #"""
            {
              "text": "Hello world",
              "segments": [
                { "start": 0.0, "end": 1.5, "text": "Hello" },
                { "start": 1.5, "end": 3.0, "text": " world" }
              ]
            }
            """#
        let cues = try LectureTranscriptionService.parseTranscription(Data(json.utf8))

        #expect(cues.count == 2)
        #expect(cues[0].start == 0)
        #expect(cues[0].end == 1.5)
        #expect(cues[0].text == "Hello")
        #expect(cues[1].text == "world")
    }

    @Test func parsesPlainTextResponse() throws {
        let json = #"{"text":"First paragraph.\n\nSecond paragraph."}"#
        let cues = try LectureTranscriptionService.parseTranscription(Data(json.utf8))

        #expect(cues.map(\.text) == ["First paragraph.", "Second paragraph."])
    }

    @Test func rejectsEmptyResponse() {
        #expect(throws: LectureTranscriptionError.self) {
            try LectureTranscriptionService.parseTranscription(Data(#"{"text":""}"#.utf8))
        }
    }
}
