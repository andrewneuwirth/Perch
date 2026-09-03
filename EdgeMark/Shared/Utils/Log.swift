import OSLog

nonisolated enum Log {
    static let app = Logger(subsystem: "io.github.ender-wang.Perch", category: "app")
    static let storage = Logger(subsystem: "io.github.ender-wang.Perch", category: "storage")
    static let window = Logger(subsystem: "io.github.ender-wang.Perch", category: "window")
    static let shortcuts = Logger(subsystem: "io.github.ender-wang.Perch", category: "shortcuts")
    static let navigation = Logger(subsystem: "io.github.ender-wang.Perch", category: "navigation")
    static let updates = Logger(subsystem: "io.github.ender-wang.Perch", category: "updates")
    static let peek = Logger(subsystem: "io.github.ender-wang.Perch", category: "peek")
}
