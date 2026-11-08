import Foundation

/// Small, fast, repeatable random numbers: the same seed always gives the same beat.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number from 0 up to (not including) 1.
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// A genre's starting groove. Each line is 16 steps: x = always, o = sometimes, . = only when busy.
public struct BeatStyle: Hashable, Sendable {
    public var id: String
    public var name: String
    public var keywords: [String]
    public var tempo: ClosedRange<Double>
    public var lines: [SampleRole: String]
    public var hatRolls: Bool
    public var swingBase: Double
    public var humanize: Double
    /// How long bass notes can ring, in 16th steps.
    public var bassLength: Double

    public static let all: [BeatStyle] = [boomBap, trap, house, techno, drumAndBass, lofi, afro, reggaeton]
    public static let fallback = boomBap

    /// The first style whose keywords appear in the goal as whole words ("trap" doesn't count as "rap").
    public static func detect(in goal: String) -> BeatStyle {
        let g = " " + words(goal) + " "
        for style in all where style.keywords.contains(where: { g.contains(" " + words($0) + " ") }) { return style }
        return fallback
    }

    static func words(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    public static let boomBap = BeatStyle(
        id: "boombap", name: "Boom bap", keywords: ["boom bap", "boombap", "hip hop", "hip-hop", "hiphop", "rap", "90s"],
        tempo: 82...98,
        lines: [.kick: "x......o..x..o..", .snare: "....x.......x...", .closedHat: "x.x.x.x.x.x.x.x.",
                .openHat: "..............o.", .perc: "......o.......o."],
        hatRolls: false, swingBase: 0.15, humanize: 0.3, bassLength: 3)

    public static let trap = BeatStyle(
        id: "trap", name: "Trap", keywords: ["trap", "drill", "808"],
        tempo: 130...160,
        lines: [.kick: "x......x..o.....", .snare: "........x.......", .clap: "........x.......",
                .closedHat: "x.x.x.x.x.x.x.x.", .openHat: "..............o.", .perc: "...o.......o...."],
        hatRolls: true, swingBase: 0, humanize: 0.05, bassLength: 8)

    public static let house = BeatStyle(
        id: "house", name: "House", keywords: ["house", "disco", "garage", "dance"],
        tempo: 118...128,
        lines: [.kick: "x...x...x...x...", .clap: "....x.......x...", .closedHat: "o.x.o.x.o.x.o.x.",
                .openHat: "..x...x...x...x.", .perc: "...o.....o...o.."],
        hatRolls: false, swingBase: 0.08, humanize: 0.05, bassLength: 2)

    public static let techno = BeatStyle(
        id: "techno", name: "Techno", keywords: ["techno", "industrial", "warehouse", "rave"],
        tempo: 124...140,
        lines: [.kick: "x...x...x...x...", .clap: "....o.......o...", .closedHat: "..x...x...x...x.",
                .openHat: "..o...o...o...o.", .perc: "o.o.o.o.o.o.o.o."],
        hatRolls: false, swingBase: 0, humanize: 0.03, bassLength: 1.5)

    public static let drumAndBass = BeatStyle(
        id: "dnb", name: "Drum and bass", keywords: ["drum and bass", "drum & bass", "drum n bass", "dnb", "jungle", "liquid"],
        tempo: 165...178,
        lines: [.kick: "x.........x.....", .snare: "....x.......x...", .closedHat: "x.x.x.x.x.x.x.x.",
                .openHat: "......o.......o.", .perc: "..o.......o....."],
        hatRolls: false, swingBase: 0.02, humanize: 0.08, bassLength: 4)

    public static let lofi = BeatStyle(
        id: "lofi", name: "Lo-fi", keywords: ["lofi", "lo-fi", "lo fi", "chill", "study", "jazzy", "dusty"],
        tempo: 70...88,
        lines: [.kick: "x.......o.x.....", .snare: "....x.......x...", .closedHat: "x.x.x.x.x.x.x.x.",
                .openHat: "..............o.", .perc: "...o.......o...."],
        hatRolls: false, swingBase: 0.35, humanize: 0.5, bassLength: 4)

    public static let afro = BeatStyle(
        id: "afro", name: "Afro / amapiano", keywords: ["afro", "amapiano", "afrobeat", "afrobeats", "afro house"],
        tempo: 105...118,
        lines: [.kick: "x...x...x...x...", .snare: "......x.......x.", .closedHat: "x.xxx.xxx.xxx.xx",
                .openHat: "..o.......o.....", .perc: "x..x..x...x..x.."],
        hatRolls: false, swingBase: 0.12, humanize: 0.15, bassLength: 3)

    public static let reggaeton = BeatStyle(
        id: "reggaeton", name: "Reggaeton", keywords: ["reggaeton", "dembow", "latin", "dancehall"],
        tempo: 88...100,
        lines: [.kick: "x...x...x...x...", .snare: "...x..x....x..x.", .closedHat: "x.x.x.x.x.x.x.x.",
                .openHat: "..............o.", .perc: "..o...o...o...o."],
        hatRolls: false, swingBase: 0, humanize: 0.08, bassLength: 3)
}

/// The dial values a beat is made from, each 0...1.
public struct BeatParameters: Hashable, Sendable {
    public var tempo: Double
    public var swing: Double
    public var density: Double
    public var variation: Double
    public var tone: Double
    public var bass: Double
    public var kit: Double
    public var pattern: Double

