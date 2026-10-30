import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Echo360 lecture portal: the official web player with a transcript panel
/// that can record PDFViewer's own audio and save notes into a workbook.
struct LecturePortalView: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workbooks: WorkbookStore
    @StateObject private var store = LectureStore.shared
    @StateObject private var web = LectureWebController()
    @StateObject private var recorder = SystemAudioRecorder()

    @AppStorage("lectureTranscriptionProvider") private var transcriptionProviderRaw =
        LectureTranscriptionProvider.onDevice.rawValue

    @State private var cues: [TranscriptCue] = []
    @State private var isFetching = false
    @State private var isTranscribing = false
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var importTranscript = false
    @State private var importAudio = false
    @State private var showTranscriptionSettings = false
    @State private var apiKey = ""
    @State private var showSaveToWorkbook = false
    @State private var pageTitle = "Echo360 Lecture"
    @State private var pageURL = "https://echo360.net.au"

    private let homeURL = URL(string: "https://echo360.net.au")!

    private var transcriptionProvider: LectureTranscriptionProvider {
        LectureTranscriptionProvider(rawValue: transcriptionProviderRaw) ?? .onDevice
    }

    var body: some View {
        VSplitView {
            LectureWebView(url: homeURL, controller: web)
                .frame(minHeight: 260)
            transcriptSection
                .frame(minHeight: 190)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear { recorder.cancel() }
        .onChange(of: recorder.errorMessage) { _, newValue in
            if let newValue {
                errorMessage = newValue
            }
        }
        .fileImporter(
            isPresented: $importTranscript,
            allowedContentTypes: transcriptTypes,
            allowsMultipleSelection: false
        ) { result in
            handleTranscriptImport(result)
        }
        .fileImporter(
            isPresented: $importAudio,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            handleAudioImport(result)
        }
        .alert(
            "Lecture Portal",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            if errorMessage?.contains("Screen Recording") == true {
                Button("Reset Permission") { handleResetPermission() }
                Button("Open Settings") { openScreenRecordingSettings() }
            }
            Button("OK", role: .cancel) {
                errorMessage = nil
                recorder.clearError()
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showSaveToWorkbook) {
            SaveToWorkbookSheet(title: pageTitle) { workbookID, folderID in
                Task { await saveTranscriptToWorkbook(workbookID: workbookID, folderID: folderID) }
            }
        }
        .hotReload()
    }

    // MARK: - Transcript section

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Transcript")
                    .font(.headline)

                if !cues.isEmpty {
                    Text("\(cues.count) cues")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if recorder.isRecording {
                    if recorder.isPaused {
                        Label("Paused", systemImage: "pause.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Label(
                            LectureTranscriptParser.timestamp(recorder.duration),
                            systemImage: "waveform"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                    }
                }

                Spacer()

                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button {
                    loadAPIKey()
                    showTranscriptionSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Transcription settings")
                .popover(isPresented: $showTranscriptionSettings) {
                    transcriptionSettings
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 8) {
                Button("Fetch transcript") {
                    Task { await fetchTranscript() }
                }
                .disabled(isFetching)

                if recorder.isRecording {
                    Button {
                        Task { await stopRecording() }
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .tint(.red)

                    if recorder.isPaused {
                        Button {
                            recorder.resume()
                        } label: {
                            Label("Resume", systemImage: "play.circle.fill")
                        }
                    } else {
                        Button {
                            recorder.pause()
                        } label: {
                            Label("Pause", systemImage: "pause.circle.fill")
                        }
                    }
                } else {
                    Button {
                        Task { await startRecording() }
                    } label: {
                        Label("Start recording", systemImage: "record.circle")
                    }
                    .disabled(isTranscribing)
                }

                Menu {
                    Button("Save to Notes") {
                        Task { await saveTranscriptToNotes() }
                    }
                    Button("Save to Workbook…") {
                        Task { await prepareWorkbookSave() }
                    }
                    Button("Save transcript as Text…") {
                        Task { await exportTranscriptAsText() }
                    }
                } label: {
                    Label("Save transcript", systemImage: "square.and.arrow.down")
                }
                .disabled(cues.isEmpty)

                Menu {
                    Button("Import transcript…") {
                        importTranscript = true
                    }
                    Button("Transcribe audio file…") {
                        importAudio = true
                    }
                    .disabled(isTranscribing)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if isFetching || isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            TranscriptView(cues: cues) { seconds in
                web.seek(to: seconds)
            }
        }
    }

    // MARK: - Transcript fetching

    private func updatePageInfo() async {
        if let title = await web.pageTitle()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            pageTitle = title
        }
        if let url = web.currentURL?.absoluteString {
            pageURL = url
        }
    }

    private func fetchTranscript() async {
        isFetching = true
        status = nil
        defer { isFetching = false }

        await updatePageInfo()
        await web.openTranscriptPanel()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let info = await web.transcriptInfo()

        let lessonID = info?.lessonID ?? LectureStore.lessonID(from: web.currentURL)
        let mediaID = info?.mediaID

        if let lessonID, let mediaID, let url = web.currentURL {
            do {
                let cookies = await web.cookies()
                let lecture = Lecture(title: pageTitle, lessonURL: url.absoluteString)
                let raw = try await store.fetchTranscript(
                    for: lecture,
                    lessonID: lessonID,
                    mediaID: mediaID,
                    cookies: cookies
                )
                let parsed = LectureTranscriptParser.parse(raw)
                if !parsed.isEmpty {
                    cues = parsed
                    status = "Fetched \(parsed.count) cues from Echo360."
                    return
                }
            } catch {
                // Fall through to the transcript panel text.
            }
        }

        if let panel = info?.panelText?.trimmingCharacters(in: .whitespacesAndNewlines), !panel.isEmpty {
            cues = LectureTranscriptParser.parse(panel)
            status = "Read the transcript panel."
            return
        }

        errorMessage = "No transcript was available. Open a lecture recording, or import a TXT/VTT file."
    }

    // MARK: - Recording

    private func startRecording() async {
        do {
            try await recorder.start()
            status = "Recording PDFViewer audio — play the lecture now."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        do {
            let url = try await recorder.stop()
            await transcribeAudioFile(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func transcribeAudioFile(_ url: URL) async {
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            cues = try await LectureTranscriptionService.transcribe(
                audioURL: url,
                provider: transcriptionProvider
            )
            await updatePageInfo()
            status = "Transcribed \(cues.count) cues with \(transcriptionProvider.title)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Imports

    private func handleTranscriptImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "Couldn’t read “\(url.lastPathComponent)”."
            return
        }
        cues = LectureTranscriptParser.parse(raw)
        status = "Imported \(cues.count) cues."
    }

    private func handleAudioImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            await transcribeAudioFile(url)
        }
    }

    // MARK: - Saving

    private func prepareWorkbookSave() async {
        await updatePageInfo()
        showSaveToWorkbook = true
    }

    private func saveTranscriptToNotes() async {
        guard !cues.isEmpty else { return }
        await updatePageInfo()
        library.createNote(title: pageTitle, text: transcriptNote())
        status = "Saved to Notes."
    }

    private func saveTranscriptToWorkbook(workbookID: UUID, folderID: UUID?) async {
        guard !cues.isEmpty else { return }
        await updatePageInfo()

        let note = library.createNote(
            title: pageTitle,
            text: transcriptNote(),
            addToActiveWorkbook: false
        )
        guard let url = note.fileURL else {
            errorMessage = "The transcript note could not be saved."
            return
        }

        workbooks.add(
            workbooks.makeItem(kind: .note, title: note.title, url: url),
            to: workbookID,
            folderID: folderID
        )
        let name = workbooks.workbooks.first { $0.id == workbookID }?.name ?? "workbook"
        status = "Saved to \(name)."
    }

    private func exportTranscriptAsText() async {
        guard !cues.isEmpty else { return }
        await updatePageInfo()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(pageTitle).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try transcriptText().write(to: url, atomically: true, encoding: .utf8)
            status = "Saved transcript text."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func transcriptHeader() -> String {
        let saved = Date.now.formatted(date: .abbreviated, time: .shortened)
        return "Lecture: \(pageTitle)\nSource: \(pageURL)\nSaved: \(saved)\n\n"
    }

    private func transcriptText() -> String {
        transcriptHeader() + LectureTranscriptParser.plainText(cues, includeTimestamps: true) + "\n"
    }

    private func transcriptNote() -> NSAttributedString {
        let header = transcriptHeader()
        let body = LectureTranscriptParser.plainText(cues, includeTimestamps: true) + "\n"

        let attributed = NSMutableAttributedString(string: header)
        attributed.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: 12, weight: .semibold),
            range: NSRange(location: 0, length: (header as NSString).length)
        )
        attributed.append(
            NSAttributedString(
                string: body,
                attributes: [.font: NSFont.systemFont(ofSize: 13)]
            )
        )
        return attributed
    }

    // MARK: - Transcription settings

    private var transcriptionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription")
                .font(.headline)

            Picker("Service", selection: $transcriptionProviderRaw) {
                ForEach(LectureTranscriptionProvider.allCases) { provider in
                    Text(provider.title).tag(provider.rawValue)
                }
            }
            .pickerStyle(.radioGroup)

            if transcriptionProvider == .onDevice {
                Text(transcriptionProvider.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save key") { saveAPIKey() }
                    Button("Clear") { clearAPIKey() }
                    Spacer()
                }

                Text(transcriptionProvider.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { showTranscriptionSettings = false }
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { loadAPIKey() }
        .onChange(of: transcriptionProviderRaw) { _, _ in loadAPIKey() }
    }

    private func loadAPIKey() {
        apiKey = LectureTranscriptionSettings.apiKey(for: transcriptionProvider) ?? ""
    }

    private func saveAPIKey() {
        LectureTranscriptionSettings.setAPIKey(apiKey, for: transcriptionProvider)
        status = "Saved the \(transcriptionProvider.title) API key."
    }

    private func clearAPIKey() {
        apiKey = ""
        LectureTranscriptionSettings.setAPIKey("", for: transcriptionProvider)
        status = "Cleared the API key."
    }

    // MARK: - Permissions

    private func handleResetPermission() {
        errorMessage = nil
        recorder.clearError()

        DispatchQueue.main.async {
            let reset = SystemAudioRecorder.resetScreenCapturePermission()
            let alert = NSAlert()
            alert.messageText = reset ? "Screen Recording Reset" : "Couldn’t Reset Screen Recording"
            alert.informativeText =
                reset
                ? "Click Request Permission and grant the macOS prompt. Then quit PDFViewer and reopen it before recording."
                : "Open System Settings, remove PDFViewer from Screen Recording, then add it again. Then quit and reopen PDFViewer."
            alert.addButton(withTitle: "Request Permission")
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                _ = SystemAudioRecorder.requestScreenCaptureAccess()
                let done = NSAlert()
                done.messageText = "Screen Recording"
                done.informativeText =
                    "If you granted access, quit PDFViewer and reopen it before recording."
                done.addButton(withTitle: "Quit PDFViewer")
                done.addButton(withTitle: "Cancel")
                if done.runModal() == .alertFirstButtonReturn {
                    NSApp.terminate(nil)
                }
            case .alertSecondButtonReturn:
                self.openScreenRecordingSettings()
            default:
                break
            }
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    private var transcriptTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let vtt = UTType(filenameExtension: "vtt") {
            types.append(vtt)
        }
        return types
    }
}
