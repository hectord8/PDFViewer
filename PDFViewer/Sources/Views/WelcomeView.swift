import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tertiary)

            Text("No PDF Open")
                .font(.title2.weight(.medium))

            Text("Drop PDFs here, or open them from Finder.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Open PDF…") {
                store.presentOpenPanel()
            }
            .controlSize(.large)
            .padding(.top, 4)

            VStack(spacing: 3) {
                shortcutRow("Open", "⌘O")
                shortcutRow("Find", "⌘F")
                shortcutRow("Next / Previous Tab", "⌘⇧] / ⌘⇧[")
                shortcutRow("Close Tab", "⌘W")
                shortcutRow("Thumbnails", "⌘⇧T")
                shortcutRow("Zoom In / Out", "⌘+ / ⌘−")
            }
            .padding(.top, 18)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func shortcutRow(_ label: String, _ keys: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Text(keys)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}