import Foundation

/// Beats: makes real audio from the person's own samples (for example Native Instruments
/// Maschine expansions and Battery kits). No AI and no network: dials map straight onto the groove,
/// so the same dials always give the same beat. The goal names the style ("dusty lo-fi", "trap",
/// "house") and can name a kit or expansion to use.
public struct BeatsAdapter: DomainAdapter {
    public let id = "beats"
    public let name = "Beats (your samples)"
    public let symbol = "waveform"
    public let status = AdapterStatus.ready
    public let capabilities = OutputCapabilities(kind: .audio, editable: false, exportFormats: ["wav", "mid"])
    public let dialHint = "tempo, swing, density, variation, tone, bass, kit, pattern"

    public static let previewBars = 4
    public static let renderBars = 16

    public init() {}

    /// The style a state asks for: a "Style:" requirement wins, otherwise the goal decides.
    public static func style(for state: WorkingState) -> BeatStyle {
        if let pick = state.constraints.first(where: { $0.isActive && $0.kind == .other && $0.text.hasPrefix(BeatProducer.stylePrefix) }) {
            let named = String(pick.text.dropFirst(BeatProducer.stylePrefix.count)).lowercased()
            if let exact = BeatStyle.all.first(where: { $0.name.lowercased() == named || $0.id == named }) { return exact }
            return BeatStyle.detect(in: named)
        }
        return BeatStyle.detect(in: state.goal)
    }

    public func suggestDials(for goal: String, using providers: ProviderSet) async throws -> [Dial] {
        let style = BeatStyle.detect(in: goal)
        let lo = Int(style.tempo.lowerBound), hi = Int(style.tempo.upperBound)
        return [
            Dial(name: "Tempo", detail: "Speed within the \(style.name.lowercased()) range.", lowPole: "\(lo) BPM", highPole: "\(hi) BPM", value: 50),
            Dial(name: "Swing", detail: "How far every second 16th note leans late.", lowPole: "straight", highPole: "heavy swing",
                 value: style.swingBase > 0.2 ? 55 : 20),
            Dial(name: "Density", detail: "How many hits fill the bar.", lowPole: "sparse", highPole: "busy", value: 50),
            Dial(name: "Variation", detail: "Whether bars repeat or keep changing, with fills.", lowPole: "one loop", highPole: "always evolving", value: 40),
            Dial(name: "Tone", detail: "Overall brightness of the mix.", lowPole: "dark and muffled", highPole: "bright and open", value: 75),
            Dial(name: "Bass", detail: "A bassline that follows the kick.", lowPole: "no bass", highPole: "heavy bass", value: 50),
            Dial(name: "Kit", detail: "Which kit or expansion the sounds come from.", lowPole: "first kit", highPole: "last kit", value: 0),
            Dial(name: "Pattern", detail: "Picks a different groove for the same style.", lowPole: "groove A", highPole: "groove J", value: 0)
        ]
    }

    public func compile(_ input: CompileInput) -> CompiledRequest {
        let p = BeatParameters(dials: input.state.dials)
        let fixed = input.state.constraints.filter(\.isActive).map { "\($0.kind.rawValue):\($0.text.trimmed)" }
        let summary = [
            "goal=\(input.state.goal.trimmed.lowercased())",
            String(format: "tempo=%.2f swing=%.2f density=%.2f variation=%.2f tone=%.2f bass=%.2f kit=%.2f pattern=%.2f",
                   p.tempo, p.swing, p.density, p.variation, p.tone, p.bass, p.kit, p.pattern),
            "quality=\(input.quality.rawValue)",
            "fixed=\(fixed.joined(separator: "|"))"
        ].joined(separator: "\n")
        // The groove seed comes from the goal alone, so dials reshape one beat instead of reshuffling it.
        let seed = Compiler.seed(for: "beats:" + input.state.goal.trimmed.lowercased())
        return CompiledRequest(input: input, text: TextRequest(system: "beats", user: summary, maxTokens: 0), seed: seed)
    }

