import XCTest
@testable import EthersPrismCore

/// A provider that records which agent was asked.
struct NamedProvider: TextProvider {
    let name: String
    let model = "test"
    let reply: String
    func complete(_ request: TextRequest) async throws -> String { reply }
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
