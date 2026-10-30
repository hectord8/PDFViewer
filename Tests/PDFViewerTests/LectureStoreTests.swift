import Foundation
import Testing

#if canImport(PDFViewer)
@testable import PDFViewer
#else
@testable import PDFViewerKit
#endif

struct LectureStoreTests {
    private func makeStore() -> (LectureStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFViewerLectureTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "PDFViewerLectureTests-\(UUID().uuidString)")!
        return (LectureStore(defaults: defaults, storageDirectory: directory), directory)
    }

    @Test func addsAndDeduplicatesLessons() {
        let (store, _) = makeStore()

        let first = store.add(lessonURL: "https://echo360.net.au/lesson/abc-123/classroom", title: "Week 1")
        let duplicate = store.add(lessonURL: "https://echo360.net.au/lesson/abc-123/classroom")

        #expect(store.lectures.count == 1)
        #expect(first?.title == "Week 1")
        #expect(duplicate?.id == first?.id)
    }

    @Test func rejectsInvalidURLs() {
        let (store, _) = makeStore()

        #expect(store.add(lessonURL: "   ") == nil)
    }

    @Test func renamesAndRemoves() {
        let (store, _) = makeStore()
        guard let lecture = store.add(lessonURL: "https://echo360.net.au/lesson/abc/classroom") else {
            Issue.record("Could not add lecture")
            return
        }

        store.rename(lecture, to: "Signals and Systems")
        #expect(store.lectures.first?.title == "Signals and Systems")

        store.remove(lecture)
        #expect(store.lectures.isEmpty)
    }

    @Test func marksLectureOpened() {
        let (store, _) = makeStore()
        guard let lecture = store.add(lessonURL: "https://echo360.net.au/lesson/abc/classroom") else {
            Issue.record("Could not add lecture")
            return
        }

        store.markOpened(lecture)

        #expect(store.lectures.first?.lastOpened != nil)
        #expect(store.lastSelectedLectureID == lecture.id)
    }

    @Test func persistsAcrossInstances() {
        let (store, directory) = makeStore()
        guard let lecture = store.add(lessonURL: "https://echo360.net.au/lesson/abc/classroom", title: "Week 2") else {
            Issue.record("Could not add lecture")
            return
        }
        store.updateMediaID(lecture, mediaID: "media-1")
        store.saveNow()

        let defaults = UserDefaults(suiteName: "PDFViewerLectureTests-\(UUID().uuidString)")!
        let reloaded = LectureStore(defaults: defaults, storageDirectory: directory)

        #expect(reloaded.lectures.count == 1)
        #expect(reloaded.lectures[0].title == "Week 2")
        #expect(reloaded.lectures[0].mediaID == "media-1")
    }

    @Test func extractsLessonIDFromURL() {
        #expect(
            LectureStore.lessonID(from: URL(string: "https://echo360.net.au/lesson/abc-123/classroom"))
                == "abc-123"
        )
        #expect(LectureStore.lessonID(from: URL(string: "https://echo360.net.au/home")) == nil)
    }

    @Test func buildsTranscriptEndpoint() {
        let lessonURL = URL(string: "https://echo360.net.au/lesson/lesson1/classroom")!
        let endpoint = LectureStore.transcriptEndpoint(
            lessonURL: lessonURL,
            lessonID: "lesson1",
            mediaID: "media1"
        )

        #expect(
            endpoint?.absoluteString
                == "https://echo360.net.au/api/ui/echoplayer/lessons/lesson1/medias/media1/transcript-file?format=vtt"
        )
    }
}
