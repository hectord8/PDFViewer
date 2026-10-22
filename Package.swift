// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PDFViewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PDFViewerKit", targets: ["PDFViewerKit"])
    ],
    targets: [
        .target(
            name: "PDFViewerKit",
            path: "PDFViewer/Sources",
            exclude: ["App/PDFViewerApp.swift"]
        ),
        .testTarget(
            name: "PDFViewerTests",
            dependencies: ["PDFViewerKit"],
            path: "Tests/PDFViewerTests"
        )
    ]
)
