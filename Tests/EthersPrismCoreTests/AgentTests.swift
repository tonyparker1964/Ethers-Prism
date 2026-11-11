import XCTest
@testable import EthersPrismCore

/// A provider that records which agent was asked.
struct NamedProvider: TextProvider {
    let name: String
    let model = "test"
    let reply: String
    func complete(_ request: TextRequest) async throws -> String { reply }
}

/// Returns the system prompt it was sent.
struct EchoSystemProvider: TextProvider {
    let name = "echo"
    let model = "echo"
    func complete(_ request: TextRequest) async throws -> String { request.system }
}

final class AgentTests: XCTestCase {
    func testEachJobGoesToItsOwnAgent() async throws {
        let providers = ProviderSet(
            text: NamedProvider(name: "fallback", reply: "fallback text"),
            image: MockImageProvider(),
            agents: [
                .dialDesigner: NamedProvider(name: "designer", reply: #"[{"name":"A","low":"x","high":"y"},{"name":"B","low":"x","high":"y"}]"#),
                .writer: NamedProvider(name: "writer", reply: "written"),
                .coder: NamedProvider(name: "coder", reply: "let x = 1"),
                .artDirector: NamedProvider(name: "director", reply: #"{"prompt":"a tiger","negative":"text"}"#)
            ])
        let state = WorkingState(goal: "g", domainID: "text", dials: [], constraints: [])

        let dials = try await Domains.text.suggestDials(for: "g", using: providers)
        XCTAssertEqual(dials.map(\.name), ["A", "B"])

        let text = try await Domains.text.generate(Domains.text.compile(CompileInput(state: state, quality: .preview)), using: providers)
        XCTAssertEqual(text.output.text, "written")
        XCTAssertEqual(text.output.provider, "writer")
        XCTAssertEqual(text.output.agent, "Writer")

        let code = try await Domains.code.generate(Domains.code.compile(CompileInput(state: state, quality: .preview)), using: providers)
        XCTAssertEqual(code.output.provider, "coder")
        XCTAssertEqual(code.output.agent, "Coder")

        let image = ImageAdapter()
        let img = try await image.generate(image.compile(CompileInput(state: state, quality: .preview)), using: providers)
        XCTAssertEqual(img.output.imagePrompt, "a tiger")
        XCTAssertTrue(img.output.promptModel?.contains("director") ?? false)

        XCTAssertEqual(providers.text(for: .checker).name, "fallback", "roles without an agent fall back")
    }

    func testLargeModelDetection() {
        XCTAssertTrue(LocalMemory.isLarge("qwen3-coder-30b-a3b-instruct"))
        XCTAssertTrue(LocalMemory.isLarge("Llama-3.3-70B"))
        XCTAssertFalse(LocalMemory.isLarge("qwen/qwen3-8b"))
        XCTAssertFalse(LocalMemory.isLarge("claude-sonnet-5-5"))
        XCTAssertFalse(LocalMemory.isLarge("mock"))
    }

    func testFindsLoadedLMStudioInstances() {
        let json: [String: Any] = ["models": [
            ["key": "qwen3-coder-30b-a3b-instruct", "loaded_instances": [["id": "qwen3-coder-30b-a3b-instruct"]]],
            ["key": "qwen/qwen3-8b", "loaded_instances": [["id": "qwen/qwen3-8b"], ["id": "qwen/qwen3-8b:2"]]],
            ["key": "nomic", "loaded_instances": [[String: Any]]()]
        ]]
        XCTAssertEqual(LocalMemory.loadedInstanceIDs(in: json),
                       ["qwen/qwen3-8b", "qwen/qwen3-8b:2", "qwen3-coder-30b-a3b-instruct"])
    }

    func testThinkingIsStripped() {
        XCTAssertEqual(OutputCleaner.stripThinking("<think>hmm\nmore</think>\n\nAnswer"), "Answer")
        XCTAssertEqual(OutputCleaner.stripThinking("<think>never closed"), "")
        XCTAssertEqual(try DialSuggester.parse("<think>[not this]</think>[{\"name\":\"A\",\"low\":\"x\",\"high\":\"y\"}]").count, 1)
        XCTAssertTrue(OpenAICompatibleTextProvider.wantsNoThink("qwen/qwen3-8b"))
        XCTAssertFalse(OpenAICompatibleTextProvider.wantsNoThink("qwen3-coder-30b-a3b-instruct"))
        XCTAssertEqual(OpenAICompatibleTextProvider.url("http://127.0.0.1:1234/v1/", "/v1/models")?.absoluteString,
                       "http://127.0.0.1:1234/v1/models")
    }

    func testCheckerOnlyRunsWithRequirementsAndParsesVerdicts() {
        let out = Output(kind: .text, text: "Hello", provider: "p", model: "m")
        XCTAssertNil(Checker.request(for: out, constraints: []))
        let req = Checker.request(for: out, constraints: [Constraint(kind: .mustAvoid, text: "jargon")])
        XCTAssertTrue(req?.user.contains("Must avoid: jargon") ?? false)

        let ok = Checker.parse(#"{"passes": true, "issues": []}"#, reviewer: "r")
        XCTAssertTrue(ok.passed)
        let bad = Checker.parse("<think>x</think> {\"passes\": false, \"issues\": [\"uses jargon\"]}", reviewer: "r")
        XCTAssertFalse(bad.passed)
        XCTAssertEqual(bad.issues, ["uses jargon"])
        XCTAssertFalse(Checker.parse("no idea", reviewer: "r").passed)
    }

    func testReviewIsStoredWithoutChangingTheResult() {
        var s = Session(goal: "g")
        let snap = s.record(Output(kind: .text, text: "draft", provider: "p", model: "m"), origin: .preview)
        s.setReview(Review(passed: false, issues: ["x"], reviewer: "Checker"), for: snap.id)
        XCTAssertEqual(s.snapshot(snap.id)?.output.text, "draft")
        XCTAssertEqual(s.snapshot(snap.id)?.output.review?.issues, ["x"])
        let edit = s.recordManualEdit(text: "mine")
        XCTAssertNil(edit?.output.review, "a hand edit hasn't been reviewed yet")
        XCTAssertEqual(edit?.output.agent, "You (hand edit)")
    }

    func testTeamDecodesOldOrPartialSettings() throws {
        let partial = #"{"assignments":[{"role":"writer","backend":"anthropic","model":"claude-x"}]}"#
        let team = try JSONDecoder().decode(AgentTeam.self, from: Data(partial.utf8))
        XCTAssertEqual(team.assignment(.writer).backend, .anthropic)
        XCTAssertEqual(team.assignment(.coder).model, AgentTeam.coderModel, "missing roles get local defaults")
        XCTAssertEqual(team.lmStudioURL, "http://127.0.0.1:1234")
        XCTAssertTrue(team.checkerEnabled)
    }

    func testSmallModelJSONSlipsAreRepaired() throws {
        // Real output from Qwen3 8B: one key without quotes, names in snake_case.
        let raw = "\n\n[\n {\"name\": \"visual_complexity\", \"detail\": \"d\", \"low\": \"a\", high: \"b\"},\n {\"name\": \"mood\", \"detail\": \"d\", \"low\": \"a\", \"high\": \"b\",}\n]"
        let dials = try DialSuggester.parse(raw)
        XCTAssertEqual(dials.map(\.name), ["Visual complexity", "Mood"])
        XCTAssertEqual(dials[0].highPole, "b")
        // Structured-output answers come wrapped in an object.
        XCTAssertEqual(try DialSuggester.parse(#"{"dials":[{"name":"Pace","detail":"","low":"slow","high":"fast"}]}"#).count, 1)
        XCTAssertEqual(ImageAdapter.parsePrompt(#"{prompt: "a tiger", negative: "text",}"#).prompt, "a tiger")
    }

    func testDataAnswersAskForASchema() throws {
        XCTAssertNotNil(DialSuggester.request(goal: "g", adapterName: "Text", hint: "").schema)
        XCTAssertNotNil(ImageAdapter().compile(CompileInput(state: WorkingState(goal: "g", domainID: "image", dials: [], constraints: []), quality: .preview)).text.schema)
        let out = Output(kind: .text, text: "x", provider: "p", model: "m")
        XCTAssertNotNil(Checker.request(for: out, constraints: [Constraint(kind: .accuracy, text: "true")])?.schema)
        for schema in [Schemas.dials, Schemas.imagePrompt, Schemas.review] {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(schema.utf8)))
        }
        XCTAssertNil(Domains.text.compile(CompileInput(state: WorkingState(goal: "g", domainID: "text", dials: [], constraints: []), quality: .preview)).text.schema,
                     "free-form writing is not forced into JSON")
    }

    func testServerErrorsBecomeReadable() {
        let body = Data(#"{"error":{"message":"No models loaded. Please load a model","type":"invalid_request_error"}}"#.utf8)
        let msg = OpenAICompatibleTextProvider.friendlyError(status: 400, data: body, server: "LM Studio", model: "qwen/qwen3-8b")
        XCTAssertTrue(msg.contains("can't find the model “qwen/qwen3-8b”"))
        XCTAssertFalse(msg.contains("{"))
    }

    func testBlenderStageMapsDialsDeterministically() async throws {
        let stage = BlenderStageAdapter()
        let dials = try await stage.suggestDials(for: "", using: ProviderSet(text: MockTextProvider(), image: nil))
        XCTAssertEqual(dials.count, 5)
        var state = WorkingState(goal: "~/Models/tiger.glb", domainID: "stage", dials: dials, constraints: [])
        state.dials[0].value = 50
        let a = stage.compile(CompileInput(state: state, quality: .preview))
        XCTAssertEqual(a, stage.compile(CompileInput(state: state, quality: .preview)))
        let p = BlenderStageAdapter.parameters(CompileInput(state: state, quality: .render))
        XCTAssertEqual(p["orbit"] as? Double, 0.5)
        XCTAssertTrue((p["model"] as? String)?.hasSuffix("/Models/tiger.glb") ?? false)
        XCTAssertNil(BlenderStageAdapter.modelPath(from: "a robot"), "no file means the sample model")
    }

    func testBlenderAnimationReadsSongImageAndDials() async throws {
        let anim = BlenderAnimationAdapter()
        XCTAssertEqual(Domains.adapter(for: "animate").capabilities.kind, .video)
        XCTAssertFalse(Domains.adapter(for: "animate").capabilities.needsVideoProvider, "Blender, not ComfyUI")
        let dials = try await anim.suggestDials(for: "", using: ProviderSet(text: MockTextProvider(), image: nil))
        XCTAssertEqual(dials.count, 6)

        let f = BlenderAnimationAdapter.files(in: "fiery planet\n~/Music/My Beat.wav\n/Volumes/Art/sun map.png")
        XCTAssertTrue(f.audio?.hasSuffix("/Music/My Beat.wav") ?? false, "paths with spaces work")
        XCTAssertFalse(f.audio?.hasPrefix("~") ?? true, "the home folder is expanded")
        XCTAssertEqual(f.texture, "/Volumes/Art/sun map.png")
        XCTAssertEqual(f.words, "fiery planet")
        let none = BlenderAnimationAdapter.files(in: "earth/fire planet")
        XCTAssertNil(none.audio)
        XCTAssertNil(none.texture)

        var state = WorkingState(goal: "~/Music/beat.mp3", domainID: "animate", dials: dials, constraints: [])
        state.dials[0].value = 100
        let a = anim.compile(CompileInput(state: state, quality: .preview))
        XCTAssertEqual(a, anim.compile(CompileInput(state: state, quality: .preview)))
        XCTAssertNotEqual(a.seed, anim.compile(CompileInput(state: state, quality: .render)).seed)
        let p = BlenderAnimationAdapter.parameters(CompileInput(state: state, quality: .render))
        XCTAssertEqual(p["spin"] as? Double, 1.0)
        XCTAssertEqual(p["beat"] as? Double, 0.6)
        XCTAssertEqual(p["texture"] as? String, "")
        XCTAssertTrue((p["audio"] as? String)?.hasSuffix("/Music/beat.mp3") ?? false)
    }

    func testTeachByExampleUsesOnlyStarsAndHandEdits() async throws {
        var s = Session(goal: "Announce the meetup")
        s.dials = [Dial(name: "Warmth", lowPole: "cool", highPole: "warm")]
        s.record(Output(kind: .text, text: "ignored draft", provider: "p", model: "m"), origin: .preview)
        let starred = s.record(Output(kind: .text, text: "starred draft", provider: "p", model: "m"), origin: .preview)
        s.toggleChosen(starred.id)
        s.recordManualEdit(text: "my own words")
        var img = Session(goal: "tiger", domainID: "image")
        let pic = img.record(Output(kind: .image, imagePrompt: "a tiger of stars", provider: "p", model: "m"), origin: .preview)
        img.toggleChosen(pic.id)

        let writer = try XCTUnwrap(TeachByExample.examples(for: .writer, in: [s, img]))
        XCTAssertTrue(writer.contains("my own words"))
        XCTAssertTrue(writer.contains("starred draft"))
        XCTAssertFalse(writer.contains("ignored draft"), "unstarred results are not examples")
        XCTAssertTrue(TeachByExample.examples(for: .artDirector, in: [s, img])?.contains("a tiger of stars") ?? false)
        XCTAssertTrue(TeachByExample.examples(for: .dialDesigner, in: [s, img])?.contains("Warmth: cool ↔ warm") ?? false)
        XCTAssertNil(TeachByExample.examples(for: .checker, in: [s, img]))
        XCTAssertNil(TeachByExample.examples(for: .coder, in: [s, img]))
        XCTAssertNil(TeachByExample.examples(for: .writer, in: []), "no history, no examples")

        let echo = EchoSystemProvider()
        let taught = ExampleTaughtTextProvider(inner: echo, examples: writer)
        let sent = try await taught.complete(TextRequest(system: "base", user: "u", maxTokens: 5))
        XCTAssertTrue(sent.hasPrefix("base"))
        XCTAssertTrue(sent.contains(TeachByExample.marker))
    }

    func testMCPTransportRoundTrip() async throws {
        // A stand-in MCP server: answers every request line with a fixed tool list, echoing the id.
        let script = """
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          [ -n "$id" ] && printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"mixar_render","description":"Render"}]}}\\n' "$id"
        done
        """
        let client = StdioMCPClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        try client.start()
        defer { client.stop() }
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertEqual(tools, [MCPTool(name: "mixar_render", description: "Render")])
    }
}

final class LineLogoTests: XCTestCase {
    func testLineLogoIsALocalVideoFieldWithItsOwnDials() async throws {
        let a = Domains.adapter(for: "linelogo")
        XCTAssertEqual(a.capabilities.kind, .video)
        XCTAssertFalse(a.capabilities.needsVideoProvider, "Blender, not ComfyUI")
        let dials = try await a.suggestDials(for: "", using: ProviderSet(text: MockTextProvider(), image: nil))
        XCTAssertEqual(dials.map(\.name), ["Draw speed", "Line weight", "Wobble", "Timing", "Glow", "Detail", "Ink", "Camera push", "Length"])
    }

    func testLineLogoReadsTheImageAndDials() {
        XCTAssertEqual(GreasePencilLogoAdapter.imagePath(from: "neon version\n/Volumes/Art/My Logo.PNG"), "/Volumes/Art/My Logo.PNG")
        XCTAssertNil(GreasePencilLogoAdapter.imagePath(from: "just words"))
        let dials = [Dial(name: "Glow", lowPole: "a", highPole: "b", value: 80),
                     Dial(name: "Camera push", lowPole: "a", highPole: "b", value: 0)]
        let state = WorkingState(goal: "", domainID: "linelogo", dials: dials, constraints: [])
        let p = GreasePencilLogoAdapter.parameters(CompileInput(state: state, quality: .preview))
        XCTAssertEqual(p["glow"] as? Double, 0.8)
        XCTAssertEqual(p["drift"] as? Double, 0)
        XCTAssertEqual(p["image"] as? String, GreasePencilLogoAdapter.defaultLogo, "empty goal uses the emblem")
        XCTAssertEqual(p["quality"] as? String, "preview")
        let r1 = GreasePencilLogoAdapter().compile(CompileInput(state: state, quality: .preview))
        let r2 = GreasePencilLogoAdapter().compile(CompileInput(state: state, quality: .preview))
        XCTAssertEqual(r1.seed, r2.seed, "same dials, same clip")
        XCTAssertTrue(GreasePencilLogoAdapter.script.contains("use_lights = False"))
    }
}

final class ModelFromImageTests: XCTestCase {
    func testModelFromImageIsALocalFieldWithItsDials() async throws {
        let a = Domains.adapter(for: "model3d")
        XCTAssertEqual(a.capabilities.kind, .image)
        XCTAssertFalse(a.capabilities.needsImageProvider, "Blender, not ComfyUI")
        let dials = try await a.suggestDials(for: "", using: ProviderSet(text: MockTextProvider(), image: nil))
        XCTAssertEqual(dials.map(\.name), ["Mode", "Depth", "Bevel", "Material", "Detail", "Color", "Light angle", "Camera angle"])
    }

    func testReadsPictureDialsAndModelPath() {
        let dials = [Dial(name: "Mode", lowPole: "relief", highPole: "extrude", value: 100),
                     Dial(name: "Material", lowPole: "metal", highPole: "neon", value: 50),
                     Dial(name: "Camera angle", lowPole: "a", highPole: "b", value: 0)]
        let state = WorkingState(goal: "/Users/me/Art/Fiery Tiger.png", domainID: "model3d", dials: dials, constraints: [])
        let p = ModelFromImageAdapter.parameters(CompileInput(state: state, quality: .render))
        XCTAssertEqual(p["mode"] as? Double, 1.0)
        XCTAssertEqual(p["material"] as? Double, 0.5)
        XCTAssertEqual(p["tilt"] as? Double, 0)
        XCTAssertEqual(p["image"] as? String, "/Users/me/Art/Fiery Tiger.png")
        XCTAssertEqual(ModelFromImageAdapter.modelPath(in: "Fiery Tiger.png as a 3D relief. Model: /Users/me/3D Models/Fiery Tiger relief 42.glb"),
                       "/Users/me/3D Models/Fiery Tiger relief 42.glb")
        XCTAssertNil(ModelFromImageAdapter.modelPath(in: "no model here"))
        XCTAssertTrue(ModelFromImageAdapter.script.contains("export_scene.gltf"))
    }
}

final class BlenderScriptTests: XCTestCase {
    func testRecognisesScriptsButNotProse() {
        XCTAssertTrue(BlenderScriptAdapter.looksLikeScript("# Title: Rings\nimport bpy, math\nbpy.ops.mesh.primitive_torus_add()"))
        XCTAssertTrue(BlenderScriptAdapter.looksLikeScript("from bpy import data"))
        XCTAssertFalse(BlenderScriptAdapter.looksLikeScript(BlenderScriptAdapter.claudeInstructions))
        XCTAssertFalse(BlenderScriptAdapter.looksLikeScript("Use bpy.data to read things"))
    }

    func testTakesCodeOutOfAClaudeReply() {
        let reply = "Here you go:\n\n```python\n# Title: Neon Rings\nimport bpy\nprint(1)\n```\n\nIt makes rings."
        let s = BlenderScriptAdapter.extractScript(reply)
        XCTAssertEqual(s, "# Title: Neon Rings\nimport bpy\nprint(1)\n")
        XCTAssertEqual(BlenderScriptAdapter.title(of: s), "Neon Rings")
        XCTAssertEqual(BlenderScriptAdapter.title(of: "import bpy\n"), "Blender script")
        XCTAssertEqual(BlenderScriptAdapter.title(of: "# Golden logo turning\nimport bpy"), "Golden logo turning")
    }

    func testRenderCallsAreSwitchedOff() {
        let s = BlenderScriptAdapter.sanitized("bpy.ops.render.render(animation=True)\nbpy.ops.wm.quit_blender()")
        XCTAssertFalse(s.contains("bpy.ops.render.render("))
        XCTAssertFalse(s.contains("quit_blender("))
    }

    func testSavesOnceToTheLibrary() throws {
        let old = BlenderScriptAdapter.libraryFolder
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prism-lib-\(UUID().uuidString)").path
        BlenderScriptAdapter.libraryFolder = dir
        defer { BlenderScriptAdapter.libraryFolder = old; try? FileManager.default.removeItem(atPath: dir) }
        let script = "# Title: Test/Scene\nimport bpy\n"
        let a = try BlenderScriptAdapter.saveToLibrary(script)
        let b = try BlenderScriptAdapter.saveToLibrary(script)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasSuffix("Test-Scene.py"))
        XCTAssertEqual(BlenderScriptAdapter.library(), [a])
    }

    func testFixedDials() async throws {
        let a = Domains.adapter(for: "blenderscript")
        let dials = try await a.suggestDials(for: "", using: ProviderSet(text: MockTextProvider(), image: nil))
        XCTAssertEqual(dials.map(\.name), ["Preview frame", "Render quality"])
    }
}
