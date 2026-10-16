import SwiftUI

struct DocumentTabBar: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.tabs) { tab in
                        tabButton(for: tab)
                            .id(tab.id)
                    }

                    Button {
                        store.presentOpenPanel()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open another PDF")
                    .padding(.leading, 2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: store.selectedTabID) { _, newValue in
                guard let newValue else { return }
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
        .frame(height: 36)
        .background(.bar)
    }

    private func tabButton(for tab: PDFDocumentTab) -> some View {
        let isSelected = store.selectedTabID == tab.id

        return HStack(spacing: 6) {
            Button {
                store.select(tab)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                    Text(tab.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                }
                .frame(maxWidth: 180, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.url.path)

            Button {
                store.closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.55))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close this tab")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                .shadow(color: .black.opacity(isSelected ? 0.18 : 0), radius: 1.5, y: 0.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(isSelected ? 0.10 : 0.06), lineWidth: 1)
        }
    }
}