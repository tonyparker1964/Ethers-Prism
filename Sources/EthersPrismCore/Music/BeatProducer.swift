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

    /// Flat on purpose: small local models follow a flat schema far more reliably than nested objects.
    public static let schema = #"{"type":"object","properties":{"style":{"type":"string"},"kits":{"type":"array","items":{"type":"string"}},"tempo":{"type":"number"},"swing":{"type":"number"},"density":{"type":"number"},"variation":{"type":"number"},"tone":{"type":"number"},"bass":{"type":"number"},"pattern":{"type":"number"},"note":{"type":"string"}},"required":["style","kits","tempo","swing","density","variation","tone","bass","pattern","note"],"additionalProperties":false}"#

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
        Respond with only JSON: {"style": "style id", "kits": ["kit name"], "tempo": 0-100, "swing": 0-100, \
        "density": 0-100, "variation": 0-100, "tone": 0-100, "bass": 0-100, "pattern": 0-100, \
        "note": "one short sentence on the choices"}
        """
        var user = "Goal: \(goal.trimmed)\n\nStyles:\n\(styles)\n\nKits in the library:\n\(kitList.isEmpty ? "(none)" : kitList)"
        if !fixed.isEmpty { user += "\n\nFixed requirements:\n\(fixed)" }
        // Room to spare: a model that thinks before answering can use hundreds of tokens first.
        return TextRequest(system: system, user: user, maxTokens: 2500, schema: schema)
    }

    /// A number that may arrive as 40, 40.0 or "40".
    private struct Number: Decodable {
        var value: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { value = d }
            else if let s = try? c.decode(String.self) { value = Double(s.trimmingCharacters(in: .whitespaces)) }
        }
    }

    private struct Raw: Decodable {
        var style: String?
        var kits: [String]?
        var dials: [String: Number]?
        var note: String?
        var tempo, swing, density, variation, tone, bass, pattern: Number?
    }

    /// Reads the agent's answer. Unknown styles and kits that aren't in the library are dropped.
    public static func parse(_ raw: String, kits available: [String]) throws -> ProducerPlan {
        let text = OutputCleaner.stripThinking(raw)
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e else {
            throw PrismError.local("its answer had no settings in it: “\(text.trimmed.prefix(120))”")
        }
        let slice = String(text[s...e])
        var decoded: Raw?
        for candidate in [slice, JSONRepair.repair(slice, keys: ["style", "kits", "dials", "note"] + dialKeys)] {
            if let r = try? JSONDecoder().decode(Raw.self, from: Data(candidate.utf8)) { decoded = r; break }
        }
        guard let r = decoded else { throw PrismError.local("its answer couldn't be read: “\(slice.prefix(120))”") }
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
        // Older answers nest the dials; current ones put them at the top level. Either works.
        for (key, v) in r.dials ?? [:] where dialKeys.contains(key.lowercased()) {
            if let n = v.value { values[key.lowercased()] = Dial.clamp(n) }
        }
        let flat: [(String, Number?)] = [("tempo", r.tempo), ("swing", r.swing), ("density", r.density),
                                         ("variation", r.variation), ("tone", r.tone), ("bass", r.bass), ("pattern", r.pattern)]
        for (key, v) in flat { if let n = v?.value { values[key] = Dial.clamp(n) } }
        return ProducerPlan(style: style, kits: Array(kits.prefix(3)), dialValues: values, note: (r.note ?? "").trimmed)
    }

    public static func plan(goal: String, index: SampleIndex, constraints: [Constraint],
                            using provider: any TextProvider) async throws -> ProducerPlan {
        let kits = index.drumKits
        let req = request(goal: goal, kits: kits, constraints: constraints)
        do {
            return try parse(try await provider.complete(req), kits: kits)
        } catch let e as PrismError where e != .missingAPIKey {
            // Some local models answer empty when held to a schema. Ask once more without it.
            if case .local(let m) = e, m.contains("isn't reachable") || m.contains("Choose a model") { throw e }
            var loose = req
            loose.schema = nil
            return try parse(try await provider.complete(loose), kits: kits)
        }
    }

    // MARK: Built-in producer (no AI)

    /// Mood words and the dial positions they suggest. Checked as whole words in the goal.
    static let moods: [(words: [String], dial: String, value: Double)] = [
        (["slow", "chill", "laid back", "laidback", "relaxed", "late night", "late-night", "sleepy", "mellow", "calm"], "tempo", 25),
        (["fast", "energetic", "hype", "aggressive", "upbeat", "driving", "intense", "party"], "tempo", 80),
        (["swing", "swung", "jazzy", "jazz", "bouncy", "shuffle", "groovy", "lazy", "dusty", "loose"], "swing", 70),
        (["straight", "tight", "robotic", "mechanical", "quantized"], "swing", 5),
        (["minimal", "sparse", "simple", "stripped", "empty"], "density", 20),
        (["busy", "complex", "dense", "rolling", "frantic"], "density", 80),
        (["evolving", "fills", "live", "varied", "changing", "jazz", "jazzy"], "variation", 70),
        (["loop", "repetitive", "hypnotic", "steady"], "variation", 15),
        (["dark", "muffled", "warm", "dusty", "vintage", "underwater", "late night", "late-night", "murky", "vinyl"], "tone", 30),
        (["bright", "crisp", "clean", "shiny", "airy", "sparkly", "modern"], "tone", 90),
        (["no bass", "without bass", "drums only", "just drums"], "bass", 0),
        (["heavy bass", "bassy", "808", "sub", "deep", "bass heavy", "boomy"], "bass", 85)
    ]

    /// Reads mood words in the goal and picks kits whose names match the goal or the style.
    /// Always works, needs no model, and gives the same answer for the same goal.
    public static func builtIn(goal: String, kits available: [String]) -> ProducerPlan {
        let g = " " + BeatStyle.words(goal) + " "
        var sums: [String: (total: Double, count: Double)] = [:]
        var heard: [String] = []
        for mood in moods {
            if let w = mood.words.first(where: { g.contains(" " + BeatStyle.words($0) + " ") }) {
                let s = sums[mood.dial] ?? (0, 0)
                sums[mood.dial] = (s.total + mood.value, s.count + 1)
                if !heard.contains(w) { heard.append(w) }
            }
        }
        var values: [String: Double] = [:]
        for (dial, s) in sums { values[dial] = (s.total / s.count).rounded() }

        let detected = BeatStyle.detect(in: goal)
        let named = BeatStyle.all.contains { st in st.keywords.contains { g.contains(" " + BeatStyle.words($0) + " ") } }
        let style: BeatStyle? = named ? detected : nil

        // Kits: names sharing a word with the goal (or starting with a style word, like "Afrobeats" for afro).
        let goalWords = Set(SampleScanner.tokens(goal).filter { $0.count >= 4 && !BeatsAdapter.genericKitWords.contains($0) })
        let styleWords = Set((style?.keywords ?? []).flatMap { SampleScanner.tokens($0) }.filter { $0.count >= 3 })
        var kits: [String] = []
        for kit in available {
            let words = SampleScanner.tokens(kit)
            let hit = words.contains { w in goalWords.contains(w) || styleWords.contains { w.hasPrefix($0) } }
            if hit { kits.append(kit) }
            if kits.count == 3 { break }
        }

        var parts: [String] = []
        if let style { parts.append(style.name.lowercased()) }
        if !heard.isEmpty { parts.append("heard “\(heard.joined(separator: "”, “"))”") }
        let note = parts.isEmpty
            ? "no style or mood words found in the goal, so the dials start in the middle."
            : parts.joined(separator: "; ") + "."
        return ProducerPlan(style: style, kits: kits, dialValues: values, note: note)
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
