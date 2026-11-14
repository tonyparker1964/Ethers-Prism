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

final class ChooseYourLookFieldTests: XCTestCase {
    func testLookLineIsReadFromTheGoal() {
        XCTAssertEqual(Sculpt3D.lookName(in: "/tmp/cub.glb\n\nLook: Claymation — Soft modelling clay."), "Claymation")
        XCTAssertNil(Sculpt3D.lookName(in: "/tmp/cub.glb"))
    }

    func testThreeDStageGetsTheFinishAndStillFindsTheModel() {
        let goal = "/tmp/cub.glb\n\nLook: Marble Statue — Carved stone."
        XCTAssertEqual(BlenderStageAdapter.modelPath(from: goal), "/tmp/cub.glb")
        let state = WorkingState(goal: goal, domainID: "stage", dials: [], constraints: [])
        let p = BlenderStageAdapter.parameters(CompileInput(state: state, quality: .preview))
        XCTAssertEqual((p["finish"] as? [String: Any])?["pattern"] as? String, "marble")
        let plain = WorkingState(goal: "/tmp/cub.glb", domainID: "stage", dials: [], constraints: [])
        XCTAssertNil(BlenderStageAdapter.parameters(CompileInput(state: plain, quality: .preview))["finish"])
    }
}

final class LookRecipeTests: XCTestCase {
    private func look(_ name: String, _ description: String) -> TrueTrace.Look {
        TrueTrace.Look(name: name, description: description, collection: "Anime", samplePath: "/tmp/sheet.webp", cols: 5, rows: 5, tile: 3)
    }

    func testDescriptionsGiveEachAnimeLookItsOwnLinesAndShading() throws {
        let showa = TrueTrace.recipe(.anime, look: look("Showa-era", "Thick ink lines, flat cel colors, simple shading, film grain."))
        let shojo = TrueTrace.recipe(.anime, look: look("Shōjo", "Large luminous eyes, sparkles, soft pastels, delicate linework."))
        let showaInk = try XCTUnwrap(showa["ink_w"] as? Double), shojoInk = try XCTUnwrap(shojo["ink_w"] as? Double)
        XCTAssertGreaterThan(showaInk, shojoInk * 2, "thick ink vs delicate linework")
        XCTAssertEqual(showa["cel_levels"] as? Int, 2)
        XCTAssertGreaterThan(try XCTUnwrap(shojo["cel_levels"] as? Int), 5)
        XCTAssertLessThan(try XCTUnwrap(shojo["saturation"] as? Double), 1.0)
        XCTAssertEqual(showa["boil"] as? Double, 0.25)
    }

    func testTheSampleSetsTheColoursExceptForMonochromeFamilies() {
        let anime = TrueTrace.recipe(.anime, look: look("City-pop retro", "1980s pastel neon, sunset gradients."))
        XCTAssertEqual((anime["look_sample"] as? [String: Any])?["tile"] as? Int, 3)
        XCTAssertNil(TrueTrace.recipe(.ink, look: look("Manga", "Monochrome linework"))["look_sample"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(anime))
    }

    func testNoLookKeepsTheFamilyRecipe() {
        XCTAssertNil(TrueTrace.recipe(.anime, look: nil)["look_sample"])
    }
}

final class DetailSliderTests: XCTestCase {
    func testDetailMovesColoursShapesAndLines() throws {
        let low = TrueTrace.recipe(.anime, look: nil, detail: 0.2)
        let mid = TrueTrace.recipe(.anime, look: nil, detail: 0.6)
        let high = TrueTrace.recipe(.anime, look: nil, detail: 0.95)
        let c = { (r: [String: Any]) in r["colors"] as? Int ?? 0 }
        XCTAssertLessThan(c(low), c(mid)); XCTAssertLessThan(c(mid), c(high))
        XCTAssertEqual(c(mid), TrueTrace.recipe(.anime)["colors"] as? Int, "60% leaves the look as designed")
        XCTAssertGreaterThan(try XCTUnwrap(low["min_area"] as? Double), try XCTUnwrap(high["min_area"] as? Double))
        XCTAssertGreaterThan(try XCTUnwrap(low["ink_threshold"] as? Double), try XCTUnwrap(high["ink_threshold"] as? Double))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(low))
    }
}
