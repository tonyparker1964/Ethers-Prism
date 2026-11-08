import Foundation

/// One job inside the instrument. Each job gets its own model; the person still steers and chooses.
public enum AgentRole: String, Codable, CaseIterable, Hashable, Sendable {
    case dialDesigner, writer, artDirector, coder, checker

    public var title: String {
        switch self {
        case .dialDesigner: return "Dial Designer"
        case .writer: return "Writer"
        case .artDirector: return "Art Director"
        case .coder: return "Coder"
        case .checker: return "Checker"
        }
    }

    public var job: String {
        switch self {
        case .dialDesigner: return "Proposes dials for a goal."
        case .writer: return "Writes text, music sketches, storyboards and research plans."
        case .artDirector: return "Turns dials and requirements into image prompts."
        case .coder: return "Writes code for the Code field."
        case .checker: return "Reviews each result against the fixed requirements and flags problems. Never rewrites."
        }
    }
}

public enum AgentBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case anthropic, lmStudio, ollama, mock

    public var label: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .lmStudio: return "LM Studio (this Mac)"
        case .ollama: return "Ollama"
        case .mock: return "Mock (test only)"
        }
    }

    public var isLocal: Bool { self == .lmStudio || self == .ollama }
}

public struct AgentAssignment: Codable, Hashable, Identifiable, Sendable {
    public var role: AgentRole
    public var backend: AgentBackend
    public var model: String
    public var id: AgentRole { role }

    public init(role: AgentRole, backend: AgentBackend, model: String) {
        self.role = role
        self.backend = backend
        self.model = model
    }
}

/// Which model does which job, plus where the local servers are.
public struct AgentTeam: Codable, Hashable, Sendable {
    public var assignments: [AgentAssignment]
    public var lmStudioURL: String
    public var ollamaURL: String
    public var checkerEnabled: Bool
    /// Large local models (20B+) and ComfyUI take turns with memory.
    public var memoryHandoff: Bool

    public static let smallLocalModel = "qwen/qwen3-8b"
    public static let coderModel = "qwen3-coder-30b-a3b-instruct"

    public init(assignments: [AgentAssignment], lmStudioURL: String = "http://127.0.0.1:1234",
                ollamaURL: String = "http://127.0.0.1:11434", checkerEnabled: Bool = true, memoryHandoff: Bool = true) {
        self.assignments = assignments
        self.lmStudioURL = lmStudioURL
        self.ollamaURL = ollamaURL
        self.checkerEnabled = checkerEnabled
        self.memoryHandoff = memoryHandoff
    }

    /// Everything local on this Mac: a small fast model for frequent jobs, the 30B coder for code.
    public static let local = AgentTeam(assignments: [
        AgentAssignment(role: .dialDesigner, backend: .lmStudio, model: smallLocalModel),
        AgentAssignment(role: .writer, backend: .lmStudio, model: smallLocalModel),
        AgentAssignment(role: .artDirector, backend: .lmStudio, model: smallLocalModel),
        AgentAssignment(role: .coder, backend: .lmStudio, model: coderModel),
        AgentAssignment(role: .checker, backend: .lmStudio, model: smallLocalModel)
    ])

    public static let mock = AgentTeam(assignments: AgentRole.allCases.map {
        AgentAssignment(role: $0, backend: .mock, model: "mock")
    })

    public func assignment(_ role: AgentRole) -> AgentAssignment {
        assignments.first { $0.role == role } ?? AgentAssignment(role: role, backend: .mock, model: "mock")
    }

    public mutating func set(_ a: AgentAssignment) {
        if let i = assignments.firstIndex(where: { $0.role == a.role }) { assignments[i] = a } else { assignments.append(a) }
    }

    private enum CodingKeys: String, CodingKey {
        case assignments, lmStudioURL, ollamaURL, checkerEnabled, memoryHandoff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try c.decodeIfPresent([AgentAssignment].self, forKey: .assignments) ?? AgentTeam.local.assignments
        lmStudioURL = try c.decodeIfPresent(String.self, forKey: .lmStudioURL) ?? "http://127.0.0.1:1234"
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? "http://127.0.0.1:11434"
        checkerEnabled = try c.decodeIfPresent(Bool.self, forKey: .checkerEnabled) ?? true
        memoryHandoff = try c.decodeIfPresent(Bool.self, forKey: .memoryHandoff) ?? true
        for role in AgentRole.allCases where !assignments.contains(where: { $0.role == role }) {
            assignments.append(AgentTeam.local.assignment(role))
        }
    }
}

/// The Checker's verdict on a result. Stored with the history state; it never changes the result.
public struct Review: Codable, Hashable, Sendable {
    public var passed: Bool
    public var issues: [String]
    public var reviewer: String

    public init(passed: Bool, issues: [String], reviewer: String) {
        self.passed = passed
        self.issues = issues
        self.reviewer = reviewer
    }
}

public enum Checker {
    public static let marker = "[[CHECKER]]"

    /// Nil when there is nothing to check against.
    public static func request(for output: Output, constraints: [Constraint]) -> TextRequest? {
        // A beat's requirements are applied to sample choice directly; there's no text to review.
        if output.kind == .audio { return nil }
        let fixed = Compiler.describe(constraints)
        let content = output.text ?? output.imagePrompt
        guard !fixed.isEmpty, let content, !content.trimmed.isEmpty else { return nil }
        let what = output.text == nil ? "image prompt (the picture itself is not available to you)" : "result"
        let system = """
        \(marker) You are a careful reviewer. Check the \(what) against the fixed requirements only. \
        A requirement names a quality, not a word to search for: "Must avoid: jargon" means no technical or insider \
        language, not the word "jargon". Report a problem only if you can quote the exact words in the \(what) that \
        break a requirement; if you cannot quote them, the requirement is met. Do not judge style or taste and never \
        rewrite anything. Respond with only JSON: \
        {"passes": true or false, "issues": ["requirement — \\"exact quoted words\\""]}
        """
        let label = output.text == nil ? "Image prompt" : "Result"
        let user = "Fixed requirements:\n\(fixed)\n\n\(label):\n\"\"\"\n\(content.prefix(12000))\n\"\"\""
        return TextRequest(system: system, user: user, maxTokens: 600, schema: Schemas.review)
    }

    private struct Raw: Decodable {
        let passes: Bool?
        let pass: Bool?
        let issues: [String]?
    }

    public static func parse(_ raw: String, reviewer: String) -> Review {
        let text = OutputCleaner.stripThinking(raw)
        if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e,
           let r = [String(text[s...e]), JSONRepair.repair(String(text[s...e]), keys: ["passes", "pass", "issues"])]
               .lazy.compactMap({ try? JSONDecoder().decode(Raw.self, from: Data($0.utf8)) }).first {
            let issues = (r.issues ?? []).map(\.trimmed).filter { !$0.isEmpty }
            return Review(passed: (r.passes ?? r.pass ?? issues.isEmpty) && issues.isEmpty, issues: issues, reviewer: reviewer)
        }
        return Review(passed: false, issues: ["The Checker's answer couldn't be read."], reviewer: reviewer)
    }
}

extension Session {
    public mutating func setReview(_ review: Review, for snapshotID: UUID) {
        if let i = snapshots.firstIndex(where: { $0.id == snapshotID }) { snapshots[i].output.review = review }
    }
}