    public init(tempo: Double = 0.5, swing: Double = 0.3, density: Double = 0.5, variation: Double = 0.4,
                tone: Double = 0.6, bass: Double = 0.5, kit: Double = 0, pattern: Double = 0) {
        self.tempo = tempo
        self.swing = swing
        self.density = density
        self.variation = variation
        self.tone = tone
        self.bass = bass
        self.kit = kit
        self.pattern = pattern
    }

    /// Reads dials by name, so renamed or reordered dials still work.
    public init(dials: [Dial]) {
        func v(_ key: String, _ fallback: Double) -> Double {
            (dials.first { $0.name.lowercased().contains(key) }?.value ?? fallback * 100) / 100
        }
        self.init(tempo: v("tempo", 0.5), swing: v("swing", 0.3), density: v("density", 0.5),
                  variation: v("variation", 0.4), tone: v("tone", 0.6), bass: v("bass", 0.5),
                  kit: v("kit", 0), pattern: v("pattern", 0))
    }
}

/// One hit. Time is in 16th-note steps from the start; bass notes carry a pitch and a length.
public struct BeatEvent: Hashable, Sendable {
    public var role: SampleRole
    public var time: Double
    public var velocity: Double
    public var semitones: Double
    public var length: Double

    public init(role: SampleRole, time: Double, velocity: Double, semitones: Double = 0, length: Double = 0) {
        self.role = role
        self.time = time
        self.velocity = velocity
        self.semitones = semitones
        self.length = length
    }
}

/// A composed beat, ready to mix and to write as MIDI.
public struct BeatPlan: Hashable, Sendable {
    public var style: BeatStyle
    public var bpm: Double
    public var bars: Int
    public var events: [BeatEvent]

    public var steps: Int { bars * 16 }
    public var secondsPerStep: Double { 60 / bpm / 4 }
}

public enum BeatComposer {
    /// Extra hits each role can gain when the beat gets busy.
    static let extras: [SampleRole: Double] = [.kick: 0.18, .snare: 0.14, .clap: 0.05, .closedHat: 0.85,
                                               .openHat: 0.12, .perc: 0.4]
    static let scale: [Double] = [0, 0, 0, 7, 3, 5, 10, -2, 12]

