import XCTest
@testable import EthersPrismCore

/// Claude and ChatGPT through your own accounts (Claude Code and Codex). No real tools are run here.
final class AccountTests: XCTestCase {
    func testBackendsMapToTheirTools() {
        XCTAssertEqual(AgentBackend.claudeAccount.account, .claude)
        XCTAssertEqual(AgentBackend.chatGPT.account, .codex)
        XCTAssertNil(AgentBackend.anthropic.account)
        XCTAssertFalse(AgentBackend.claudeAccount.needsModel, "an empty model means the account's default")
        XCTAssertFalse(AgentBackend.chatGPT.needsModel)
        XCTAssertTrue(AgentBackend.lmStudio.needsModel)
        XCTAssertFalse(AgentBackend.chatGPT.isLocal)
    }

    func testSavedTeamsWithAccountsDecode() throws {
        let json = #"{"assignments":[{"role":"writer","backend":"claudeAccount","model":""},{"role":"checker","backend":"chatGPT","model":""}]}"#
        let team = try JSONDecoder().decode(AgentTeam.self, from: Data(json.utf8))
        XCTAssertEqual(team.assignment(.writer).backend, .claudeAccount)
        XCTAssertEqual(team.assignment(.checker).backend, .chatGPT)
        XCTAssertEqual(AgentTeam.allAccount(.chatGPT).count, AgentRole.allCases.count)
        XCTAssertTrue(AgentTeam.allAccount(.claudeAccount).allSatisfy { $0.backend == .claudeAccount && $0.model.isEmpty })
    }

    func testClaudeCodeIsAskedForOneAnswerWithoutTools() {
        let args = AccountCLIs.claudeArguments(system: "SYS", model: "sonnet")
        XCTAssertEqual(args.first, "-p")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertEqual(args[args.firstIndex(of: "--append-system-prompt")! + 1], "SYS")
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "sonnet")
        XCTAssertFalse(AccountCLIs.claudeArguments(system: "S", model: " ").contains("--model"))
    }

    func testCodexReadsThePromptFromStdinReadOnly() {
        let args = AccountCLIs.codexArguments(outputFile: "/tmp/a.txt", model: "")
        XCTAssertEqual(args.first, "exec")
        XCTAssertEqual(args.last, "-")
        XCTAssertEqual(args[args.firstIndex(of: "--sandbox")! + 1], "read-only")
        XCTAssertFalse(args.contains("--model"))
    }

    func testReadsClaudeCodeReplies() {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"[{\"name\":\"Tone\"}]"}"#
        XCTAssertEqual(AccountCLIs.parseClaude(ok).0, #"[{"name":"Tone"}]"#)
        let list = #"[{"type":"system"},{"type":"result","is_error":false,"result":"hi"}]"#
        XCTAssertEqual(AccountCLIs.parseClaude(list).0, "hi")
        let bad = #"{"type":"result","is_error":true,"result":"Invalid API key · Please run /login"}"#
        XCTAssertNil(AccountCLIs.parseClaude(bad).0)
        XCTAssertTrue(AccountCLIs.friendly(.claude, AccountCLIs.parseClaude(bad).1!).contains("Sign In"))
    }

    func testReadsCodexEvents() {
        let out = """
        {"type":"thread.started"}
        {"type":"item.completed","item":{"type":"reasoning","text":"thinking"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"{\\"passes\\": true, \\"issues\\": []}"}}
        """
        XCTAssertEqual(AccountCLIs.parseCodexEvents(out).0, #"{"passes": true, "issues": []}"#)
        let failed = #"{"type":"turn.failed","error":{"message":"You've hit your usage limit"}}"#
        XCTAssertEqual(AccountCLIs.parseCodexEvents(failed).1, "You've hit your usage limit")
        XCTAssertTrue(AccountCLIs.friendly(.codex, "You've hit your usage limit").contains("usage limit is reached"))
    }

    func testSchemaIsSpelledOutForTools() {
        let r = TextRequest(system: "SYS", user: "USER", maxTokens: 100, schema: #"{"type":"object"}"#)
        let p = AccountCLIs.combined(r, extra: "EXTRA")
        XCTAssertTrue(p.hasPrefix("SYS"))
        XCTAssertTrue(p.hasSuffix("USER"))
        XCTAssertTrue(p.contains(#"{"type":"object"}"#))
    }

    func testSignInScriptsInstallWhenMissing() {
        XCTAssertTrue(AccountCLIs.connectScript(.claude, existing: nil).contains("claude.ai/install.sh"))
        XCTAssertFalse(AccountCLIs.connectScript(.claude, existing: "/x/claude").contains("install.sh"))
        XCTAssertTrue(AccountCLIs.connectScript(.codex, existing: nil).contains("@openai/codex"))
        XCTAssertTrue(AccountCLIs.connectScript(.codex, existing: "/x/codex").contains("login"))
    }
}
