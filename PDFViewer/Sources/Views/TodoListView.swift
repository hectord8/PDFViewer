import SwiftUI

struct TodoListView: View {
    @ObservedObject private var store = TodoStore.shared
    @State private var newText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Tasks")
                    .font(.headline)
                Text("\(store.remainingCount) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if store.hasCompleted {
                    Button("Clear done") {
                        store.clearCompleted()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("No tasks yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.items) { item in
                        TodoRow(item: item, store: store)
                    }
                    .onDelete { store.remove(at: $0) }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack(spacing: 6) {
                TextField("Add a task…", text: $newText)
                    .textFieldStyle(.plain)
                    .onSubmit(add)
                    .focused($focused)

                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 260, minHeight: 300)
        .onAppear { focused = true }
    }

    private func add() {
        if store.add(newText) {
            newText = ""
        }
    }
}

private struct TodoRow: View {
    let item: TodoItem
    @ObservedObject var store: TodoStore

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.toggle(item)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Text(item.text)
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? .secondary : .primary)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(item) }
        .contextMenu {
            Button("Delete", role: .destructive) {
                store.remove(item)
            }
        }
    }
}
