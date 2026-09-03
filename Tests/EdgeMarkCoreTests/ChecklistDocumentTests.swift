@testable import ChecklistCore
import XCTest

final class ChecklistDocumentTests: XCTestCase {
    let canonical = """
    # Groceries

    - [ ] Milk
    - [x] Eggs
      Get the free-range ones.
      - [Costco](https://www.costco.com)
    - [ ] Call the plumber
      - [Yelp listing](https://yelp.com/biz/abc)

    ## Hardware
    - [ ] Screws

    ## Empty group

    """

    func testParseCanonical() {
        let doc = ChecklistDocument.parse(canonical)
        XCTAssertEqual(doc.title, "Groceries")
        XCTAssertEqual(doc.ungrouped.map(\.title), ["Milk", "Eggs", "Call the plumber"])
        XCTAssertEqual(doc.ungrouped.map(\.isDone), [false, true, false])
        XCTAssertEqual(doc.ungrouped[1].notes, "Get the free-range ones.")
        XCTAssertEqual(doc.ungrouped[1].links.map(\.label), ["Costco"])
        XCTAssertEqual(doc.ungrouped[1].links.first?.url.absoluteString, "https://www.costco.com")
        XCTAssertEqual(doc.ungrouped[2].links.map(\.label), ["Yelp listing"])
        XCTAssertEqual(doc.groups.map(\.name), ["Hardware", "Empty group"])
        XCTAssertEqual(doc.groups[0].items.map(\.title), ["Screws"])
        XCTAssertTrue(doc.groups[1].items.isEmpty)
        XCTAssertEqual(doc.totalCount, 4)
        XCTAssertEqual(doc.doneCount, 1)
    }

    func testRoundTripIsByteIdentical() {
        let doc = ChecklistDocument.parse(canonical)
        XCTAssertEqual(doc.serialize(), canonical)
    }

    func testSeededClassesRoundTrip() {
        let doc = ChecklistDocument.seededClasses()
        let md = doc.serialize()
        XCTAssertEqual(md, """
        # Classes

        ## PHYS410 (Classical Mechanics)

        ## PHYS467 (Quantum)

        ## ENEE304 (Nanoelectronics)

        ## ENEE382 (Electromagnetism)

        """)
        let reparsed = ChecklistDocument.parse(md)
        XCTAssertEqual(reparsed.groups.map(\.name), ChecklistDocument.seededClassNames)
        XCTAssertEqual(reparsed.serialize(), md)
    }

    func testUppercaseXAndBareURLAndMultilineNotes() {
        let md = """
        # T
        - [X] Done thing
          line one
          line two
          https://example.com/path
        """
        let doc = ChecklistDocument.parse(md)
        XCTAssertTrue(doc.ungrouped[0].isDone)
        XCTAssertEqual(doc.ungrouped[0].notes, "line one\nline two")
        XCTAssertEqual(doc.ungrouped[0].links.first?.label, "example.com")
        XCTAssertEqual(doc.serialize(), """
        # T

        - [x] Done thing
          line one
          line two
          - [example.com](https://example.com/path)

        """)
    }

    func testPreamblePreserved() {
        let md = "# T\n\nSome intro text\n\n- [ ] A\n"
        let doc = ChecklistDocument.parse(md)
        XCTAssertEqual(doc.preamble, ["Some intro text"])
        XCTAssertEqual(doc.serialize(), md)
    }

    func testToggleSinksDoneToBottomAndReopenReturnsToOpenSegment() {
        var doc = ChecklistDocument.parse("# T\n\n- [ ] A\n- [ ] B\n- [ ] C\n")
        let a = doc.ungrouped[0].id
        doc.toggle(itemID: a)
        XCTAssertEqual(doc.ungrouped.map(\.title), ["B", "C", "A"])
        XCTAssertTrue(doc.ungrouped[2].isDone)
        doc.toggle(itemID: a)
        XCTAssertEqual(doc.ungrouped.map(\.title), ["B", "C", "A"])
        XCTAssertFalse(doc.ungrouped[2].isDone)
        // Reopen with a done item present: goes before the done segment
        let b = doc.ungrouped[0].id
        doc.toggle(itemID: b) // B done -> [C, A, B]
        let c = doc.ungrouped[0].id
        doc.toggle(itemID: c) // C done -> [A, B, C]
        doc.toggle(itemID: b) // B reopened -> [A, B, C] with B open before C
        XCTAssertEqual(doc.ungrouped.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(doc.ungrouped.map(\.isDone), [false, false, true])
    }

    func testAddMoveRemoveAndGroups() {
        var doc = ChecklistDocument(title: "T")
        doc.addGroup(name: "G1")
        doc.addGroup(name: "G2")
        let item = doc.addItem(title: "X", toGroup: 0)
        doc.addItem(title: "Y", toGroup: nil)
        XCTAssertEqual(doc.serialize(), "# T\n\n- [ ] Y\n\n## G1\n- [ ] X\n\n## G2\n")
        doc.moveItem(id: item.id, toGroup: 1)
        XCTAssertEqual(doc.groups[0].items.count, 0)
        XCTAssertEqual(doc.groups[1].items.map(\.title), ["X"])
        doc.moveGroup(id: doc.groups[1].id, direction: -1)
        XCTAssertEqual(doc.groups.map(\.name), ["G2", "G1"])
        doc.renameGroup(id: doc.groups[0].id, to: "Renamed")
        XCTAssertEqual(doc.groups[0].name, "Renamed")
        doc.removeItem(id: item.id)
        XCTAssertEqual(doc.totalCount, 1)
        doc.toggle(itemID: doc.ungrouped[0].id)
        doc.clearCompleted()
        XCTAssertEqual(doc.totalCount, 0)
        doc.removeGroup(id: doc.groups[0].id)
        XCTAssertEqual(doc.groups.map(\.name), ["G1"])
    }
}
