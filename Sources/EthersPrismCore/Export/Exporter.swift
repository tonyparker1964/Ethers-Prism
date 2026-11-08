import Foundation

/// A readable record of how a result was reached.
public enum Exporter {
    public static func authorshipLog(_ session: Session, adapterName: String, exportedAt: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let final = session.currentSnapshot else {
            return "# \(session.title)\n\nNo result has been generated yet.\n"
        }
        let path = session.path(to: final.id)
        let edits = path.filter { $0.origin == .manualEdit }.count
        var l: [String] = [
            "# Authorship log: \(session.title)",
            "",
            "This log records the creative process inside Ethers Prism: the goal, the editor the person built,",
            "the states they explored and the result they selected. It describes the process only and makes",
            "no legal claim about ownership or copyright.",
            "",
            "- **Goal:** \(final.state.goal.trimmed)",
            "- **Field:** \(adapterName)",
            "- **Exported:** \(f.string(from: exportedAt))",
            "- **States explored in this session:** \(session.snapshots.count) (\(path.count) on the selected branch)",
            "- **Manual edits on the selected branch:** \(edits)",
            "",
            "## Dials at the final selection"
        ]
        l += final.state.dials.map(Compiler.describe)
        let fixed = Compiler.describe(final.state.constraints)
        l += ["", "## Fixed requirements", fixed.isEmpty ? "(none)" : fixed]

        l += ["", "## Selected branch"]
        for (i, s) in path.enumerated() {
            let values = s.state.dials.map { "\($0.name) \($0.intValue)" }.joined(separator: " · ")
            let star = s.chosen ? " ★" : ""
            l.append("\(i + 1). \(f.string(from: s.createdAt)) — \(s.origin.label)\(star): \(session.summary(for: s))")
            if !values.isEmpty { l.append("   Values: \(values)") }
            var meta = "   Made with: \(s.output.agent.map { "\($0) — " } ?? "")\(s.output.provider)"
            if !s.output.model.isEmpty { meta += " · \(s.output.model)" }
            if let pm = s.output.promptModel { meta += " (prompt by \(pm))" }
            l.append(meta)
            if let r = s.output.review {
                l.append("   Checked by \(r.reviewer): " + (r.passed ? "meets the fixed requirements" : "flagged " + r.issues.joined(separator: "; ")))
            }
        }

        l += ["", "## Final selection", "\(final.origin.label) from \(f.string(from: final.createdAt))\(final.chosen ? ", marked as chosen" : "")."]
        if let prompt = final.output.imagePrompt { l += ["", "Image prompt:", "> \(prompt)"] }
        if let text = final.output.text { l += ["", "## Result", "", text] }
        if let asset = final.output.assetPath { l += ["", "Image file: \((asset as NSString).lastPathComponent)"] }
        return l.joined(separator: "\n") + "\n"
    }

    /// Suggested file name and contents for the selected result.
    public static func resultFile(_ snapshot: Snapshot, store: Store) -> (ext: String, data: Data)? {
        switch snapshot.output.kind {
        case .image:
            guard let url = store.assetURL(snapshot.output.assetPath), let data = try? Data(contentsOf: url) else { return nil }
            return (url.pathExtension, data)
        case .code:
            return ("txt", Data((snapshot.output.text ?? "").utf8))
        case .text, .storyboard:
            return ("md", Data((snapshot.output.text ?? "").utf8))
        }
    }

    public static func safeFileName(_ title: String) -> String {
        let cleaned = title.map { "/\\:*?\"<>|".contains($0) ? "-" : $0 }
        let s = String(cleaned).trimmed
        return s.isEmpty ? "Ethers Prism" : String(s.prefix(60))
    }
}
