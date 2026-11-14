import XCTest
@testable import EthersPrismCore

final class BlenderReferenceTests: XCTestCase {
    /// The built-in text must match Docs/Blender-Cheat-Sheet.md (run scripts/sync-blender-reference.py after editing it).
    func testBuiltInTextMatchesTheDoc() throws {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Docs/Blender-Cheat-Sheet.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        XCTAssertEqual(BlenderReference.text, text.trimmingCharacters(in: .newlines),
                       "Run: python3 scripts/sync-blender-reference.py")
        XCTAssertTrue(BlenderReference.text.contains("GREASE_PENCIL_LINEART"))
    }

    func testCoderGetsTheCheatSheetOnlyForBlenderGoals() {
        let blender = WorkingState(goal: "A Blender script: Grease Pencil logo drawing on", domainID: "code", dials: [], constraints: [])
        let other = WorkingState(goal: "A Swift function that sorts names", domainID: "code", dials: [], constraints: [])
        let b = Domains.code.compile(CompileInput(state: blender, quality: .preview))
        let o = Domains.code.compile(CompileInput(state: other, quality: .preview))
        XCTAssertTrue(b.text.system.contains("Blender cheat sheet for Ethers Prism"))
        XCTAssertFalse(o.text.system.contains("Blender cheat sheet"))
        // The writer never gets it, even for a Blender goal.
        let w = Domains.text.compile(CompileInput(state: blender, quality: .preview))
        XCTAssertFalse(w.text.system.contains("Blender cheat sheet"))
    }

    func testSaveWritesTheFile() throws {
        let old = BlenderReference.savedPath
        defer { BlenderReference.savedPath = old }
        BlenderReference.savedPath = NSTemporaryDirectory() + "prism-test-\(UUID().uuidString)/Blender Cheat Sheet.md"
        let path = try BlenderReference.save()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), BlenderReference.text)
    }
}
