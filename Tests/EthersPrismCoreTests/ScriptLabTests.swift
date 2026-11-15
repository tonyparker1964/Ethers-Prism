import XCTest
@testable import EthersPrismCore

final class ScriptLabTests: XCTestCase {
    func testHeaderPutsTheUsersFirstLineAfterTheHeader() {
        let h = ScriptLab.header(libraryFolder: "/tmp/x", picture: "/tmp/p.png")
        XCTAssertEqual(h.components(separatedBy: "\n").count - 1, ScriptLab.headerLines)
        XCTAssertTrue(h.contains(#"prism_gp.IMAGE = r"/tmp/p.png""#))
        XCTAssertTrue(h.contains("from prism_gp import *"))
    }

    func testErrorLinesPointAtTheUsersScript() {
        let tb = """
        Traceback (most recent call last):
          File "script.py", line 9, in <module>
          File "/tmp/abc/prism_gp.py", line 300, in brush
        NameError: name 'gold' is not defined
        """
        let m = ScriptLab.mapError(tb)
        XCTAssertEqual(m.line, 9 - ScriptLab.headerLines)
        XCTAssertTrue(m.message.contains("Line \(9 - ScriptLab.headerLines)"))
        XCTAssertTrue(m.message.contains("NameError"))
        XCTAssertFalse(m.message.contains("/tmp/abc"))
    }

    func testTemplatesAndLibraryAreBuiltIn() {
        XCTAssertGreaterThanOrEqual(ScriptLab.templates.count, 5)
        for t in ScriptLab.templates {
            XCTAssertTrue(t.code.contains("canvas("), t.name)
            XCTAssertTrue(t.code.contains("draw_on("), t.name)
        }
        for fn in ["def canvas(", "def brush(", "def stroke(", "def paint(", "def ink(", "def draw_on(", "def plan_paint("] {
            XCTAssertTrue(ScriptLab.library.contains(fn), fn)
        }
        XCTAssertTrue(ScriptLab.apiReference.contains("brush(name"))
    }

    func testSavingAndListingScripts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ScriptLab.save("canvas()\n", name: "My: Brush", in: dir)
        XCTAssertEqual(url.lastPathComponent, "My- Brush.py")
        XCTAssertEqual(ScriptLab.scripts(in: dir).map(\.lastPathComponent), ["My- Brush.py"])
    }
}
