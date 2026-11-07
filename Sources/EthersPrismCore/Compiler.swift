import Foundation

/// Turns a goal plus dial positions into instructions for the model.
public enum Compiler {
    public static func describe(_ axis: Dial) -> String {
        let v = Int(axis.value.rounded())
        let low = "\"\(axis.lowPole)\"", high = "\"\(axis.highPole)\""
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
        return "- \(axis.name): \(v)/100 — \(lean)"
    }

    public static func compile(goal: String, axes: [Dial], quality: Quality,
                               role: String, format: String, maxTokens: Int) -> CompiledRequest {
        let system = """
        \(role)
        You are working inside Ethers Prism, an instrument where a person explores variations by moving dials. \
        Each dial has two named ends. Honor every dial setting faithfully, and make the difference between settings \
        clearly perceptible.
        Output format: \(format)
        Output only the result itself. No preamble and no commentary about the dials.
        """
        let dials = axes.isEmpty ? "(none)" : axes.map(describe).joined(separator: "\n")
        let note = quality == .preview
            ? "QUICK PREVIEW: a short, rough draft (about a quarter of full size) that still makes every dial's effect visible."
            : "FULL RENDER: the complete, polished result."
        let user = """
        Goal: \(goal)

        Dials (0 = first end, 100 = second end):
        \(dials)

        \(note)
        """
        return CompiledRequest(system: system, user: user, maxTokens: maxTokens)
    }
}

/// Asks the model to propose dials for a goal, and reads its answer.
public enum AxisSuggester {
    public static let marker = "[[AXIS-SUGGESTION]]"

    public static func request(goal: String, adapter: any DomainAdapter, count: Int = 6) -> CompiledRequest {
        let system = """
        \(marker) You design creative instruments. Given a goal, propose dials (sliders) that let a person \
        explore meaningfully different variations. Each dial is one independent dimension with two concrete, \
        contrasting ends. Dials must not overlap. Respond with only a JSON array.
        """
        let user = """
        Field: \(adapter.name)
        Dimensions that often matter here: \(adapter.axisHint)
        Goal: \(goal)

        Propose exactly \(count) dials as JSON:
        [{"name": "short name", "low": "what 0 means", "high": "what 100 means"}]
        """
        return CompiledRequest(system: system, user: user, maxTokens: 900)
    }

    private struct Raw: Decodable {
        let name: String
        let low: String
        let high: String
    }

    /// Tolerates prose or code fences around the JSON array.
    public static func parse(_ text: String) throws -> [Dial] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let raws = try? JSONDecoder().decode([Raw].self, from: data), !raws.isEmpty
        else { throw PrismError.badAxisJSON }
        return raws.map { Dial(name: $0.name.trimmed, lowPole: $0.low.trimmed, highPole: $0.high.trimmed) }
    }
}

public enum OutputCleaner {
    public static func clean(_ raw: String, kind: OutputKind) -> String {
        let t = raw.trimmed
        switch kind {
        case .svg:
            if let s = t.range(of: "<svg", options: .caseInsensitive),
               let e = t.range(of: "</svg>", options: [.caseInsensitive, .backwards]),
               s.lowerBound < e.upperBound {
                return String(t[s.lowerBound..<e.upperBound])
            }
            return t
        case .code, .text, .storyboard:
            return stripFences(t)
        }
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
                scenes.append(StoryboardScene(id: scenes.count, title: t,
                                              body: body.joined(separator: "\n").trimmed))
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

public enum Exporter {
    /// The result plus a record of how the person got there.
    public static func authorshipLog(_ session: Session, adapter: any DomainAdapter) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines: [String] = [
            "# \(session.title)",
            "",
            "- **Goal:** \(session.goal)",
            "- **Field:** \(adapter.name)",
            "- **Made with:** Ethers Prism. The person chose the dials, explored, and picked the result; the AI supplied the range of options.",
            "",
            "## Dials"
        ]
        let dials = session.currentSnapshot?.axes ?? session.axes
        lines += dials.map(Compiler.describe)

        if let cur = session.currentSnapshot {
            let path = session.path(to: cur.id)
            lines += ["", "## Path (\(path.count) steps)"]
            for (i, s) in path.enumerated() {
                let star = s.chosen ? " ★ chosen" : ""
                lines.append("\(i + 1). \(f.string(from: s.createdAt)) · \(s.quality.rawValue) · \(session.summary(for: s))\(star)")
            }
            lines += ["", "States explored in total: \(session.snapshots.count)", "", "## Result", ""]
            switch adapter.outputKind {
            case .svg: lines += ["```svg", cur.output, "```"]
            case .code: lines += ["```", cur.output, "```"]
            case .text, .storyboard: lines.append(cur.output)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
