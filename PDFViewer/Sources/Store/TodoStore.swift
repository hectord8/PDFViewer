import Foundation

struct TodoItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var isDone = false
}

/// A small, persistent task list shown in a floating panel.
@MainActor
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    @Published private(set) var items: [TodoItem] = []

    private let key = "todoItems"

    private init() {
        load()
    }

    var remainingCount: Int {
        items.filter { !$0.isDone }.count
    }

    var hasCompleted: Bool {
        items.contains { $0.isDone }
    }

    @discardableResult
    func add(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        items.append(TodoItem(text: trimmed))
        save()
        return true
    }

    func toggle(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
        save()
    }

    func remove(_ item: TodoItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func clearCompleted() {
        items.removeAll { $0.isDone }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
