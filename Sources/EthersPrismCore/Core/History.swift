import Foundation

public struct TreeRow: Identifiable, Hashable, Sendable {
    public var snapshot: Snapshot
    public var depth: Int
    public var id: UUID { snapshot.id }
}

/// History is a tree: go back to any state and branch without losing other branches.
extension Session {
    public var currentSnapshot: Snapshot? { currentSnapshotID.flatMap { snapshot($0) } }

    public func snapshot(_ id: UUID) -> Snapshot? { snapshots.first { $0.id == id } }

    public func children(of id: UUID?) -> [Snapshot] { snapshots.filter { $0.parentID == id } }

    /// Saves a new state as a child of the current state (or of `parent` when given).
    /// `state` is the working state the request was made from; the live dials are not touched.
    @discardableResult
    public mutating func record(_ output: Output, origin: Origin, state: WorkingState? = nil,
                                note: String? = nil, date: Date = Date()) -> Snapshot {
        recordChild(of: currentSnapshotID, output, origin: origin, state: state, note: note, date: date)
    }

    @discardableResult
    public mutating func recordChild(of parent: UUID?, _ output: Output, origin: Origin, state: WorkingState? = nil,
                                     note: String? = nil, date: Date = Date()) -> Snapshot {
        let snap = Snapshot(parentID: parent, createdAt: date, state: state ?? workingState,
                            origin: origin, output: output, note: note)
        snapshots.append(snap)
        currentSnapshotID = snap.id
        updatedAt = date
        return snap
    }

    /// Saves hand edits to the current text as a new state. The edited state is never overwritten later.
    @discardableResult
    public mutating func recordManualEdit(text: String, date: Date = Date()) -> Snapshot? {
        guard let cur = currentSnapshot, cur.output.text != nil, cur.output.text != text else { return nil }
        var out = cur.output
        out.text = text
        return recordChild(of: cur.id, out, origin: .manualEdit, state: cur.state, note: nil, date: date)
    }

    /// Returns to an earlier state, including its goal, dials and constraints.
    public mutating func restore(_ id: UUID) {
        guard let snap = snapshot(id) else { return }
        workingState = snap.state
        title = goal.trimmed.isEmpty ? "Untitled" : String(goal.trimmed.prefix(48))
        currentSnapshotID = id
    }

    public mutating func toggleChosen(_ id: UUID) {
        if let i = snapshots.firstIndex(where: { $0.id == id }) { snapshots[i].chosen.toggle() }
    }

    public func path(to id: UUID) -> [Snapshot] {
        var result: [Snapshot] = []
        var cursor: UUID? = id
        var steps = 0
        while let c = cursor, let snap = snapshot(c), steps <= snapshots.count {
            result.append(snap)
            cursor = snap.parentID
            steps += 1
        }
        return result.reversed()
    }

    /// A straight line of edits stays at one depth; each extra branch indents one level.
    public func treeRows() -> [TreeRow] {
        var rows: [TreeRow] = []
        func visit(_ parent: UUID?, _ depth: Int) {
            for (i, child) in children(of: parent).enumerated() {
                let d = i == 0 ? depth : depth + 1
                rows.append(TreeRow(snapshot: child, depth: d))
                visit(child.id, d)
            }
        }
        visit(nil, 0)
        return rows
    }

    public func summary(for snap: Snapshot) -> String {
        if snap.origin == .manualEdit { return "manual edit" }
        if let note = snap.note { return note }
        guard let pid = snap.parentID, let parent = snapshot(pid) else { return "start" }
        let c = StateDiff.changes(from: parent.state, to: snap.state)
        if c.isEmpty { return snap.origin == .render ? "full render" : "same settings" }
        return c.joined(separator: ", ")
    }

    // MARK: Editing the editor

    public mutating func addDial(_ dial: Dial) { dials.append(dial) }

    public mutating func removeDial(_ id: UUID) { dials.removeAll { $0.id == id } }

    public mutating func updateDial(_ dial: Dial) {
        if let i = dials.firstIndex(where: { $0.id == dial.id }) { dials[i] = dial }
    }

