import XCTest
@testable import EthersPrismCore

final class CoreTests: XCTestCase {
    private func dial(_ v: Double) -> Dial {
        Dial(name: "Detail", lowPole: "sparse", highPole: "rich", value: v)
    }

    func testDescribeEndsAndMiddle() {
        XCTAssertTrue(Compiler.describe(dial(0)).contains("fully at \"sparse\""))
        XCTAssertTrue(Compiler.describe(dial(50)).contains("balanced"))
        XCTAssertTrue(Compiler.describe(dial(80)).contains("strongly toward \"rich\""))
        XCTAssertTrue(Compiler.describe(dial(100)).contains("fully at \"rich\""))
    }

    func testAxisValueIsClamped() {
        XCTAssertEqual(Dial(name: "x", lowPole: "a", highPole: "b", value: 140).value, 100)
        XCTAssertEqual(Dial(name: "x", lowPole: "a", highPole: "b", value: -5).value, 0)
    }

    func testCompileIncludesGoalDialsAndQuality() {
        let preview = Domains.text.compile(goal: "Explain annealing", axes: [dial(20)], quality: .preview)
        let render = Domains.text.compile(goal: "Explain annealing", axes: [dial(20)], quality: .render)
        XCTAssertTrue(preview.user.contains("Explain annealing"))
        XCTAssertTrue(preview.user.contains("Detail: 20/100"))
        XCTAssertTrue(preview.user.contains("QUICK PREVIEW"))
        XCTAssertTrue(render.user.contains("FULL RENDER"))
        XCTAssertLessThan(preview.maxTokens, render.maxTokens)
    }

    func testEveryDomainCompiles() {
        XCTAssertEqual(Set(Domains.all.map(\.id)).count, Domains.all.count, "domain ids must be unique")
        for adapter in Domains.all {
            let r = adapter.compile(goal: "g", axes: [dial(50)], quality: .preview)
            XCTAssertFalse(r.system.isEmpty)
            XCTAssertGreaterThan(r.maxTokens, 0)
        }
        XCTAssertEqual(Domains.adapter(for: "nope").id, "text")
    }

    func testAxisParsingToleratesProse() throws {
        let text = """
        Sure! Here are the dials:
        ```json
        [{"name":"Pace","low":"slow","high":"fast"},{"name":"Humor","low":"serious","high":"playful"}]
        ```
        Enjoy.
        """
        let axes = try AxisSuggester.parse(text)
        XCTAssertEqual(axes.count, 2)
        XCTAssertEqual(axes[0].name, "Pace")
        XCTAssertEqual(axes[1].highPole, "playful")
        XCTAssertEqual(axes[0].value, 50)
    }

    func testAxisParsingRejectsGarbage() {
        XCTAssertThrowsError(try AxisSuggester.parse("no json here"))
        XCTAssertThrowsError(try AxisSuggester.parse("[]"))
    }

    func testHistoryBranching() {
        var s = Session(goal: "g", axes: [dial(10)])
        let a = s.record(output: "A", quality: .preview)
        s.axes[0].value = 60
        let b = s.record(output: "B", quality: .preview)
        XCTAssertEqual(b.parentID, a.id)

        s.restore(a.id)
        XCTAssertEqual(s.axes[0].value, 10)
        XCTAssertEqual(s.currentSnapshotID, a.id)

        s.axes[0].value = 90
        let c = s.record(output: "C", quality: .render)
        XCTAssertEqual(c.parentID, a.id)
        XCTAssertEqual(s.children(of: a.id).count, 2)
        XCTAssertEqual(s.path(to: c.id).map(\.output), ["A", "C"])

        let rows = s.treeRows()
        XCTAssertEqual(rows.map(\.snapshot.output), ["A", "B", "C"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1])
        XCTAssertEqual(s.summary(for: a), "start")
        XCTAssertEqual(s.summary(for: c), "Detail 10→90")
    }

    func testRecordUsesDialsFromRequestTime() {
        var s = Session(goal: "g", axes: [dial(10)])
        let used = s.axes
        s.axes[0].value = 70 // moved while the request was in flight
        let snap = s.record(output: "x", quality: .preview, axes: used)
        XCTAssertEqual(snap.axes[0].value, 10)
        XCTAssertEqual(s.axes[0].value, 70, "recording must not snap the live dials back")
    }

