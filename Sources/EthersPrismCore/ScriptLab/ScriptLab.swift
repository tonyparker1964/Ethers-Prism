import Foundation

/// Script Lab: Python scripts that make brushes, colours and strokes with PRISM's `prism_gp` library,
/// run in Blender (no window) and come back as a still or a video.
public enum ScriptLab {
    public struct Output: Sendable {
        public var still: URL?
        public var movie: URL?
        public var log: String
        public var info: String
    }

    public struct ScriptError: LocalizedError, Sendable {
        public var message: String
        /// Line in the user's script, when Python says where.
        public var line: Int?
        public var errorDescription: String? { message }
    }

    /// What PRISM puts in front of every script: the library on the path and the chosen picture.
    public static func header(libraryFolder: String, picture: String?) -> String {
        """
        import sys
        sys.path.insert(0, r"\(libraryFolder)")
        import prism_gp
        prism_gp.IMAGE = r"\(picture ?? "")"
        from prism_gp import *

        """
    }

    /// Lines the header adds (error line numbers are shifted back by this).
    static let headerLines = 5

    /// Rewrites Python's line numbers so they point at the user's script, and returns the last one.
    public static func mapError(_ text: String) -> (message: String, line: Int?) {
        var lastLine: Int?
        var lines: [String] = []
        let pattern = try! NSRegularExpression(pattern: #"File "script\.py", line (\d+)"#)
        for l in text.components(separatedBy: .newlines) {
            let ns = l as NSString
            if let m = pattern.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)),
               let n = Int(ns.substring(with: m.range(at: 1))) {
                let mapped = max(1, n - headerLines)
                lastLine = mapped
                lines.append(pattern.stringByReplacingMatches(in: l, range: NSRange(location: 0, length: ns.length),
                                                              withTemplate: "Line \(mapped)"))
            } else if l.contains("prism_gp.py") {
                lines.append(l.replacingOccurrences(of: #"File ".*prism_gp\.py""#, with: "prism_gp", options: .regularExpression))
            } else {
                lines.append(l)
            }
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), lastLine)
    }

    /// Runs a script. `video` renders the whole animation as MP4; otherwise one still at `frame` (0…1 of
    /// the animation, 1 = the finished drawing). Results are kept in `keepIn`.
    public static func run(code: String, picture: String?, video: Bool, frame: Double = 1, fullSize: Bool = false,
                           keepIn: URL, title: String) async throws -> Output {
        let blender = BlenderStageAdapter.blenderPath
        guard FileManager.default.isExecutableFile(atPath: blender) else {
            throw ScriptError(message: "Blender wasn't found in /Applications. Install Blender to use Script Lab.", line: nil)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrismScriptLab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try library.write(to: dir.appendingPathComponent("prism_gp.py"), atomically: true, encoding: .utf8)
        let user = dir.appendingPathComponent("user_script.py")
        try (header(libraryFolder: dir.path, picture: picture) + BlenderScriptAdapter.sanitized(code))
            .write(to: user, atomically: true, encoding: .utf8)
        let runner = dir.appendingPathComponent("runner.py")
        try BlenderScriptAdapter.runner.write(to: runner, atomically: true, encoding: .utf8)

        let params: [String: Any] = ["script": user.path, "out": dir.appendingPathComponent("render").path,
                                     "error": dir.appendingPathComponent("error.txt").path,
                                     "frame": min(max(frame, 0), 1), "quality": 0.5, "preview": !video && !fullSize]
        let args = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8) ?? "{}"
        let log = dir.appendingPathComponent("blender.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: blender)
        process.arguments = ["-b", "--factory-startup", "--python", runner.path, "--", args]
        process.standardOutput = handle
        process.standardError = handle
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()

        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let shown = text.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("PRISM") || $0.contains("Error") || $0.hasPrefix("Traceback") }
            .joined(separator: "\n")
        if let err = try? String(contentsOf: dir.appendingPathComponent("error.txt"), encoding: .utf8), !err.trimmed.isEmpty {
            let mapped = mapError(err)
            throw ScriptError(message: mapped.message, line: mapped.line)
        }
        let info = text.components(separatedBy: .newlines).filter { $0.hasPrefix("PRISM: ") }
            .map { String($0.dropFirst(7)) }.joined(separator: " ")
        try FileManager.default.createDirectory(at: keepIn, withIntermediateDirectories: true)
        let stamp = Self.stamp()
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined(separator: "-")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if video, let name = files.first(where: { $0.lowercased().hasSuffix(".mp4") }) {
            let dest = keepIn.appendingPathComponent("\(stamp) \(safe).mp4")
            try FileManager.default.copyItem(at: dir.appendingPathComponent(name), to: dest)
            return Output(still: nil, movie: dest, log: shown, info: info)
        }
        let png = dir.appendingPathComponent("render.png")
        guard FileManager.default.fileExists(atPath: png.path) else {
            let errors = text.components(separatedBy: .newlines).filter { $0.contains("Error") || $0.contains("rror:") }
            throw ScriptError(message: "Blender didn't produce a picture. " + (errors.isEmpty ? String(text.suffix(600)) : errors.joined(separator: "\n")),
                              line: nil)
        }
        let dest = keepIn.appendingPathComponent("\(stamp) \(safe).png")
        try FileManager.default.copyItem(at: png, to: dest)
        return Output(still: dest, movie: nil, log: shown, info: info)
    }

