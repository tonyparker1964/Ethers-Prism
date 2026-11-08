import Foundation

/// What the Music Producer agent decided for a Beats goal. Everything it picks lands where the
/// person can see and change it: the style and kits become fixed requirements, the rest are dial positions.
public struct ProducerPlan: Hashable, Sendable {
    public var style: BeatStyle?
    public var kits: [String]
    /// Dial name (lowercased) → value 0...100.
    public var dialValues: [String: Double]
    public var note: String

    public init(style: BeatStyle?, kits: [String], dialValues: [String: Double], note: String) {
        self.style = style
        self.kits = kits
        self.dialValues = dialValues
        self.note = note
    }
}

public enum BeatProducer {
    public static let marker = "[[PRODUCER]]"
    /// Requirements the producer adds start with these, so a new suggestion replaces the old picks
    /// and never touches requirements the person wrote.
    public static let stylePrefix = "Style: "
    public static let kitPrefix = "Kit: "
    static let dialKeys = ["tempo", "swing", "density", "variation", "tone", "bass", "pattern"]

    public static let schema = #"{"type":"object","properties":{"style":{"type":"string"},"kits":{"type":"array","maxItems":3,"items":{"type":"string"}},"dials":{"type":"object","properties":{"tempo":{"type":"number"},"swing":{"type":"number"},"density":{"type":"number"},"variation":{"type":"number"},"tone":{"type":"number"},"bass":{"type":"number"},"pattern":{"type":"number"}}},"note":{"type":"string"}},"required":["style","kits","dials","note"]}"#

    public static func request(goal: String, kits: [String], constraints: [Constraint]) -> TextRequest {
        let styles = BeatStyle.all.map { "- \($0.id): \($0.name), \(Int($0.tempo.lowerBound))–\(Int($0.tempo.upperBound)) BPM" }
            .joined(separator: "\n")
        let kitList = kits.prefix(300).map { "- \($0)" }.joined(separator: "\n")
        let fixed = Compiler.describe(constraints.filter { !isProducerPick($0) })
        let system = """
        \(marker) You are a music producer setting up a beat machine that plays the person's own drum samples. \
        Choose the style that best fits the goal, up to three kits from the list whose names suit the sound \
        (use the names exactly as written; if the goal names a kit, choose it), and a starting position from 0 to 100 \
        for each dial: tempo (slowest to fastest within the style), swing (straight to heavy), density (sparse to busy), \
        variation (one repeating loop to always evolving with fills), tone (dark and muffled to bright), \
        bass (none to heavy), pattern (picks among ten grooves). Respect every fixed requirement. \
        Respond with only JSON: {"style": "style id", "kits": ["kit name"], "dials": {"tempo": 0-100, "swing": 0-100, \
        "density": 0-100, "variation": 0-100, "tone": 0-100, "bass": 0-100, "pattern": 0-100}, \
        "note": "one short sentence on the choices"}
        """
        var user = "Goal: \(goal.trimmed)\n\nStyles:\n\(styles)\n\nKits in the library:\n\(kitList.isEmpty ? "(none)" : kitList)"
        if !fixed.isEmpty { user += "\n\nFixed requirements:\n\(fixed)" }
        return TextRequest(system: system, user: user, maxTokens: 500, schema: schema)
    }

    private struct Raw: Decodable {
        var style: String?
        var kits: [String]?
        var dials: [String: Double]?
        var note: String?
    }

    /// Reads the agent's answer. Unknown styles and kits that aren't in the library are dropped.
    public static func parse(_ raw: String, kits available: [String]) throws -> ProducerPlan {
        let text = OutputCleaner.stripThinking(raw)
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e else { throw PrismError.emptyResponse }
        let slice = String(text[s...e])
        var decoded: Raw?
        for candidate in [slice, JSONRepair.repair(slice, keys: ["style", "kits", "dials", "note"] + dialKeys)] {
            if let r = try? JSONDecoder().decode(Raw.self, from: Data(candidate.utf8)) { decoded = r; break }
        }
        guard let r = decoded else { throw PrismError.emptyResponse }
        let wanted = (r.style ?? "").lowercased()
        var style = BeatStyle.all.first { $0.id == wanted || $0.name.lowercased() == wanted }
        if style == nil, !wanted.isEmpty {
            let detected = BeatStyle.detect(in: wanted)
            // detect falls back to boom bap when nothing matches; only trust it when the words really say so.
            if detected.id != BeatStyle.fallback.id || wanted.contains("boom") || wanted.contains("hip") { style = detected }
        }
        var kits: [String] = []
        for k in r.kits ?? [] {
            if let match = available.first(where: { $0.lowercased() == k.trimmed.lowercased() }), !kits.contains(match) {
                kits.append(match)
            }
        }
        var values: [String: Double] = [:]
        for (key, v) in r.dials ?? [:] where dialKeys.contains(key.lowercased()) {
            values[key.lowercased()] = Dial.clamp(v)
        }
        return ProducerPlan(style: style, kits: Array(kits.prefix(3)), dialValues: values, note: (r.note ?? "").trimmed)
    }

    public static func plan(goal: String, index: SampleIndex, constraints: [Constraint],
                            using provider: any TextProvider) async throws -> ProducerPlan {
        let kits = index.drumKits
        let raw = try await provider.complete(request(goal: goal, kits: kits, constraints: constraints))
        return try parse(raw, kits: kits)
    }

    public static func isProducerPick(_ c: Constraint) -> Bool {
        (c.kind == .other && c.text.hasPrefix(stylePrefix)) || (c.kind == .mustInclude && c.text.hasPrefix(kitPrefix))
    }

    /// Sets dial positions by name. The Kit dial goes to the start, so it steps through the chosen kits.
    public static func apply(_ plan: ProducerPlan, to dials: [Dial]) -> [Dial] {
        dials.map { d in
            var d = d
            let key = d.name.lowercased()
            if let v = plan.dialValues.first(where: { key.contains($0.key) })?.value { d.value = v }
            if key.contains("kit"), !plan.kits.isEmpty { d.value = 0 }
            return d
        }
    }

    /// The person's own requirements, plus the producer's new style and kit picks (earlier picks are replaced).
    public static func constraints(for plan: ProducerPlan, keeping existing: [Constraint]) -> [Constraint] {
        var out = existing.filter { !isProducerPick($0) }
        if let style = plan.style { out.append(Constraint(kind: .other, text: stylePrefix + style.name)) }
        for kit in plan.kits { out.append(Constraint(kind: .mustInclude, text: kitPrefix + kit)) }
        return out
    }
}
