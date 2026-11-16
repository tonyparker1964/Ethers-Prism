import Foundation

// Claude and ChatGPT through your own signed-in accounts, the same way Ether Explains does it:
// Claude runs through Claude Code (the `claude` command), ChatGPT through OpenAI's Codex (the `codex` command).
// No API keys: each uses your Claude or ChatGPT plan's usage.

/// The two account tools Prism can drive.
public enum AccountCLI: String, CaseIterable, Sendable {
    case claude, codex

    public var command: String { rawValue }
    public var toolName: String { self == .claude ? "Claude Code" : "Codex" }
    public var serviceName: String { self == .claude ? "Claude" : "ChatGPT" }

    public var backend: AgentBackend { self == .claude ? .claudeAccount : .chatGPT }

    func candidates(home: String) -> [String] {
        switch self {
        case .claude:
            return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                    "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude", "\(home)/.volta/bin/claude"]
        case .codex:
            return ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                    "\(home)/.npm-global/bin/codex", "\(home)/.codex/bin/codex", "\(home)/.bun/bin/codex", "\(home)/.volta/bin/codex"]
        }
    }
}

/// Installed? Signed in? Shown in Settings → Agents.
public struct AccountStatus: Equatable, Sendable {
    public var installed: Bool
    public var signedIn: Bool
    public var version: String
    public var detail: String

    public init(installed: Bool, signedIn: Bool, version: String = "", detail: String = "") {
        self.installed = installed
        self.signedIn = signedIn
        self.version = version
        self.detail = detail
    }

    public var ready: Bool { installed && signedIn }
}

