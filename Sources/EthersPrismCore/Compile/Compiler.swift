import Foundation

/// Everything an adapter needs to build a request. New fields go in `options` so adapters keep compiling.
public struct CompileInput: Codable, Hashable, Sendable {
    public var state: WorkingState
    public var quality: Quality
    public var options: [String: String]

    public init(state: WorkingState, quality: Quality, options: [String: String] = [:]) {
        self.state = state
        self.quality = quality
        self.options = options
    }
}

public struct TextRequest: Codable, Hashable, Sendable {
    public var system: String
    public var user: String
    public var maxTokens: Int
    /// Optional JSON Schema (as JSON text). Servers that support structured output are held to it.
    public var schema: String?

    public init(system: String, user: String, maxTokens: Int, schema: String? = nil) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.schema = schema
    }
}

/// JSON Schemas for the answers agents must return as data.
public enum Schemas {
    public static let dials = #"{"type":"object","properties":{"dials":{"type":"array","minItems":4,"maxItems":8,"items":{"type":"object","properties":{"name":{"type":"string"},"detail":{"type":"string"},"low":{"type":"string"},"high":{"type":"string"}},"required":["name","detail","low","high"]}}},"required":["dials"]}"#
    public static let imagePrompt = #"{"type":"object","properties":{"prompt":{"type":"string"},"negative":{"type":"string"}},"required":["prompt","negative"]}"#
    public static let review = #"{"type":"object","properties":{"passes":{"type":"boolean"},"issues":{"type":"array","items":{"type":"string"}}},"required":["passes","issues"]}"#
}

