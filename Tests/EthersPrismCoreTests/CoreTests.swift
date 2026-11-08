import XCTest
@testable import EthersPrismCore

/// Deterministic random numbers for tests.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class DialTests: XCTestCase {
    func testValuesAreClampedOnCreateAndEdit() {
        var d = Dial(name: "x", lowPole: "a", highPole: "b", value: 140)
        XCTAssertEqual(d.value, 100)
        d.value = -20
        XCTAssertEqual(d.value, 0)
        d.value = .nan
        XCTAssertEqual(d.value, 50)
    }

    func testValidationFindsProblems() {
        let a = Dial(name: "Tone", lowPole: "dry", highPole: "warm")
        let blank = Dial(name: " ", lowPole: "", highPole: "x")
        let dupName = Dial(name: "tone", lowPole: "a", highPole: "b")
        let issues = DialRules.issues(in: [a, blank, dupName, a])
        XCTAssertTrue(issues.contains(.emptyName(blank.id)))
        XCTAssertTrue(issues.contains(.emptyPole(blank.id)))
        XCTAssertTrue(issues.contains(.duplicateName("tone")))
        XCTAssertTrue(issues.contains(.duplicateID(a.id)))
        XCTAssertTrue(DialRules.issues(in: [a]).isEmpty)
    }

    func testEditingAddMoveRemove() {
        var s = Session(goal: "g")
        let a = Dial(name: "A", lowPole: "0", highPole: "1")
        let b = Dial(name: "B", lowPole: "0", highPole: "1")
        let c = Dial(name: "C", lowPole: "0", highPole: "1")
        s.addDial(a); s.addDial(b); s.addDial(c)
        s.moveDial(c.id, by: -2)
        XCTAssertEqual(s.dials.map(\.name), ["C", "A", "B"])
        s.moveDial(c.id, by: 10)
        XCTAssertEqual(s.dials.map(\.name), ["A", "B", "C"])
        var renamed = b
        renamed.name = "Bee"
        s.updateDial(renamed)
        s.removeDial(a.id)
        XCTAssertEqual(s.dials.map(\.name), ["Bee", "C"])
    }

    func testOldFilesWithoutNewFieldsStillDecode() throws {
        let json = #"{"id":"6F1A2B3C-0001-4E50-9A10-000000000009","name":"Pace","lowPole":"slow","highPole":"fast","value":200}"#
        let d = try JSONDecoder().decode(Dial.self, from: Data(json.utf8))
        XCTAssertEqual(d.detail, "")
        XCTAssertFalse(d.locked)
        XCTAssertEqual(d.value, 100)
    }
}

final class LockAndSweepTests: XCTestCase {
    private func session() -> Session {
        var s = Session(goal: "Explain annealing")
        s.dials = [Dial(name: "Detail", lowPole: "sparse", highPole: "rich", value: 40),
                   Dial(name: "Tone", lowPole: "serious", highPole: "playful", value: 60, locked: true),
                   Dial(name: "History", lowPole: "none", highPole: "lots", value: 20)]
        s.constraints = [Constraint(kind: .accuracy, text: "Be accurate")]
        return s
    }

    func testLockedDialsNeverMoveDuringExploration() {
        var s = session()
        var rng = SeededRNG(state: 42)
        for _ in 0..<50 { s.nudgeUnlocked(spread: 30, using: &rng) }
        XCTAssertEqual(s.dials[1].value, 60)
        XCTAssertNotEqual(s.dials[0].value, 40, "unlocked dials should move")
    }

    func testSweepChangesOnlyOneDial() throws {
        let s = session()
        let variants = try Sweep.variants(of: s.workingState, dialID: s.dials[0].id)
        XCTAssertEqual(variants.map(\.value), [0, 25, 50, 75, 100])
        for v in variants {
            XCTAssertEqual(v.state.dials[0].value, v.value)
            XCTAssertEqual(v.state.dials[1], s.dials[1])
            XCTAssertEqual(v.state.dials[2], s.dials[2])
            XCTAssertEqual(v.state.constraints, s.constraints)
            XCTAssertEqual(v.state.goal, s.goal)
        }
    }

