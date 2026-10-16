import AppKit
import SwiftUI

struct FlashcardView: View {
    @ObservedObject var tab: FlashcardTab

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if tab.cards.isEmpty {
                emptyView
            } else if tab.isFinished {
                finishedView
            } else {
                cardArea
                Divider()
                footer
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title)
                    .font(.title2.bold())

                if let url = tab.deckURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label(url.path, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal the deck folder in Finder")
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(tab.knownCount) of \(tab.totalCount) known")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                ProgressView(value: tab.progress)
                    .frame(width: 160)

                Button {
                    tab.shuffle()
                } label: {
                    Label("Shuffle remaining", systemImage: "shuffle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(tab.queue.count < 2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var cardArea: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            if let card = tab.current {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tab.showingBack ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )

                    VStack(spacing: 14) {
                        Text(tab.showingBack ? "Back" : "Front")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(tab.showingBack ? card.back : card.front)
                            .font(.system(size: 22, weight: .medium))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity)

                        if !tab.showingBack {
                            Text("Click to reveal the answer")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(32)
                }
                .frame(maxWidth: 620)
                .frame(height: 340)
                .contentShape(Rectangle())
                .onTapGesture { tab.flip() }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if tab.showingBack {
                Button {
                    tab.rate(.dontKnow)
                } label: {
                    Label("Don’t know", systemImage: "xmark")
                }
                .tint(.red)
                .keyboardShortcut("f", modifiers: [])

                Button {
                    tab.rate(.stillLearning)
                } label: {
                    Label("Still learning", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(.orange)
                .keyboardShortcut("g", modifiers: [])

                Button {
                    tab.rate(.know)
                } label: {
                    Label("I know", systemImage: "checkmark")
                }
                .tint(.green)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("h", modifiers: [])
            } else {
                Button {
                    tab.flip()
                } label: {
                    Label("Show answer", systemImage: "arrow.2.squarepath")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
            }

            Spacer()

            Text("\(tab.remainingCount) remaining")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("This deck is empty.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var finishedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You know all \(tab.totalCount) card\(tab.totalCount == 1 ? "" : "s")")
                .font(.title3.bold())

            Text("Every card has been marked as known.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Study again") {
                tab.restart()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
