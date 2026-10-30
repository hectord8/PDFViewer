import SwiftUI

struct TranscriptView: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    let cues: [TranscriptCue]
    var onSeek: ((TimeInterval) -> Void)?

    var body: some View {
        Group {
            if cues.isEmpty {
                ContentUnavailableView(
                    "No transcript yet",
                    systemImage: "text.alignleft",
                    description: Text(
                        "Fetch the Echo360 transcript, import a TXT/VTT file, or transcribe an audio file.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(cues) { cue in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                if cue.start > 0, let onSeek {
                                    Button(LectureTranscriptParser.timestamp(cue.start)) {
                                        onSeek(cue.start)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Color.accentColor)
                                    .help("Jump to this point in the lecture")
                                }

                                Text(cue.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .hotReload()
    }
}