    func testLockedDialMustBeUnlockedBeforeSweep() {
        let s = session()
        XCTAssertThrowsError(try Sweep.variants(of: s.workingState, dialID: s.dials[1].id)) {
            XCTAssertEqual($0 as? PrismError, .dialLocked)
        }
        XCTAssertThrowsError(try Sweep.variants(of: s.workingState, dialID: UUID()))
    }
}

final class HistoryTests: XCTestCase {
    private func out(_ t: String) -> Output { Output(kind: .text, text: t, provider: "Mock", model: "mock") }

    func testBranchingAndRestoringKeepsAllBranches() {
        var s = Session(goal: "g")
        s.dials = [Dial(name: "Detail", lowPole: "a", highPole: "b", value: 10)]
        let a = s.record(out("A"), origin: .preview)
        s.dials[0].value = 60
        let b = s.record(out("B"), origin: .preview)
        XCTAssertEqual(b.parentID, a.id)

        s.restore(a.id)
        XCTAssertEqual(s.dials[0].value, 10)
        XCTAssertEqual(s.currentSnapshotID, a.id)

        s.dials[0].value = 90
        let c = s.record(out("C"), origin: .render)
        XCTAssertEqual(c.parentID, a.id)
        XCTAssertEqual(s.snapshots.count, 3, "branching never deletes")
        XCTAssertEqual(s.path(to: c.id).map(\.output.text), ["A", "C"])
        XCTAssertEqual(s.treeRows().map(\.depth), [0, 0, 1])
        XCTAssertEqual(s.summary(for: c), "Detail 10→90")
        XCTAssertEqual(s.summary(for: a), "start")
    }

    func testRecordUsesStateFromRequestTimeWithoutMovingLiveDials() {
        var s = Session(goal: "g")
        s.dials = [Dial(name: "D", lowPole: "a", highPole: "b", value: 10)]
        let requested = s.workingState
        s.dials[0].value = 70
        let snap = s.record(out("x"), origin: .preview, state: requested)
        XCTAssertEqual(snap.state.dials[0].value, 10)
        XCTAssertEqual(s.dials[0].value, 70)
    }

    func testManualEditsBecomeTheirOwnState() {
        var s = Session(goal: "g")
        let a = s.record(out("draft"), origin: .preview)
        let edit = s.recordManualEdit(text: "my words")
        XCTAssertEqual(edit?.parentID, a.id)
        XCTAssertEqual(edit?.origin, .manualEdit)
        XCTAssertEqual(s.snapshot(a.id)?.output.text, "draft", "the generated version is kept")
        XCTAssertNil(s.recordManualEdit(text: "my words"), "no state when nothing changed")
        s.record(out("regenerated"), origin: .preview)
        XCTAssertEqual(s.snapshot(edit!.id)?.output.text, "my words", "regeneration never overwrites an edit")
    }

    func testDiffsCoverGoalDialsAndConstraints() {
        let d = Dial(name: "Detail", lowPole: "a", highPole: "b", value: 10)
        var d2 = d
        d2.value = 40
        let a = WorkingState(goal: "one", domainID: "text", dials: [d], constraints: [])
        let b = WorkingState(goal: "two", domainID: "text", dials: [d2],
                             constraints: [Constraint(kind: .mustAvoid, text: "jargon")])
        let c = StateDiff.changes(from: a, to: b)
        XCTAssertTrue(c.contains("goal changed"))
        XCTAssertTrue(c.contains("Detail 10→40"))
        XCTAssertTrue(c.contains("+ Must avoid: jargon"))
    }

    func testSameStateDetectionIgnoresLocks() {
        var d = Dial(name: "D", lowPole: "a", highPole: "b", value: 33)
        let a = WorkingState(goal: "g", domainID: "text", dials: [d], constraints: [])
        d.locked = true
        let b = WorkingState(goal: "g ", domainID: "text", dials: [d], constraints: [])
        XCTAssertTrue(a.generatesSame(as: b))
    }
}

