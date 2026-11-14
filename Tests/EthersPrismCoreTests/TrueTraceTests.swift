import XCTest
@testable import EthersPrismCore

final class TrueTraceTests: XCTestCase {
    func testLooksMapToGreasePencilFamilies() {
        XCTAssertEqual(TrueTrace.family(look: "Anime", collection: "Images"), .anime)
        XCTAssertEqual(TrueTrace.family(look: "1990s cel anime", collection: "Anime"), .anime)
        XCTAssertEqual(TrueTrace.family(look: "Manga", collection: "Images"), .ink)
        XCTAssertEqual(TrueTrace.family(look: "Pixel Art", collection: "Images"), .pixel)
        XCTAssertEqual(TrueTrace.family(look: "Watercolor Storybook", collection: "Images"), .paint)
        XCTAssertEqual(TrueTrace.family(look: "Stained Glass", collection: "Images"), .poster)
        XCTAssertEqual(TrueTrace.family(look: "Synthwave '80s", collection: "Images"), .neon)
        XCTAssertEqual(TrueTrace.family(look: "Blueprint Technical Drawing", collection: "Images"), .blueprint)
        XCTAssertEqual(TrueTrace.family(look: "Cel-Shaded 3D", collection: "3D"), .anime)
        XCTAssertEqual(TrueTrace.family(look: "Donghua 2D", collection: "Donghua"), .anime)
    }

    func testThreeDAndPhotoLooksAreNotDrawable() {
        for look in ["Photorealistic CGI", "Claymation", "Photorealistic", "Cinematic Photography", "Marble Statue",
                     "Donghua 3D Cultivation", "Stop-Motion Puppet"] {
            XCTAssertNil(TrueTrace.family(look: look, collection: "3D"), look)
        }
    }

    func testEveryRecipeIsValidJSONForTheScript() throws {
        for family in TrueTrace.Family.allCases {
            let r = TrueTrace.recipe(family)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(r), family.rawValue)
            XCTAssertNotNil(r["colors"], family.rawValue)
            XCTAssertNotNil(r["ink"], family.rawValue)
        }
    }

    /// The built-in script must match Tools/true-trace (run scripts/sync-true-trace.py after editing them).
    func testBuiltInScriptMatchesTheTools() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let core = try String(contentsOf: root.appendingPathComponent("Tools/true-trace/core.py"), encoding: .utf8)
        let build = try String(contentsOf: root.appendingPathComponent("Tools/true-trace/build.py"), encoding: .utf8)
        XCTAssertTrue(TrueTrace.script.contains("def trace(rgb, r):"))
        XCTAssertTrue(core.contains("def trace(rgb, r):"))
        XCTAssertTrue(TrueTrace.script.hasSuffix(build.trimmingCharacters(in: .newlines)),
                      "Run: python3 scripts/sync-true-trace.py")
    }
}

final class Sculpt3DTests: XCTestCase {
    func testThreeDLooksMapToFinishes() {
        XCTAssertEqual(Sculpt3D.finish(look: "Claymation"), .clay)
        XCTAssertEqual(Sculpt3D.finish(look: "Architectural Clay Render"), .whiteClay)
        XCTAssertEqual(Sculpt3D.finish(look: "Designer Vinyl Toy"), .vinyl)
        XCTAssertEqual(Sculpt3D.finish(look: "Marble Statue"), .marble)
        XCTAssertEqual(Sculpt3D.finish(look: "Glass and Crystal 3D"), .glass)
        XCTAssertEqual(Sculpt3D.finish(look: "Photorealistic CGI"), .cgi)
        XCTAssertEqual(Sculpt3D.finish(look: "Low-Poly 3D"), .lowPoly)
        XCTAssertEqual(Sculpt3D.finish(look: "Donghua 3D Cultivation"), .cgi)
    }

    func testTwoDAndPhotoLooksAreNotSculpted() {
        for look in ["Anime", "Watercolor Storybook", "Photorealistic", "Polaroid Instant", "Cel-Shaded 3D"] {
            XCTAssertNil(Sculpt3D.finish(look: look), look)
        }
    }

    func testEveryRecipeIsValidJSONForTheScript() {
        for finish in Sculpt3D.Finish.allCases {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(Sculpt3D.recipe(finish)), finish.rawValue)
        }
        XCTAssertTrue(Sculpt3D.script.contains("def height_field("))
    }
}