    /// Moves a dial up (negative) or down (positive) in the list.
    public mutating func moveDial(_ id: UUID, by offset: Int) {
        guard let i = dials.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), dials.count - 1)
        guard i != j else { return }
        let d = dials.remove(at: i)
        dials.insert(d, at: j)
    }

    /// Nudges every unlocked dial by up to ±spread. Locked dials never move.
    public mutating func nudgeUnlocked<G: RandomNumberGenerator>(spread: Double, using rng: inout G) {
        for i in dials.indices where !dials[i].locked {
            dials[i].value = (dials[i].value + Double.random(in: -spread...spread, using: &rng)).rounded()
        }
    }
}

/// Human-readable differences between two states.
public enum StateDiff {
    public static func changes(from a: WorkingState, to b: WorkingState) -> [String] {
        var out: [String] = []
        if a.goal.trimmed != b.goal.trimmed { out.append("goal changed") }
        if a.domainID != b.domainID { out.append("field \(a.domainID)→\(b.domainID)") }
        out += dialChanges(from: a.dials, to: b.dials)
        out += constraintChanges(from: a.constraints, to: b.constraints)
        return out
    }

    public static func dialChanges(from old: [Dial], to new: [Dial]) -> [String] {
        var out: [String] = []
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for d in new {
            if let o = oldByID[d.id] {
                if o.name != d.name { out.append("renamed \(o.name)→\(d.name)") }
                if o.lowPole != d.lowPole || o.highPole != d.highPole { out.append("redefined \(d.name)") }
                if o.intValue != d.intValue { out.append("\(d.name) \(o.intValue)→\(d.intValue)") }
            } else {
                out.append("+ \(d.name)")
            }
        }
        let ids = Set(new.map(\.id))
        for o in old where !ids.contains(o.id) { out.append("− \(o.name)") }
        return out
    }

    public static func constraintChanges(from old: [Constraint], to new: [Constraint]) -> [String] {
        let a = Set(old.filter(\.isActive).map { "\($0.kind.label): \($0.text.trimmed)" })
        let b = Set(new.filter(\.isActive).map { "\($0.kind.label): \($0.text.trimmed)" })
        return b.subtracting(a).sorted().map { "+ \($0)" } + a.subtracting(b).sorted().map { "− \($0)" }
    }
}

// MARK: - Sweep

public struct SweepVariant: Hashable, Sendable {
    public var value: Double
    public var state: WorkingState
}

public enum Sweep {
    public static let positions: [Double] = [0, 25, 50, 75, 100]

    /// Five states that differ only in one dial's value. Everything else, constraints included, is held fixed.
    public static func variants(of state: WorkingState, dialID: UUID) throws -> [SweepVariant] {
        guard let i = state.dials.firstIndex(where: { $0.id == dialID }) else { throw PrismError.dialNotFound }
        guard !state.dials[i].locked else { throw PrismError.dialLocked }
        return positions.map { v in
            var s = state
            s.dials[i].value = v
            return SweepVariant(value: v, state: s)
        }
    }
}

// MARK: - Stale responses

/// Hands out tickets so only the newest request may update the screen.
public final class GenerationGate: @unchecked Sendable {
    private var latest = 0
    private let lock = NSLock()

    public init() {}

    public func begin() -> Int {
        lock.lock(); defer { lock.unlock() }
        latest += 1
        return latest
    }

    public func isCurrent(_ ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ticket == latest
    }

    /// Makes every outstanding ticket stale.
    public func invalidate() { _ = begin() }
}

public enum PrismError: LocalizedError, Equatable {
    case missingAPIKey
    case missingImageProvider
    case badDialJSON
    case emptyResponse
    case http(Int, String)
    case comfy(String)
    case dialLocked
    case dialNotFound
    case unsupportedVersion(Int)
    case invalidFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key is set. Add one in Settings (⌘,), or switch the text provider to Mock."
        case .missingImageProvider:
            return "No image provider is set up. Choose ComfyUI, Claude SVG or Mock in Settings (⌘,)."
        case .badDialJSON:
            return "The dial suggestions couldn't be read. Try Suggest Dials again."
        case .emptyResponse:
            return "The provider returned an empty response."
        case .http(let code, let body):
            return "The provider returned an error (\(code)). \(body.prefix(300))"
        case .comfy(let message):
            return "ComfyUI: \(message)"
        case .dialLocked:
            return "Unlock this dial before sweeping it."
        case .dialNotFound:
            return "That dial no longer exists."
        case .unsupportedVersion(let v):
            return "This file was made by a newer version of Ethers Prism (format \(v))."
        case .invalidFile(let why):
            return "This file can't be opened: \(why)"
        }
    }
}