final class CompileTests: XCTestCase {
    private func state() -> WorkingState {
        WorkingState(goal: "Explain annealing", domainID: "text",
                     dials: [Dial(name: "Detail", detail: "how much", lowPole: "sparse", highPole: "rich", value: 80)],
                     constraints: [Constraint(kind: .accuracy, text: "No invented facts"),
                                   Constraint(kind: .mustInclude, text: "a furnace", isActive: false)])
    }

    func testCompileIsDeterministicIncludingAfterSaveLoad() throws {
        var s = Session(goal: "x")
        s.workingState = state()
        s.record(Output(kind: .text, text: "t", provider: "Mock", model: "mock"), origin: .preview)
        let saved = s.currentSnapshot!.state
        let first = Domains.text.compile(CompileInput(state: saved, quality: .preview))

        let data = try Store.encoder().encode(s)
        let loaded = try Store.decodeSession(data)
        let second = Domains.text.compile(CompileInput(state: loaded.currentSnapshot!.state, quality: .preview))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.seed, second.seed)
    }

    func testCompileIncludesDialsActiveConstraintsAndQuality() {
        let p = Domains.text.compile(CompileInput(state: state(), quality: .preview))
        let r = Domains.text.compile(CompileInput(state: state(), quality: .render))
        XCTAssertTrue(p.text.user.contains("Explain annealing"))
        XCTAssertTrue(p.text.user.contains("Detail (how much): 80/100"))
        XCTAssertTrue(p.text.user.contains("Accuracy: No invented facts"))
        XCTAssertFalse(p.text.user.contains("furnace"), "inactive constraints are left out")
        XCTAssertTrue(p.text.user.contains("QUICK PREVIEW"))
        XCTAssertTrue(r.text.user.contains("FULL RENDER"))
        XCTAssertLessThan(p.text.maxTokens, r.text.maxTokens)
    }

    func testEveryAdapterCompilesAndUnfinishedOnesAreLabeled() {
        XCTAssertEqual(Set(Domains.all.map(\.id)).count, Domains.all.count)
        for a in Domains.all {
            let r = a.compile(CompileInput(state: state(), quality: .preview))
            XCTAssertFalse(r.text.system.isEmpty)
        }
        XCTAssertTrue(Domains.adapter(for: "text").status.isReady)
        XCTAssertTrue(Domains.adapter(for: "image").status.isReady)
        for id in ["video", "music", "code", "research"] {
            XCTAssertNotNil(Domains.adapter(for: id).status.note, "\(id) must be marked unfinished")
        }
    }

    func testDialSuggestionParsing() throws {
        let raw = "Here:\n```json\n[{\"name\":\"Pace\",\"description\":\"speed\",\"low\":\"slow\",\"high\":\"fast\"},{\"name\":\"Humor\",\"low\":\"dry\",\"high\":\"silly\"}]\n```"
        let dials = try DialSuggester.parse(raw)
        XCTAssertEqual(dials.map(\.name), ["Pace", "Humor"])
        XCTAssertEqual(dials[0].detail, "speed")
        XCTAssertThrowsError(try DialSuggester.parse("nothing"))
        XCTAssertThrowsError(try DialSuggester.parse(#"[{"name":"","low":"a","high":"b"}]"#))
    }

    func testImagePromptParsingAndCleaning() {
        let p = ImageAdapter.parsePrompt("Sure: {\"prompt\": \"a tiger of stars\", \"negative\": \"text\"}")
        XCTAssertEqual(p.prompt, "a tiger of stars")
        XCTAssertEqual(p.negative, "text")
        XCTAssertEqual(ImageAdapter.parsePrompt("just words").prompt, "just words")
        XCTAssertEqual(OutputCleaner.clean("x ```svg\n<svg a><g/></svg>\n```", kind: .image), "<svg a><g/></svg>")
        XCTAssertEqual(OutputCleaner.clean("```swift\nlet a = 1\n```", kind: .code), "let a = 1")
        XCTAssertEqual(Storyboard.parse("## One\nA\n## Two\nB").map(\.title), ["One", "Two"])
    }
}

final class GateTests: XCTestCase {
    func testOnlyTheNewestRequestMayUpdate() {
        let gate = GenerationGate()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertFalse(gate.isCurrent(first), "a slow older response must be ignored")
        XCTAssertTrue(gate.isCurrent(second))
        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(second))
    }
}

