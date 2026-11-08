import Foundation

/// What the person likes, learned from their ratings of beats. Kept in a small file on this Mac only.
/// A liked beat raises the score of every sample and kit in it and remembers its dial positions for
/// that style; a "not for me" lowers the scores. Changing a rating undoes the old one first.
public struct TasteProfile: Codable, Hashable, Sendable {
    public var sampleScores: [String: Int]
    public var kitScores: [String: Int]
    /// Style id → dial key → sum of positions (0...100) in liked beats.
    public var dialSums: [String: [String: Double]]
    /// Style id → how many liked beats are in the sums.
    public var likedCounts: [String: Int]

    public init() {
        sampleScores = [:]
        kitScores = [:]
        dialSums = [:]
        likedCounts = [:]
    }

    public var isEmpty: Bool { sampleScores.isEmpty && kitScores.isEmpty }

    static let dialKeys = ["tempo", "swing", "density", "variation", "tone", "bass"]

    public func score(sample path: String) -> Int { sampleScores[path] ?? 0 }
    public func score(kit name: String) -> Int { kitScores[name] ?? 0 }

    /// Moves a beat's rating from `old` to `new` (each -1, 0 or +1).
    public mutating func rate(samples: [String], kits: [String], style: String, dials: BeatParameters, from old: Int, to new: Int) {
        let delta = new - old
        guard delta != 0 else { return }
        for s in samples { sampleScores[s, default: 0] += delta }
        for k in Set(kits) { kitScores[k, default: 0] += delta }
        sampleScores = sampleScores.filter { $0.value != 0 }
        kitScores = kitScores.filter { $0.value != 0 }

        let values: [String: Double] = ["tempo": dials.tempo, "swing": dials.swing, "density": dials.density,
                                        "variation": dials.variation, "tone": dials.tone, "bass": dials.bass]
        if old == 1 || new == 1 {
            let sign: Double = new == 1 ? 1 : -1
            var sums = dialSums[style] ?? [:]
            for (k, v) in values { sums[k, default: 0] += sign * v * 100 }
            dialSums[style] = sums
            likedCounts[style, default: 0] += Int(sign)
            if (likedCounts[style] ?? 0) <= 0 {
                likedCounts[style] = nil
                dialSums[style] = nil
            }
        }
    }

    /// Average dial positions of liked beats in this style, once there are at least two.
    public func likedDials(style: String) -> [String: Double] {
        guard let n = likedCounts[style], n >= 2, let sums = dialSums[style] else { return [:] }
        return sums.mapValues { Dial.clamp(($0 / Double(n)).rounded()) }
    }

    public var likedKits: [String] { kitScores.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map(\.key) }
    public var dislikedKits: [String] { kitScores.filter { $0.value < 0 }.sorted { $0.value < $1.value }.map(\.key) }
}