    /// The same style, seed, parameters and bar count always give the same beat.
    /// Every step draws the same amount of randomness whatever the dials say, so turning a dial
    /// changes the beat smoothly instead of reshuffling it.
    public static func compose(style: BeatStyle, seed: UInt64, parameters p: BeatParameters, bars: Int) -> BeatPlan {
        let bpm = (style.tempo.lowerBound + (style.tempo.upperBound - style.tempo.lowerBound) * p.tempo).rounded()
        let patternSeed = seed &+ UInt64(Int((p.pattern * 9).rounded())) &* 0x632B_E59B_D9B4_E019
        let period: Int = p.variation < 0.25 ? 1 : (p.variation < 0.5 ? 2 : (p.variation < 0.75 ? 4 : 1_000))
        let swingAmount = min(0.45, style.swingBase + p.swing * 0.33)
        var events: [BeatEvent] = []
        let order: [SampleRole] = [.kick, .snare, .clap, .closedHat, .openHat, .perc]

        for bar in 0..<max(1, bars) {
            let shape = bar % period
            var rng = SplitMix64(seed: patternSeed &+ UInt64(shape) &* 0xD1B5_4A32_D192_ED03)
            var feel = SplitMix64(seed: patternSeed ^ (UInt64(bar) &* 0x9E37_79B9_7F4A_7C15))
            let isFillBar = bar % 4 == 3
            let base = Double(bar * 16)
            var barEvents: [BeatEvent] = []

            for role in order {
                let line = Array(style.lines[role] ?? "")
                for step in 0..<16 {
                    let draw = rng.unit()
                    let rollDraw = rng.unit()
                    guard step < line.count else { continue }
                    let c = line[step]
                    let p0: Double
                    let vel: Double
                    switch c {
                    case "x": p0 = p.density < 0.12 && step % 4 != 0 && role == .closedHat ? 0 : 1; vel = step % 4 == 0 ? 1 : 0.88
                    case "o": p0 = 0.15 + 0.8 * p.density; vel = 0.72
                    default: p0 = (extras[role] ?? 0) * pow(p.density, 1.6); vel = role == .snare ? 0.32 : 0.5
                    }
                    guard draw < p0 else { continue }
                    barEvents.append(BeatEvent(role: role, time: base + Double(step), velocity: vel))
                    // Hat rolls: two or three quick repeats inside one step.
                    if style.hatRolls, role == .closedHat, rollDraw < p.variation * 0.35 {
                        let n = rollDraw < p.variation * 0.15 ? 3 : 2
                        for k in 1..<n {
                            barEvents.append(BeatEvent(role: role, time: base + Double(step) + Double(k) / Double(n),
                                                       velocity: vel * (1 - 0.15 * Double(k))))
                        }
                    }
                }
            }

            // A short fill at the end of every four bars, more likely as variation rises.
            var fillRng = SplitMix64(seed: patternSeed ^ 0xF111 &+ UInt64(bar))
            let fillChance = fillRng.unit()
            if isFillBar, bars > 1, fillChance < p.variation * 1.2 - 0.1 {
                barEvents.removeAll { $0.time >= base + 12 && ($0.role == .snare || $0.role == .closedHat) }
                for step in 12..<16 {
                    let d = fillRng.unit()
                    if d < 0.55 + 0.4 * p.variation {
                        let role: SampleRole = d < 0.3 ? .tom : .snare
                        barEvents.append(BeatEvent(role: role, time: base + Double(step), velocity: 0.55 + 0.1 * Double(step - 12)))
                    }
                }
            }
            if bar > 0, bar % 4 == 0, p.variation > 0.2 {
                barEvents.append(BeatEvent(role: .cymbal, time: base, velocity: 0.8))
            }

            // Bass follows the kick and picks notes from a simple minor scale.
            if p.bass > 0.06 {
                let kicks = barEvents.filter { $0.role == .kick }.map(\.time).sorted()
                for (i, t) in kicks.enumerated() {
                    let d = rng.unit()
                    let degree = d < 1 - p.variation * 0.8 ? 0 : scale[min(scale.count - 1, Int(d * Double(scale.count)))]
                    let next = i + 1 < kicks.count ? kicks[i + 1] : base + 16
                    let length = max(0.75, min(style.bassLength, next - t))
                    barEvents.append(BeatEvent(role: .bass, time: t, velocity: 0.55 + 0.45 * p.bass,
                                               semitones: degree, length: length))
                }
            }

            // Swing pushes every second 16th later; humanize loosens timing and loudness.
            for i in barEvents.indices {
                let step = barEvents[i].time - base
                let wholeStep = step.rounded(.down)
                if Int(wholeStep) % 2 == 1, step == wholeStep { barEvents[i].time += swingAmount }
                let jitter = (feel.unit() * 2 - 1) * style.humanize * 0.07
                let soften = 1 - style.humanize * 0.3 * feel.unit()
                if !(barEvents[i].role == .kick && step == 0) { barEvents[i].time = max(0, barEvents[i].time + jitter) }
                barEvents[i].velocity = min(1, max(0.05, barEvents[i].velocity * soften))
            }
            events += barEvents
        }
        events.sort { $0.time == $1.time ? $0.role.rawValue < $1.role.rawValue : $0.time < $1.time }
        return BeatPlan(style: style, bpm: bpm, bars: max(1, bars), events: events)
    }
}