final class StorageTests: XCTestCase {
    private func tempStore() -> Store {
        Store(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func testSaveLoadRoundTripWithAsset() throws {
        let store = tempStore()
        var s = Session(goal: "tiger", domainID: "image")
        s.dials = [Dial(name: "Realism", lowPole: "a", highPole: "b", value: 42)]
        let rel = try store.saveAsset(Data("png".utf8), ext: "png", sessionID: s.id, name: "one")
        s.record(Output(kind: .image, assetPath: rel, provider: "Mock", model: "mock"), origin: .preview)
        try store.save(s)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].dials[0].value, 42)
        XCTAssertEqual(loaded[0].currentSnapshotID, s.currentSnapshotID)
        XCTAssertEqual(try Data(contentsOf: store.assetURL(loaded[0].currentSnapshot?.output.assetPath)!), Data("png".utf8))

        store.delete(s.id)
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testImportedPathsCannotEscapeTheStore() throws {
        XCTAssertTrue(Store.isSafeRelative("Assets/abc/one.png"))
        for bad in ["/etc/passwd", "../x.png", "Assets/../../x", "Assets/a/../../b", "~/x", "Assets//x", "Sessions/a/b", "Assets/a\\b/c"] {
            XCTAssertFalse(Store.isSafeRelative(bad), bad)
        }
        let store = tempStore()
        XCTAssertNil(store.assetURL("Assets/../../secret"))

        var s = Session(goal: "g")
        s.record(Output(kind: .image, assetPath: "../../etc/passwd", provider: "x", model: "y"), origin: .preview)
        let file = store.root.appendingPathComponent("import.json")
        try store.exportData(s).write(to: file)
        let imported = try store.importSession(from: file)
        XCTAssertNil(imported.currentSnapshot?.output.assetPath, "unsafe paths are dropped on import")

        let again = try store.importSession(from: file)
        XCTAssertNotEqual(again.id, imported.id, "importing twice never overwrites")
    }

    func testRejectsNewerVersionsAndJunk() throws {
        var s = Session(goal: "g")
        s.schemaVersion = 99
        XCTAssertThrowsError(try Store.decodeSession(try Store.encoder().encode(s))) {
            XCTAssertEqual($0 as? PrismError, .unsupportedVersion(99))
        }
        XCTAssertThrowsError(try Store.decodeSession(Data("hello".utf8)))
    }

    func testTemplatesSeedOnceAndMakeFreshSessions() throws {
        let store = tempStore()
        let templates = store.loadTemplates()
        XCTAssertEqual(Set(templates.map(\.name)),
                       ["Clear Writing", "Visual Character Exploration", "Learning Through Explanation"])
        store.deleteTemplate(templates[0].id)
        XCTAssertEqual(store.loadTemplates().count, 2, "deleted examples are not re-seeded")

        var source = Session(goal: "old goal")
        source.dials = [Dial(name: "Warmth", lowPole: "cool", highPole: "warm", value: 80, locked: true)]
        source.record(Output(kind: .text, text: "old", provider: "m", model: "m"), origin: .preview)
        let t = EditorTemplate.from(source, name: "Mine", summary: "")
        try store.saveTemplate(t)

        let fresh = t.makeSession(goal: "new goal")
        XCTAssertEqual(fresh.goal, "new goal")
        XCTAssertTrue(fresh.snapshots.isEmpty, "no history is copied")
        XCTAssertEqual(fresh.dials[0].value, 80)
        XCTAssertNotEqual(fresh.dials[0].id, source.dials[0].id)
        XCTAssertEqual(fresh.templateID, t.id)
    }
}

final class ExportTests: XCTestCase {
    func testAuthorshipLogRecordsTheProcess() {
        var s = Session(goal: "Explain annealing")
        s.dials = [Dial(name: "Detail", lowPole: "a", highPole: "b", value: 10)]
        s.constraints = [Constraint(kind: .accuracy, text: "No invented facts")]
        s.record(Output(kind: .text, text: "draft", provider: "Anthropic", model: "claude-x"), origin: .preview)
        s.dials[0].value = 70
        s.record(Output(kind: .text, text: "final", provider: "Anthropic", model: "claude-x"), origin: .render)
        s.recordManualEdit(text: "final, edited")
        s.toggleChosen(s.currentSnapshotID!)

        let log = Exporter.authorshipLog(s, adapterName: "Text")
        XCTAssertTrue(log.contains("Explain annealing"))
        XCTAssertTrue(log.contains("Accuracy: No invented facts"))
        XCTAssertTrue(log.contains("Detail 10→70"))
        XCTAssertTrue(log.contains("Values: Detail 70"))
        XCTAssertTrue(log.contains("Manual edits on the selected branch:** 1"))
        XCTAssertTrue(log.contains("claude-x"))
        XCTAssertTrue(log.contains("final, edited"))
        XCTAssertTrue(log.contains("no legal claim"))
    }
}

final class ProviderTests: XCTestCase {
    func testMockTextAndImageWorkflowsEndToEnd() async throws {
        let providers = ProviderSet(text: MockTextProvider(), image: MockImageProvider())
        let dials = try await Domains.text.suggestDials(for: "a celestial tiger", using: providers)
        XCTAssertGreaterThanOrEqual(dials.count, 4)

        let state = WorkingState(goal: "a celestial tiger", domainID: "image", dials: dials,
                                 constraints: [Constraint(kind: .mustAvoid, text: "watermarks")])
        let image = ImageAdapter()
        let gen = try await image.generate(image.compile(CompileInput(state: state, quality: .preview)), using: providers)
        XCTAssertEqual(gen.output.kind, .image)
        XCTAssertEqual(gen.assetExtension, "svg")
        XCTAssertNotNil(gen.output.imagePrompt)

        let text = try await Domains.text.generate(
            Domains.text.compile(CompileInput(state: state, quality: .render)), using: providers)
        XCTAssertTrue(text.output.text?.contains("MOCK") ?? false)
    }

