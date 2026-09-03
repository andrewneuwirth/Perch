import Foundation

// MARK: - Model

struct ChecklistLink: Identifiable, Equatable {
    var id = UUID()
    var label: String
    var url: URL

    /// Host without a leading "www." — used as the default label.
    static func defaultLabel(for url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct ChecklistItem: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var isDone = false
    var notes = ""
    var links: [ChecklistLink] = []
}

struct ChecklistGroup: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [ChecklistItem] = []
}

/// In-memory representation of a checklist note. The on-disk format is plain markdown:
///
/// ```
/// # Title
///
/// - [ ] Ungrouped item
///   Notes line
///   - [Label](https://example.com)
///
/// ## Group name
/// - [x] Grouped item
/// ```
struct ChecklistDocument: Equatable {
    var title: String
    /// Non-matching top-level lines (kept so external edits aren't destroyed; not shown in UI).
    var preamble: [String] = []
    var ungrouped: [ChecklistItem] = []
    var groups: [ChecklistGroup] = []

    // MARK: Counts

    var allItems: [ChecklistItem] {
        ungrouped + groups.flatMap(\.items)
    }

    var totalCount: Int { allItems.count }
    var doneCount: Int { allItems.filter(\.isDone).count }

    // MARK: Parse

    static func parse(_ markdown: String) -> ChecklistDocument {
        var lines = markdown.components(separatedBy: "\n")
        var doc = ChecklistDocument(title: "")

        if let first = lines.first, first.hasPrefix("# ") {
            doc.title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        } else if let first = lines.first, first == "#" {
            lines.removeFirst()
        }

        var currentGroup: Int? = nil // index into doc.groups, nil = ungrouped
        var current: ChecklistItem? = nil

        func flush() {
            guard let item = current else { return }
            if let g = currentGroup {
                doc.groups[g].items.append(item)
            } else {
                doc.ungrouped.append(item)
            }
            current = nil
        }

        for rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

            if line.hasPrefix("## ") {
                flush()
                doc.groups.append(ChecklistGroup(name: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                currentGroup = doc.groups.count - 1
                continue
            }

            if let (done, title) = Self.parseTaskLine(line) {
                flush()
                current = ChecklistItem(title: title, isDone: done)
                continue
            }

            let isIndented = line.hasPrefix("  ") || line.hasPrefix("\t")
            if isIndented, current != nil {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if let link = Self.parseLinkLine(trimmed) {
                    current?.links.append(link)
                } else if var item = current {
                    item.notes = item.notes.isEmpty ? trimmed : item.notes + "\n" + trimmed
                    current = item
                }
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Unrecognised top-level line
            flush()
            doc.preamble.append(line)
        }
        flush()
        return doc
    }

    /// `- [ ] Title` / `- [x] Title` (also `*`/`+` markers, `[X]`). Returns nil if not a task line.
    private static func parseTaskLine(_ line: String) -> (done: Bool, title: String)? {
        guard line.count >= 5 else { return nil }
        let marker = line.first!
        guard marker == "-" || marker == "*" || marker == "+" else { return nil }
        let rest = line.dropFirst()
        guard rest.hasPrefix(" [") else { return nil }
        let afterBracket = rest.dropFirst(2)
        guard let state = afterBracket.first, afterBracket.dropFirst().hasPrefix("]") else { return nil }
        let done: Bool
        switch state {
        case " ": done = false
        case "x", "X": done = true
        default: return nil
        }
        let title = afterBracket.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return (done, title)
    }

    /// `- [Label](url)` bullet or a bare http(s) URL.
    private static func parseLinkLine(_ trimmed: String) -> ChecklistLink? {
        var body = Substring(trimmed)
        if let first = body.first, first == "-" || first == "*" || first == "+" {
            body = body.dropFirst().drop(while: { $0 == " " })
        }
        if body.hasPrefix("["), let close = body.firstIndex(of: "]"),
           body[body.index(after: close)...].hasPrefix("("), body.hasSuffix(")")
        {
            let label = String(body[body.index(after: body.startIndex) ..< close])
            let urlStart = body.index(close, offsetBy: 2)
            let urlString = String(body[urlStart ..< body.index(before: body.endIndex)])
            if let url = URL(string: urlString), let scheme = url.scheme, !scheme.isEmpty {
                return ChecklistLink(label: label.isEmpty ? ChecklistLink.defaultLabel(for: url) : label, url: url)
            }
            return nil
        }
        let s = String(body)
        if s.hasPrefix("http://") || s.hasPrefix("https://"), !s.contains(" "), let url = URL(string: s) {
            return ChecklistLink(label: ChecklistLink.defaultLabel(for: url), url: url)
        }
        return nil
    }

    // MARK: Serialize

    func serialize() -> String {
        var out = "# \(title)\n"
        if !preamble.isEmpty {
            out += "\n" + preamble.joined(separator: "\n") + "\n"
        }
        if !ungrouped.isEmpty {
            out += "\n"
            for item in ungrouped { out += Self.serialize(item) }
        }
        for group in groups {
            out += "\n## \(group.name)\n"
            for item in group.items { out += Self.serialize(item) }
        }
        return out
    }

    private static func serialize(_ item: ChecklistItem) -> String {
        var s = "- [\(item.isDone ? "x" : " ")] \(item.title)\n"
        for line in item.notes.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            s += "  \(line)\n"
        }
        for link in item.links {
            s += "  - [\(link.label)](\(link.url.absoluteString))\n"
        }
        return s
    }

    // MARK: Lookup

    /// Location of an item: group index (nil = ungrouped) and position.
    func locate(itemID: UUID) -> (group: Int?, index: Int)? {
        if let i = ungrouped.firstIndex(where: { $0.id == itemID }) { return (nil, i) }
        for (g, group) in groups.enumerated() {
            if let i = group.items.firstIndex(where: { $0.id == itemID }) { return (g, i) }
        }
        return nil
    }

    func item(id: UUID) -> ChecklistItem? {
        guard let loc = locate(itemID: id) else { return nil }
        return items(inGroup: loc.group)[loc.index]
    }

    func items(inGroup group: Int?) -> [ChecklistItem] {
        group.map { groups[$0].items } ?? ungrouped
    }

    private mutating func setItems(_ items: [ChecklistItem], inGroup group: Int?) {
        if let g = group { groups[g].items = items } else { ungrouped = items }
    }

    // MARK: Mutation

    mutating func update(_ item: ChecklistItem) {
        guard let loc = locate(itemID: item.id) else { return }
        var list = items(inGroup: loc.group)
        list[loc.index] = item
        setItems(list, inGroup: loc.group)
    }

    /// Toggle done state. Completed items sink to the end of their group; reopened
    /// items move to the end of the open segment so file order matches display order.
    mutating func toggle(itemID: UUID) {
        guard let loc = locate(itemID: itemID) else { return }
        var list = items(inGroup: loc.group)
        var item = list.remove(at: loc.index)
        item.isDone.toggle()
        if item.isDone {
            list.append(item)
        } else {
            let firstDone = list.firstIndex(where: \.isDone) ?? list.endIndex
            list.insert(item, at: firstDone)
        }
        setItems(list, inGroup: loc.group)
    }

    @discardableResult
    mutating func addItem(title: String, toGroup group: Int?) -> ChecklistItem {
        let item = ChecklistItem(title: title)
        var list = items(inGroup: group)
        let firstDone = list.firstIndex(where: \.isDone) ?? list.endIndex
        list.insert(item, at: firstDone)
        setItems(list, inGroup: group)
        return item
    }

    mutating func removeItem(id: UUID) {
        guard let loc = locate(itemID: id) else { return }
        var list = items(inGroup: loc.group)
        list.remove(at: loc.index)
        setItems(list, inGroup: loc.group)
    }

    /// Move an item to the end of the open segment of another group.
    mutating func moveItem(id: UUID, toGroup group: Int?) {
        guard let item = item(id: id) else { return }
        removeItem(id: id)
        var list = items(inGroup: group)
        if item.isDone {
            list.append(item)
        } else {
            let firstDone = list.firstIndex(where: \.isDone) ?? list.endIndex
            list.insert(item, at: firstDone)
        }
        setItems(list, inGroup: group)
    }

    mutating func clearCompleted() {
        ungrouped.removeAll(where: \.isDone)
        for g in groups.indices { groups[g].items.removeAll(where: \.isDone) }
    }

    @discardableResult
    mutating func addGroup(name: String) -> ChecklistGroup {
        let group = ChecklistGroup(name: name)
        groups.append(group)
        return group
    }

    mutating func renameGroup(id: UUID, to name: String) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[g].name = name
    }

    mutating func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
    }

    /// direction: -1 = up, +1 = down
    mutating func moveGroup(id: UUID, direction: Int) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        let target = g + direction
        guard groups.indices.contains(target) else { return }
        groups.swapAt(g, target)
    }

    // MARK: Seed

    static let seededClassNames = [
        "PHYS410 (Classical Mechanics)",
        "PHYS467 (Quantum)",
        "ENEE304 (Nanoelectronics)",
        "ENEE382 (Electromagnetism)",
    ]

    static func seededClasses(title: String = "Classes") -> ChecklistDocument {
        ChecklistDocument(title: title, groups: seededClassNames.map { ChecklistGroup(name: $0) })
    }
}
