import Foundation

enum WorkbookItemKind: String, Codable {
    case pdf
    case summary
    case deck
}

struct WorkbookItem: Codable, Identifiable {
    var id: UUID = UUID()
    var kind: WorkbookItemKind
    var title: String
    var path: String
    var bookmark: Data?
}

/// A named group of items inside a workbook, used to separate different
/// kinds of material (e.g. lectures vs past papers).
struct WorkbookFolder: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var items: [WorkbookItem] = []
}

struct Workbook: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var items: [WorkbookItem] = []
    var folders: [WorkbookFolder] = []

    init(id: UUID = UUID(), name: String, items: [WorkbookItem] = [], folders: [WorkbookFolder] = []) {
        self.id = id
        self.name = name
        self.items = items
        self.folders = folders
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, items, folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        items = try container.decodeIfPresent([WorkbookItem].self, forKey: .items) ?? []
        folders = try container.decodeIfPresent([WorkbookFolder].self, forKey: .folders) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(items, forKey: .items)
        try container.encode(folders, forKey: .folders)
    }
}
