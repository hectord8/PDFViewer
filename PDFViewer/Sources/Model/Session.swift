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

/// The whole app state we want to come back to next launch.
struct Session: Codable {
    var showThumbnails: Bool
    var selectedPath: String?
    var tabs: [TabState]
}