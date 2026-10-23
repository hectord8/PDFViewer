import SwiftUI

struct FindBar: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @ObservedObject var tab: PDFDocumentTab
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in document", text: $tab.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { tab.performSearch() }
                .onChange(of: tab.searchText) { _, _ in tab.scheduleSearch() }

            Text(tab.matchSummary)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)

            Button {
                tab.previousMatch()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(tab.matches.isEmpty)
            .help("Previous match")

            Button {
                tab.nextMatch()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(tab.matches.isEmpty)
            .help("Next match")

            Divider().frame(height: 18)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close the find bar (esc)")
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(.bar)
        .onAppear { fieldFocused = true }
        .onExitCommand(perform: onClose)
        .hotReload()
    }
}
