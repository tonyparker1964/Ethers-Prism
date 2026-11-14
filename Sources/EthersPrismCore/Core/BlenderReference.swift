import Foundation

/// The Blender cheat sheet (Docs/Blender-Cheat-Sheet.md), built into the app so agents can use it offline.
/// The text itself lives in BlenderReferenceText.swift, made by scripts/sync-blender-reference.py.
public enum BlenderReference {
    /// Where "Cheat Sheet" saves a copy, e.g. to add to a Claude project's knowledge.
    public static var savedPath = NSString(string: "~/Documents/Ethers Prism Exports/Blender Cheat Sheet.md").expandingTildeInPath

    /// Words that mean a goal is about Blender, so the Coder gets the cheat sheet.
    static let cues = ["blender", "bpy", "grease pencil", "greasepencil", "line art", "lineart", "eevee", "cycles render"]

    /// True when a goal is about Blender.
    public static func isAbout(_ goal: String) -> Bool {
        let g = goal.lowercased()
        return cues.contains { g.contains($0) }
    }

    /// Added to an agent's instructions when it writes Blender code.
    public static var agentAddition: String {
        """


        This task is Blender Python. The person uses Blender 5.2 on a Mac and runs scripts in the background \
        (blender -b --factory-startup --python). Prefer the bpy.data API over bpy.ops, and follow this reference:

        \(text)
        """
    }

    /// Saves the cheat sheet as a Markdown file and returns its path.
    @discardableResult
    public static func save() throws -> String {
        let dir = (savedPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try text.write(toFile: savedPath, atomically: true, encoding: .utf8)
        return savedPath
    }
}
