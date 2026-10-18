import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var store: LibraryStore

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                header
                featureRow
                shortcuts
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .background(background)
    }

    private var header: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 84, height: 84)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
                    )

                Image(systemName: "doc.text.image")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("Welcome to PDF Viewer")
                    .font(.system(size: 26, weight: .semibold))

                Text("Open documents, organise them into workbooks, and study with AI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button {
                    store.presentOpenPanel()
                } label: {
                    Label("Open PDF…", systemImage: "folder")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    store.showLibrary = true
                } label: {
                    Label("Workbooks", systemImage: "books.vertical")
                }
                .controlSize(.large)
            }
            .padding(.top, 2)
        }
    }

    private var featureRow: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            feature(icon: "books.vertical", title: "Workbooks", text: "Group lectures, papers and generated material.")
            feature(icon: "bubble.left.and.bubble.right", title: "Workbook Assistant", text: "Ask across the whole workbook and see sources.")
            feature(icon: "text.bubble", title: "Annotate", text: "AI notes beside each page, saved with the PDF.")
            feature(icon: "rectangle.on.rectangle", title: "Study", text: "Quizzes, flashcards and summaries from your documents.")
        }
    }

    private func feature(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                shortcut("Open", "⌘O")
                shortcut("Find", "⌘F")
                shortcut("Next / Previous Tab", "⌘⇧] / [")
                shortcut("Close Tab", "⌘W")
                shortcut("Reopen Closed Tab", "⌘⇧T")
                shortcut("Thumbnails", "⌘⌥T")
                shortcut("Notes", "⌘⌥N")
                shortcut("Library", "⌘⌥L")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcut(_ label: String, _ keys: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
