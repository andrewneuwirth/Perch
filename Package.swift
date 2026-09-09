// swift-tools-version: 5.9
// Test-only package. The app target compiles these same source files directly via the
// Xcode project; this package exists so the pure-Foundation core can run under `swift test`.
import PackageDescription

let package = Package(
    name: "EdgeMarkCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ChecklistCore", path: "EdgeMark/Core/Checklist"),
        .target(name: "FavoritesCore", path: "EdgeMark/Core/Favorites"),
        .target(name: "MemoryCore", path: "EdgeMark/Core/Memory"),
        .target(name: "PanelGeometryCore", path: "EdgeMark/Core/PanelGeometry"),
        .testTarget(
            name: "EdgeMarkCoreTests",
            dependencies: ["ChecklistCore", "FavoritesCore", "MemoryCore", "PanelGeometryCore"],
            path: "Tests/EdgeMarkCoreTests",
        ),
    ],
)