    static func stamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HHmmss"
        return df.string(from: Date())
    }

    // MARK: - My scripts

    public static func scripts(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "py" }
        return files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    @discardableResult
    public static func save(_ code: String, name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = name.trimmed.isEmpty ? "Untitled" : name.trimmed
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined(separator: "-")
        let url = folder.appendingPathComponent(safe.hasSuffix(".py") ? safe : safe + ".py")
        try code.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The library's API, for pasting into Claude with a script ("Copy for Claude").
    public static var apiReference: String {
        """
        PRISM Script Lab (Blender 5.x Grease Pencil, Python). `from prism_gp import *` is already done; IMAGE is the chosen picture's path.
        Coordinates are canvas pixels, origin top-left, y down. Sizes in pixels. Colours are "#rrggbb".
        canvas(width=None, height=None, background="#ffffff", seconds=4, fps=24)  # no size + a picture → picture's shape
        brush(name, kind="ink", color="#111111", size=6, opacity=None, taper=None, jitter=0, texture=None, softness=None, spacing=None)
            kinds: \(["ink", "pen", "marker", "pencil", "charcoal", "chalk", "bristle", "oil", "dry", "wash", "watercolor", "airbrush", "dots", "squares"].joined(separator: ", "))
        layer(name)  # later layers draw on top
        stroke(b, points, size=, color=, opacity=, pressure=[...], smooth=False, fill=False, close=False)
        strokes([dict(brush=b, points=..., size=..., color=...), ...])  # fast, thousands at once
        line(b, a, c) · circle(b, center, r, fill=False) · ellipse(b, center, rx, ry) · rect(b, x, y, w, h) · arc(b, center, r, start_deg, end_deg) · polygon(b, points)
        color(c) · mix(a, b, t) · lighten(c, t) · darken(c, t) · hsv(h, s, v) · gradient([colors], t) · picture_palette(n)
        load_picture(path=None, max_side=480) → H×W×3 array · plan_paint(pixels, sizes, ...) · plan_ink(pixels, ...)
        paint(brushes, picture=None, sizes=None, density=1, length=8, detail=0.5)  # repaints the picture, broad → fine
        ink(b, picture=None, threshold=0.3, detail=0.5)  # ink lines along edges
        draw_on(seconds=None, order="layers"|"together") · boil(amount) · glow(color, radius) · shadow(...) · effect(kind, **props) · modifier(kind, **props)
        numpy is np, plus math and random.
        """
    }
}