public enum AccountCLIs {
    /// Where Prism keeps sign-in scripts and the working folders for Claude Code and Codex.
    public static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let u = base.appendingPathComponent("Ethers Prism/AI Accounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    // MARK: Finding the tools

    public static func find(_ cli: AccountCLI) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let p = cli.candidates(home: home).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        // Anywhere else your Terminal can see it (apps opened from the Dock get a much shorter PATH).
        let r = shellSync("/bin/zsh", ["-lc", "command -v \(cli.command)"], timeout: 8).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return r.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: r) ? r : nil
    }

    public static func status(_ cli: AccountCLI) async -> AccountStatus {
        await Task.detached(priority: .userInitiated) { AccountCLIs.statusSync(cli) }.value
    }

    static func statusSync(_ cli: AccountCLI) -> AccountStatus {
        guard let path = find(cli) else { return AccountStatus(installed: false, signedIn: false) }
        let q = quote(path)
        let v = shellSync("/bin/zsh", ["-lc", "\(q) --version"], timeout: 20)
        let version = v.out.trimmingCharacters(in: .whitespacesAndNewlines)
        switch cli {
        case .claude:
            let a = shellSync("/bin/zsh", ["-lc", "\(q) auth status"], timeout: 20)
            var signedIn = a.code == 0
            var detail = ""
            if let j = try? JSONSerialization.jsonObject(with: Data(a.out.utf8)) as? [String: Any] {
                if let li = j["loggedIn"] as? Bool { signedIn = li }
                detail = [j["email"], j["subscriptionType"]].compactMap { $0 as? String }.joined(separator: " · ")
            }
            return AccountStatus(installed: true, signedIn: signedIn, version: version, detail: detail)
        case .codex:
            let s = shellSync("/bin/zsh", ["-lc", "\(q) login status"], timeout: 20)
            let text = (s.out + "\n" + s.err).trimmingCharacters(in: .whitespacesAndNewlines)
            let low = text.lowercased()
            let signedIn = s.code == 0 && !low.contains("not logged in") && !low.contains("not signed in")
            let detail = text.components(separatedBy: "\n").first ?? ""
            return AccountStatus(installed: true, signedIn: signedIn, version: version, detail: String(detail.prefix(120)))
        }
    }

    // MARK: Signing in

    /// The Terminal script that installs the tool if needed, then signs in with your account.
    public static func connectScript(_ cli: AccountCLI, existing: String?) -> String {
        var s = "#!/bin/zsh -l\nclear\necho \"Ethers Prism: connect \(cli.serviceName) (\(cli.toolName))\"\necho\n"
        switch cli {
        case .claude:
            if let existing {
                s += "CLAUDE=\(quote(existing))\n"
            } else {
                s += """
                echo "Installing Claude Code (Anthropic's official installer)…"
                curl -fsSL https://claude.ai/install.sh | bash || { echo; echo "The install didn't finish. Check your internet connection and try again."; read -r; exit 1; }
                export PATH="$HOME/.local/bin:$PATH"
                CLAUDE="$(command -v claude)"

                """
            }
            s += """
            echo
            echo "Sign in with your Claude account in the browser window that opens."
            "$CLAUDE" auth login || "$CLAUDE"
            echo
            "$CLAUDE" auth status >/dev/null 2>&1 && echo "✓ Signed in. Go back to Ethers Prism and press Check." || echo "Not signed in yet. Press Sign In in Ethers Prism to try again."
            echo "You can close this window."

            """
        case .codex:
            if let existing {
                s += "CODEX=\(quote(existing))\n"
            } else {
                s += """
                echo "Installing OpenAI's Codex…"
                if command -v npm >/dev/null 2>&1; then npm install -g @openai/codex --prefix "$HOME/.local"; else curl -fsSL https://chatgpt.com/codex/install.sh | sh; fi
                export PATH="$HOME/.local/bin:$HOME/.codex/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
                CODEX="$(command -v codex)"
                [ -z "$CODEX" ] && { echo; echo "The install didn't finish. Check your internet connection and try again."; read -r; exit 1; }

                """
            }
            s += """
            echo
            echo "Sign in with your ChatGPT account in the browser window that opens."
            "$CODEX" login
            echo
            "$CODEX" login status && echo "✓ Go back to Ethers Prism and press Check." || echo "Not signed in yet. Press Sign In in Ethers Prism to try again."
            echo "You can close this window."

            """
        }
        return s
    }

    /// Opens Terminal to install (if needed) and sign in.
    public static func openSignIn(_ cli: AccountCLI) throws {
        let script = connectScript(cli, existing: find(cli))
        let u = supportDir.appendingPathComponent("Connect \(cli.serviceName).command")
        try script.write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        _ = shellSync("/usr/bin/open", [u.path], timeout: 10)
    }

    // MARK: Asking

    /// What Claude Code is asked to do: answer once, with no tools, no connectors and no long thinking.
    public static func claudeArguments(system: String, model: String) -> [String] {
        var args = ["-p", "--output-format", "json", "--append-system-prompt", system,
                    "--max-turns", "2", "--tools", "",
                    "--disallowedTools", "ToolSearch,AskUserQuestion,EnterPlanMode,EnterWorktree,TaskOutput,Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task,TodoWrite,Read,Glob,Grep,LS,ExitPlanMode,Skill,SlashCommand,BashOutput,KillShell",
                    "--settings", "{\"alwaysThinkingEnabled\":false}", "--strict-mcp-config"]
        if !model.trimmed.isEmpty { args += ["--model", model.trimmed] }
        return args
    }

    public static func codexArguments(outputFile: String, model: String) -> [String] {
        var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--json", "--output-last-message", outputFile]
        if !model.trimmed.isEmpty { args += ["--model", model.trimmed] }
        args.append("-") // the prompt comes from stdin
        return args
    }

    /// Reads Claude Code's `--output-format json` reply. Returns (answer, error).
    public static func parseClaude(_ out: String) -> (String?, String?) {
        // The result object is the last JSON line (older versions may print a list of events).
        for line in out.split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: d) else { continue }
            let objects = (any as? [[String: Any]]) ?? [(any as? [String: Any]) ?? [:]]
            if let r = objects.last(where: { $0["type"] as? String == "result" }) {
                let text = r["result"] as? String
                if (r["is_error"] as? Bool) == true { return (nil, text ?? (r["subtype"] as? String) ?? "Claude Code reported an error.") }
                if let text, !text.trimmed.isEmpty { return (text, nil) }
                return (nil, "Claude Code ended without an answer (\(r["subtype"] as? String ?? "empty")).")
            }
        }
        let plain = out.trimmed
        if plain.isEmpty { return (nil, nil) }
        return (plain, nil)
    }

    /// Reads Codex's `--json` event lines. Returns (last message, error message).
    public static func parseCodexEvents(_ out: String) -> (String?, String?) {
        var last: String?, error: String?
        for line in out.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let type = j["type"] as? String ?? ""
            let item = (j["item"] as? [String: Any]) ?? (j["msg"] as? [String: Any]) ?? [:]
            let itype = (item["type"] as? String ?? item["item_type"] as? String ?? "").lowercased()
            if itype.contains("agent_message") || itype.contains("assistant"), let t = item["text"] as? String, !t.isEmpty { last = t }
            if type.contains("error") || type == "turn.failed" {
                let m = (j["message"] as? String) ?? ((j["error"] as? [String: Any])?["message"] as? String) ?? (item["message"] as? String)
                if let m, !m.isEmpty { error = m }
            }
        }
        return (last, error)
    }

    public static func friendly(_ cli: AccountCLI, _ e: String) -> String {
        let l = e.lowercased()
        if l.contains("login") || l.contains("not signed") || l.contains("authenticat") || l.contains("401") || l.contains("unauthorized") {
            return "\(cli.toolName) isn't signed in to \(cli.serviceName). Open Settings → Agents and press Sign In next to \(cli.serviceName)."
        }
        if l.contains("limit") && (l.contains("usage") || l.contains("rate") || l.contains("reached")) || l.contains("429") {
            return "Your \(cli.serviceName) usage limit is reached for now. \(e.prefix(200))"
        }
        return "\(cli.serviceName): \(e.prefix(400))"
    }

    // MARK: Running commands

    public struct Result: Sendable {
        public var out: String
        public var err: String
        public var code: Int32
        public var timedOut: Bool
    }

    /// Runs a tool through your login shell (exactly like Terminal), feeding `input` on stdin.
    /// Cancelling the task stops the tool, so it doesn't keep using your plan's usage.
    public static func run(_ path: String, _ args: [String], input: String, directory: URL,
                           timeout: TimeInterval) async throws -> Result {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    signal(SIGPIPE, SIG_IGN) // a tool that exits early mustn't take Prism with it
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    p.arguments = ["-lc", "exec \"$0\" \"$@\"", path] + args
                    p.currentDirectoryURL = directory
                    var env = ProcessInfo.processInfo.environment
                    env["MAX_THINKING_TOKENS"] = "0"
                    p.environment = env
                    let o = Pipe(), e = Pipe(), i = Pipe()
                    p.standardOutput = o; p.standardError = e; p.standardInput = i
                    do { try p.run() } catch {
                        return cont.resume(throwing: PrismError.local("Couldn't start \(path): \(error.localizedDescription)"))
                    }
                    if !box.set(p) { p.terminate() } // cancelled before it started
                    let collected = Collected()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async { collected.setOut(o.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                    group.enter()
                    DispatchQueue.global().async { collected.setErr(e.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                    DispatchQueue.global().async {
                        try? i.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                        try? i.fileHandleForWriting.close()
                    }
                    let timer = DispatchWorkItem { if p.isRunning { collected.markTimedOut(); p.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    p.waitUntilExit()
                    timer.cancel()
                    group.wait()
                    if box.cancelled { return cont.resume(throwing: CancellationError()) }
                    cont.resume(returning: collected.result(code: p.terminationStatus))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    @discardableResult
    static func shellSync(_ path: String, _ args: [String], timeout: TimeInterval) -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ("", error.localizedDescription, -1) }
        let collected = Collected()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { collected.setOut(o.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { collected.setErr(e.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        p.waitUntilExit()
        timer.cancel()
        group.wait()
        let r = collected.result(code: p.terminationStatus)
        return (r.out, r.err, r.code)
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The prompt for tools that take one block of text: instructions first, then the request.
    static func combined(_ request: TextRequest, extra: String) -> String {
        var s = request.system + "\n\n" + extra
        if let schema = request.schema, !schema.trimmed.isEmpty {
            s += "\nYour whole reply must be JSON that matches this JSON Schema (no other text, no code fences):\n\(schema)"
        }
        return s + "\n\n" + request.user
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false

    /// False if the task was already cancelled.
    func set(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = p
        return !cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let p = process, p.isRunning { p.terminate() }
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data(), timedOut = false

    func setOut(_ d: Data) { lock.lock(); out = d; lock.unlock() }
    func setErr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    func result(code: Int32) -> AccountCLIs.Result {
        lock.lock(); defer { lock.unlock() }
        return AccountCLIs.Result(out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self),
                                  code: code, timedOut: timedOut)
    }
}

// MARK: - Text providers

/// Claude through your Claude account (Claude Code). No API key.
public struct ClaudeAccountTextProvider: TextProvider {
    public let name = "Claude (your account)"
    public var model: String

    public init(model: String) { self.model = model }

    public func complete(_ request: TextRequest) async throws -> String {
        guard let claude = AccountCLIs.find(.claude) else {
            throw PrismError.local("Claude Code isn't on this Mac yet. Open Settings → Agents and press Set Up next to Claude.")
        }
        var system = request.system
        if let schema = request.schema, !schema.trimmed.isEmpty {
            system += "\n\nYour whole reply must be JSON that matches this JSON Schema (no other text, no code fences):\n\(schema)"
        }
        system += "\n\nYou are working inside the Ethers Prism app. Answer directly in your reply; do not use tools or create files."
        let r = try await AccountCLIs.run(claude, AccountCLIs.claudeArguments(system: system, model: model),
                                          input: request.user,
                                          directory: AccountCLIs.supportDir.appendingPathComponent("claude-work", isDirectory: true),
                                          timeout: 900)
        if r.timedOut { throw PrismError.local("Claude took longer than 15 minutes and was stopped.") }
        let (answer, error) = AccountCLIs.parseClaude(r.out)
        if let error { throw PrismError.local(AccountCLIs.friendly(.claude, error)) }
        guard let answer, !answer.trimmed.isEmpty else {
            let why = r.err.trimmed
            throw PrismError.local(AccountCLIs.friendly(.claude, why.isEmpty ? "Claude Code ended without an answer (exit \(r.code))." : String(why.suffix(400))))
        }
        return answer
    }
}

/// ChatGPT through your ChatGPT account (OpenAI's Codex). No API key.
public struct ChatGPTAccountTextProvider: TextProvider {
    public let name = "ChatGPT (your account)"
    public var model: String

    public init(model: String) { self.model = model }

    public func complete(_ request: TextRequest) async throws -> String {
        guard let codex = AccountCLIs.find(.codex) else {
            throw PrismError.local("Codex isn't on this Mac yet. Open Settings → Agents and press Set Up next to ChatGPT.")
        }
        let work = AccountCLIs.supportDir.appendingPathComponent("codex-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let outFile = work.appendingPathComponent("prism-answer-\(UUID().uuidString.prefix(8)).txt")
        defer { try? FileManager.default.removeItem(at: outFile) }
        let prompt = AccountCLIs.combined(request, extra: "Do not create, edit or run any files. Answer only in your reply.")
        let r = try await AccountCLIs.run(codex, AccountCLIs.codexArguments(outputFile: outFile.path, model: model),
                                          input: prompt, directory: work, timeout: 900)
        if r.timedOut { throw PrismError.local("ChatGPT took longer than 15 minutes and was stopped.") }
        let (last, error) = AccountCLIs.parseCodexEvents(r.out)
        let fileAnswer = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let answer = fileAnswer.trimmed.isEmpty ? (last ?? "") : fileAnswer
        guard !answer.trimmed.isEmpty else {
            let why = error ?? r.err.trimmed
            throw PrismError.local(AccountCLIs.friendly(.codex, why.isEmpty ? "Codex ended without an answer (exit \(r.code))." : String(why.suffix(400))))
        }
        return answer
    }
}