    public func preview(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request)
    }

    public func render(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request)
    }

    /// Words in the goal that are about style, not about which kit to use.
    static let styleWords: Set<String> = Set(BeatStyle.all.flatMap { $0.keywords.flatMap { SampleScanner.tokens($0) } })
        .union(["beat", "beats", "with", "make", "some", "that", "this", "drums", "groove", "track", "song", "music",
                "using", "from", "like", "kind", "vibe", "style", "heavy", "dark", "bright", "slow", "fast"])
        .union(genericKitWords)
    /// Words in nearly every kit name, so they never decide which kit is meant.
    static let genericKitWords: Set<String> = ["kit", "kits", "library", "libraries", "expansion", "expansions", "sounds", "the", "and"]

    /// Picks one sample per role: the Kit dial chooses a kit; requirements and the goal narrow the choice.
    public static func choose(from index: SampleIndex, goal: String, constraints: [Constraint], kit: Double,
                              seed: UInt64) -> [SampleRole: SampleFile] {
        let avoid = constraints.filter { $0.isActive && $0.kind == .mustAvoid }
            .flatMap { SampleScanner.tokens($0.text) }.filter { $0.count >= 3 }
        // Each Must include names one kit; all of its words have to be in the kit's name.
        let includePhrases = constraints.filter { $0.isActive && $0.kind == .mustInclude }
            .map { SampleScanner.tokens($0.text).filter { $0.count >= 2 && !genericKitWords.contains($0) } }
            .filter { !$0.isEmpty }
        let goalWords = SampleScanner.tokens(goal).filter { $0.count >= 4 && !styleWords.contains($0) }

        var files = index.files
        if !avoid.isEmpty {
            files = files.filter { f in
                let p = f.path.lowercased()
                return !avoid.contains { p.contains($0) }
            }
        }
        // Kits that have at least a kick and something for the backbeat come first.
        var kits = Dictionary(grouping: files, by: \.group)
        func matches(_ kit: String) -> Bool {
            let words = Set(SampleScanner.tokens(kit))
            if includePhrases.contains(where: { $0.allSatisfy { words.contains($0) } }) { return true }
            return goalWords.contains { words.contains($0) }
        }
        if !includePhrases.isEmpty || !goalWords.isEmpty {
            let named = kits.filter { k, _ in matches(k) }
            if !named.isEmpty { kits = named }
        }
        let complete = kits.filter { _, fs in
            fs.contains { $0.role == .kick } && fs.contains { $0.role == .snare || $0.role == .clap }
        }
        let names = (complete.isEmpty ? Array(kits.keys) : Array(complete.keys)).sorted()
        guard !names.isEmpty else { return [:] }
        let kitName = names[min(names.count - 1, Int((kit * Double(names.count)).rounded(.down)))]
        let kitFiles = kits[kitName] ?? []

        var rng = SplitMix64(seed: seed ^ Compiler.seed(for: kitName))
        var out: [SampleRole: SampleFile] = [:]
        for role in SampleRole.allCases {
            let draw = rng.unit()
            var pool = kitFiles.filter { $0.role == role }
            // A missing sound comes from elsewhere in the library only when the kit has nothing that can
            // stand in for it (a kit with a clap but no snare plays the clap). Bass can always come from anywhere.
            let kitCovers = role.fallbacks.contains { r in kitFiles.contains { $0.role == r } }
            if pool.isEmpty, role == .bass || !kitCovers { pool = files.filter { $0.role == role } }
            if pool.isEmpty { continue }
            out[role] = pool[min(pool.count - 1, Int(draw * Double(pool.count)))]
        }
        return out
    }

    private func run(_ request: CompiledRequest) async throws -> Generated {
        let index = BeatsLibrary.shared.index
        guard !index.isEmpty else {
            throw PrismError.local("No samples yet. Open Settings → Sounds, and add your Native Instruments folders with Add Folders….")
        }
        let state = request.input.state
        let p = BeatParameters(dials: state.dials)
        let style = Self.style(for: state)
        let chosen = Self.choose(from: index, goal: state.goal, constraints: state.constraints, kit: p.kit, seed: request.seed)
        guard chosen[.kick] != nil || chosen[.snare] != nil || chosen[.clap] != nil else {
            throw PrismError.local("None of your samples fit as drums after the requirements were applied. Check the Must avoid requirements or add more folders.")
        }
        let bars = request.input.quality == .preview ? Self.previewBars : Self.renderBars
        let plan = BeatComposer.compose(style: style, seed: request.seed, parameters: p, bars: bars)
        try Task.checkCancellation()

        var sounds: [SampleRole: StereoAudio] = [:]
        var unreadable: [String] = []
        for (role, file) in chosen {
            do { sounds[role] = try SampleCache.shared.audio(for: file.path) }
            catch { unreadable.append(file.name) }
        }
        if sounds.isEmpty {
            throw PrismError.local("The samples couldn't be read. Is the drive with your sounds connected? (\(unreadable.prefix(3).joined(separator: ", ")))")
        }
        if p.bass <= 0.06 { sounds[.bass] = nil }
        try Task.checkCancellation()
        let audio = BeatMixer.mix(plan, sounds: sounds, tone: p.tone)
        let wav = BeatAudio.wav(audio)
        let midi = BeatMIDI.file(plan)

        var lines = ["**\(plan.style.name)** · \(Int(plan.bpm)) BPM · \(plan.bars) bars", ""]
        for role in SampleRole.allCases {
            if role == .bass && p.bass <= 0.06 { continue }
            if let f = chosen[role], sounds[role] != nil {
                lines.append("- \(role.label): \(f.name) — \(f.group)")
            } else if role == .bass {
                lines.append("- Bass: built-in sine sub (no bass samples found)")
            }
        }
        if !unreadable.isEmpty { lines += ["", "Couldn't read: \(unreadable.joined(separator: ", "))"] }
        let kits = Set(chosen.values.map(\.group)).sorted().joined(separator: ", ")
        return Generated(
            output: Output(kind: .audio, text: lines.joined(separator: "\n"), provider: "Ethers Prism Beats",
                           model: kits.isEmpty ? "your samples" : kits, agent: "Beat Maker"),
            asset: wav, assetExtension: "wav", extraAssets: ["mid": midi])
    }
}