/// Repairs common slips small models make in JSON: unquoted keys and trailing commas.
public enum JSONRepair {
    public static func repair(_ text: String, keys: [String]) -> String {
        var s = text
        for key in keys {
            s = s.replacingOccurrences(of: "([{,]\\s*)\(key)\\s*:", with: "$1\"\(key)\":", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        return s
    }
}

public struct CompiledRequest: Codable, Hashable, Sendable {
    public var input: CompileInput
    public var text: TextRequest
    /// Stable seed derived from the state, so a preview and its full render share a starting point.
    public var seed: UInt64

    public init(input: CompileInput, text: TextRequest, seed: UInt64) {
        self.input = input
        self.text = text
        self.seed = seed
    }
}

/// Deterministic: the same state and quality always produce the same request.
public enum Compiler {
    public static func describe(_ dial: Dial) -> String {
        let v = dial.intValue
        let low = "\"\(dial.lowPole)\"", high = "\"\(dial.highPole)\""
        let lean: String
        switch v {
        case ..<10: lean = "fully at \(low)"
        case 10..<30: lean = "strongly toward \(low)"
        case 30..<45: lean = "somewhat toward \(low)"
        case 45...55: lean = "balanced between \(low) and \(high)"
        case 56...70: lean = "somewhat toward \(high)"
        case 71...90: lean = "strongly toward \(high)"
        default: lean = "fully at \(high)"
        }
        let about = dial.detail.trimmed.isEmpty ? "" : " (\(dial.detail.trimmed))"
        return "- \(dial.name)\(about): \(v)/100 — \(lean)"
    }

    public static func describe(_ constraints: [Constraint]) -> String {
        let active = constraints.filter { $0.isActive && !$0.text.trimmed.isEmpty }
        guard !active.isEmpty else { return "" }
        return active.map { "- \($0.kind.label): \($0.text.trimmed)" }.joined(separator: "\n")
    }

    public static func buildText(role: String, format: String, input: CompileInput,
                                 previewTokens: Int, renderTokens: Int) -> TextRequest {
        let system = """
        \(role)
        You are working inside Ethers Prism, an instrument where a person explores variations by moving dials. \
        Each dial has two named ends. Honor every dial setting faithfully and make differences between settings \
        clearly perceptible. Fixed requirements are not dials: always satisfy them fully, whatever the dials say.
        Output format: \(format)
        Output only the result itself. No preamble and no commentary about the dials.
        """
        let s = input.state
        let dials = s.dials.isEmpty ? "(none)" : s.dials.map(describe).joined(separator: "\n")
        let fixed = describe(s.constraints)
        let note = input.quality == .preview
            ? "QUICK PREVIEW: a short, rough draft (about a quarter of full size) that still makes every dial's effect visible."
            : "FULL RENDER: the complete, polished result."
        var user = "Goal: \(s.goal.trimmed)\n\nDials (0 = first end, 100 = second end):\n\(dials)\n"
        if !fixed.isEmpty { user += "\nFixed requirements (always honor):\n\(fixed)\n" }
        user += "\n\(note)"
        return TextRequest(system: system, user: user,
                           maxTokens: input.quality == .preview ? previewTokens : renderTokens)
    }

    /// FNV-1a over the state's request text. Stable across launches, unlike hashValue.
    public static func seed(for text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h & 0x7fff_ffff_ffff
    }
}

/// Asks the model to propose dials for a goal, and reads its answer.
public enum DialSuggester {
    public static let marker = "[[DIAL-SUGGESTION]]"

    public static func request(goal: String, adapterName: String, hint: String) -> TextRequest {
        let system = """
        \(marker) You design creative instruments. Given a goal, propose dials (sliders) that let a person \
        explore meaningfully different variations. Each dial is one independent dimension with two concrete, \
        contrasting ends. Dials must not overlap. Never make a dial for something that must stay fixed \
        (factual accuracy, safety, accessibility, required or forbidden content); those are constraints, not dials. \
        Respond with only a JSON array.
        """
        let user = """
        Field: \(adapterName)
        Dimensions that often matter here: \(hint)
        Goal: \(goal.trimmed)

        Propose between 4 and 8 dials (as many as truly matter for this goal) as JSON:
        [{"name": "short name", "detail": "one sentence on what it changes", "low": "what 0 means", "high": "what 100 means"}]
        """
        return TextRequest(system: system, user: user, maxTokens: 1200, schema: Schemas.dials)
    }

    /// "visual_complexity" → "Visual complexity"
    static func tidyName(_ raw: String) -> String {
        let spaced = raw.trimmed.replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }

    private struct Raw: Decodable {
        let name: String
        let detail: String?
        let description: String?
        let low: String
        let high: String
    }

    public static func parse(_ raw: String) throws -> [Dial] {
        let text = OutputCleaner.stripThinking(raw)
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else {
            throw PrismError.badDialJSON
        }
        let slice = String(text[start...end])
        func decode(_ s: String) -> [Raw]? { try? JSONDecoder().decode([Raw].self, from: Data(s.utf8)) }
        guard let raws = decode(slice) ?? decode(JSONRepair.repair(slice, keys: ["name", "detail", "description", "low", "high"])),
              !raws.isEmpty else { throw PrismError.badDialJSON }
        let dials = raws.prefix(8).map {
            Dial(name: tidyName($0.name), detail: ($0.detail ?? $0.description ?? "").trimmed,
                 lowPole: $0.low.trimmed, highPole: $0.high.trimmed)
        }
        if dials.contains(where: { $0.name.isEmpty || $0.lowPole.isEmpty || $0.highPole.isEmpty }) {
            throw PrismError.badDialJSON
        }
        return Array(dials)
    }
}

public enum OutputCleaner {
    /// Removes a reasoning model's <think>…</think> block.
    public static func stripThinking(_ raw: String) -> String {
        var s = raw
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        return s.trimmed
    }

    public static func clean(_ raw: String, kind: OutputKind) -> String {
        let t = stripThinking(raw)
        switch kind {
        case .image:
            return svgBody(t) ?? t
        case .video:
            return t
        case .code, .text, .storyboard:
            return stripFences(t)
        }
    }

    public static func svgBody(_ t: String) -> String? {
        guard let s = t.range(of: "<svg", options: .caseInsensitive),
              let e = t.range(of: "</svg>", options: [.caseInsensitive, .backwards]),
              s.lowerBound < e.upperBound else { return nil }
        return String(t[s.lowerBound..<e.upperBound])
    }

    /// Removes a code fence only when it wraps the whole output.
    public static func stripFences(_ t: String) -> String {
        guard t.hasPrefix("```") else { return t }
        var lines = t.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, last.trimmed.hasPrefix("```") { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

public struct StoryboardScene: Identifiable, Hashable, Sendable {
    public let id: Int
    public var title: String
    public var body: String
}

public enum Storyboard {
    public static func parse(_ text: String) -> [StoryboardScene] {
        var scenes: [StoryboardScene] = []
        var title: String?
        var body: [String] = []
        func flush() {
            if let t = title {
                scenes.append(StoryboardScene(id: scenes.count, title: t, body: body.joined(separator: "\n").trimmed))
            }
            body = []
        }
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                flush()
                title = String(line.dropFirst(3)).trimmed
            } else {
                body.append(line)
            }
        }
        flush()
        if scenes.isEmpty && !text.trimmed.isEmpty {
            return [StoryboardScene(id: 0, title: "Storyboard", body: text.trimmed)]
        }
        return scenes
    }
}
