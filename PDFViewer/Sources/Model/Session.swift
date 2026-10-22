import AppKit
import Foundation

/// A single open tab, in the shape we write to disk.
struct TabState: Codable {
    var path: String
    var bookmark: Data?
    var pageIndex: Int
    var zoomMode: ZoomMode
    var scale: Double
}

enum Pane: String, Codable {
    case primary
    case secondary
}

/// The whole app state we want to come back to next launch.
struct Session: Codable {
    var showThumbnails: Bool
    var selectedPath: String?
    var secondaryPath: String?
    var secondaryBookmark: Data?
    var focusedPane: Pane?
    var splitFraction: Double?
    var pinnedPaths: [String]?
    var tabs: [TabState]
}