    func testMissingConfigurationGivesClearErrors() async {
        do {
            _ = try await AnthropicTextProvider(apiKey: " ", model: "m").complete(TextRequest(system: "s", user: "u", maxTokens: 5))
            XCTFail()
        } catch { XCTAssertEqual(error as? PrismError, .missingAPIKey) }

        let state = WorkingState(goal: "g", domainID: "image", dials: [], constraints: [])
        let image = ImageAdapter()
        do {
            _ = try await image.generate(image.compile(CompileInput(state: state, quality: .preview)),
                                         using: ProviderSet(text: MockTextProvider(), image: nil))
            XCTFail()
        } catch { XCTAssertEqual(error as? PrismError, .missingImageProvider) }

        do {
            _ = try await ComfyUIImageProvider(settings: ComfyUISettings(checkpoint: ""))
                .generate(ImageJob(prompt: "p", negative: "", quality: .preview, seed: 1))
            XCTFail()
        } catch {
            guard case .comfy = error as? PrismError else { return XCTFail("\(error)") }
        }
    }

    func testComfyWorkflowUsesPreviewAndRenderSettings() {
        let settings = ComfyUISettings(checkpoint: "model.safetensors", previewSize: 512, previewSteps: 8,
                                       renderSize: 1024, renderSteps: 30)
        let job = ImageJob(prompt: "p", negative: "n", quality: .preview, seed: 7)
        let preview = ComfyUIImageProvider.workflow(for: job, settings: settings)
        var renderJob = job
        renderJob.quality = .render
        let render = ComfyUIImageProvider.workflow(for: renderJob, settings: settings)
        func inputs(_ g: [String: Any], _ id: String) -> [String: Any] {
            (g[id] as? [String: Any])?["inputs"] as? [String: Any] ?? [:]
        }
        XCTAssertEqual(inputs(preview, "3")["steps"] as? Int, 8)
        XCTAssertEqual(inputs(render, "3")["steps"] as? Int, 30)
        XCTAssertEqual(inputs(preview, "5")["width"] as? Int, 512)
        XCTAssertEqual(inputs(render, "5")["width"] as? Int, 1024)
        XCTAssertEqual(inputs(preview, "4")["ckpt_name"] as? String, "model.safetensors")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(preview))
    }
}