    func testChangesDetectsAddRemoveRename() {
        let a = dial(10)
        var renamed = a
        renamed.name = "Richness"
        let added = Dial(name: "Tone", lowPole: "dry", highPole: "warm")
        let diffs = Session.changes(from: [a], to: [renamed, added])
        XCTAssertTrue(diffs.contains("renamed Detail→Richness"))
        XCTAssertTrue(diffs.contains("+ Tone"))
        XCTAssertEqual(Session.changes(from: [a], to: []), ["− Detail"])
    }

    func testChosenToggle() {
        var s = Session(goal: "g")
        let a = s.record(output: "A", quality: .preview)
        s.toggleChosen(a.id)
        XCTAssertTrue(s.snapshot(a.id)!.chosen)
    }

    func testSVGExtraction() {
        let raw = "Here you go:\n```svg\n<svg viewBox=\"0 0 10 10\"><rect/></svg>\n```"
        XCTAssertEqual(OutputCleaner.clean(raw, kind: .svg), "<svg viewBox=\"0 0 10 10\"><rect/></svg>")
    }

    func testFenceStripping() {
        XCTAssertEqual(OutputCleaner.clean("```swift\nlet x = 1\n```", kind: .code), "let x = 1")
        XCTAssertEqual(OutputCleaner.clean("plain text", kind: .text), "plain text")
    }

    func testStoryboardParse() {
        let text = """
        ## Scene 1 — Heat (0:00–0:20)
        Visual: furnace
        Narration: hi
        ## Scene 2 — Cool (0:20–0:40)
        Visual: metal
        """
        let scenes = Storyboard.parse(text)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[1].title, "Scene 2 — Cool (0:20–0:40)")
        XCTAssertTrue(scenes[0].body.contains("furnace"))
        XCTAssertEqual(Storyboard.parse("just prose").count, 1)
    }

    func testExporterIncludesPathAndResult() {
        var s = Session(title: "Annealing", goal: "Explain annealing", axes: [dial(10)])
        s.record(output: "draft", quality: .preview)
        s.axes[0].value = 70
        s.record(output: "FINAL", quality: .render)
        let md = Exporter.authorshipLog(s, adapter: Domains.text)
        XCTAssertTrue(md.contains("Explain annealing"))
        XCTAssertTrue(md.contains("Path (2 steps)"))
        XCTAssertTrue(md.contains("Detail 10→70"))
        XCTAssertTrue(md.contains("FINAL"))
    }

    func testMockProviderRoundTrip() async throws {
        let mock = MockProvider()
        let json = try await mock.complete(AxisSuggester.request(goal: "x", adapter: Domains.music))
        XCTAssertEqual(try AxisSuggester.parse(json).count, 6)

        let svg = try await mock.complete(Domains.image.compile(goal: "x", axes: [dial(30)], quality: .preview))
        XCTAssertTrue(OutputCleaner.clean(svg, kind: .svg).hasPrefix("<svg"))

        let board = try await mock.complete(Domains.video.compile(goal: "x", axes: [dial(30)], quality: .preview))
        XCTAssertEqual(Storyboard.parse(board).count, 2)
    }

    func testAnthropicProviderRequiresKey() async {
        do {
            _ = try await AnthropicProvider(apiKey: "  ", model: "m").complete(
                CompiledRequest(system: "s", user: "u", maxTokens: 10))
            XCTFail("expected missing key error")
        } catch {
            XCTAssertEqual(error as? PrismError, .missingAPIKey)
        }
    }

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(directory: dir)
        var s = Session(goal: "g", axes: [dial(42)])
        s.record(output: "o", quality: .preview)
        try store.save(s)
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].axes[0].value, 42)
        XCTAssertEqual(loaded[0].snapshots.count, 1)
        XCTAssertEqual(loaded[0].currentSnapshotID, s.currentSnapshotID)
        store.delete(s.id)
        XCTAssertTrue(store.loadAll().isEmpty)
    }
}
