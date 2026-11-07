import Foundation

/// History is a tree, not an undo stack: go back to any state and move a dial to branch.
extension Session {
    public var currentSnapshot: Snapshot? {
        currentSnapshotID.flatMap { snapshot($0) }
    }

    public func snapshot(_ id: UUID) -> Snapshot? {
        snapshots.first { $0.id == id }
    }

    /// Children in the order they were made.
    public func children(of id: UUID?) -> [Snapshot] {
        snapshots.filter { $0.parentID == id }
    }

    /// Records a new state as a child of the current one. `axes` defaults to the current dials;
    /// pass the dials that were actually used for the request if they may have moved since.
    @discardableResult
    public mutating func record(output: String, quality: Quality, axes used: [Dial]? = nil,
                                date: Date = Date()) -> Snapshot {
        let snap = Snapshot(parentID: currentSnapshotID, createdAt: date, axes: used ?? axes,
                            quality: quality, output: output)
        snapshots.append(snap)
        currentSnapshotID = snap.id
        updatedAt = date
        return snap
    }

    /// Returns to an earlier state, including its dial settings.
    public mutating func restore(_ id: UUID) {
        guard let snap = snapshot(id) else { return }
        axes = snap.axes
        currentSnapshotID = id
    }

    public mutating func toggleChosen(_ id: UUID) {
        if let i = snapshots.firstIndex(where: { $0.id == id }) {
            snapshots[i].chosen.toggle()
        }
    }

    /// Root-to-node path.
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

    /// Flattened tree for display. A straight line of edits stays at one depth;
    /// each alternative branch is indented one level.
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

    /// Human-readable dial changes between two states.
    public static func changes(from old: [Dial], to new: [Dial]) -> [String] {
        var out: [String] = []
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for axis in new {
            if let o = oldByID[axis.id] {
                if o.name != axis.name { out.append("renamed \(o.name)→\(axis.name)") }
                let a = Int(o.value.rounded()), b = Int(axis.value.rounded())
                if a != b { out.append("\(axis.name) \(a)→\(b)") }
            } else {
                out.append("+ \(axis.name)")
            }
        }
        let newIDs = Set(new.map(\.id))
        for o in old where !newIDs.contains(o.id) {
            out.append("− \(o.name)")
        }
        return out
    }

    public func summary(for snap: Snapshot) -> String {
        guard let pid = snap.parentID, let parent = snapshot(pid) else { return "start" }
        let c = Session.changes(from: parent.axes, to: snap.axes)
        if c.isEmpty { return snap.quality == .render ? "full render" : "same dials" }
        return c.joined(separator: ", ")
    }
}
