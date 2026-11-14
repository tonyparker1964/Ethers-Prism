import Foundation

/// True Trace: Grease Pencil rebuilds a picture from filled shapes and ink lines, in a chosen look.
/// No image model is involved: Blender traces the colours and edges and draws them as strokes.
/// Each run gives a finished still (PNG), a video of it drawing itself on (MP4) and an editable .blend.
public enum TrueTrace {

    /// A group of looks that Grease Pencil draws the same way.
    public enum Family: String, CaseIterable, Sendable {
        case faithful, anime, ink, flat, poster, paint, pixel, neon, blueprint, chalk

        public var title: String {
            switch self {
            case .faithful: return "Faithful trace"
            case .anime: return "Cel shading and line art"
            case .ink: return "Black-and-white ink"
            case .flat: return "Flat colour shapes"
            case .poster: return "Bold shapes and heavy outlines"
            case .paint: return "Soft painted shapes"
            case .pixel: return "Pixel blocks"
            case .neon: return "Glowing lines on dark"
            case .blueprint: return "White lines on blue"
            case .chalk: return "Chalk on a board"
            }
        }
    }

    /// Looks that need real 3D surfaces or photographs, which strokes can't make.
    static let notDrawable = [
        "photoreal", "cgi", "cinematic photography", "polaroid", "tilt-shift", "double exposure", "fashion editorial",
        "film still", "claymation", "clay render", "stop-motion", "vinyl toy", "glass and crystal", "sculpted metal",
        "marble statue", "porcelain", "wood carving", "balloon", "knitted", "needle felt", "toy brick", "origami 3d",
        "isometric diorama", "cinematic 3d animation", "donghua 3d", "3d cultivation", "3d sci-fi", "surreal minimal sculpture",
    ]

    /// Which family draws a Studio look, or nil when Grease Pencil can't make it.
    public static func family(look name: String, collection: String) -> Family? {
        let n = name.lowercased()
        if n.contains("cel-shaded") { return .anime }
        if notDrawable.contains(where: { n.contains($0) }) { return nil }
        let rules: [(Family, [String])] = [
            (.pixel, ["pixel", "voxel"]),
            (.blueprint, ["blueprint"]),
            (.chalk, ["chalkboard"]),
            (.neon, ["neon", "synthwave", "light painting", "cyberpunk", "vaporwave", "hologram"]),
            (.ink, ["manga", "ink wash", "ink-wash", "pencil and charcoal", "gekiga", "genga", "key-frame pencil", "noir"]),
            (.poster, ["stained glass", "mosaic", "tarot", "art deco", "art nouveau", "ukiyo-e", "pop art", "street art",
                       "psychedelic", "comic", "linocut", "graphic novel", "bande dessinée", "komiks", "kente", "persian miniature",
                       "gongbi", "embroidery", "risograph"]),
            (.flat, ["flat vector", "minimalist", "paper cutout", "collage", "shadow-puppet", "sacred geometry"]),
            (.paint, ["watercolor", "gouache", "oil painting", "impressionist", "pastel", "painted", "painterly", "crayon",
                      "dreamscape", "dreamcore", "storybook", "fairy-tale", "fantasy", "saga", "myth", "afrofuturism",
                      "solarpunk", "steampunk", "surreal", "vintage editorial", "chiaroscuro", "portrait"]),
            (.anime, ["anime", "cartoon", "chibi", "donghua", "webtoon", "manhwa", "moe", "shōnen", "shōjo", "seinen", "josei",
                      "magical girl", "mecha", "isekai", "slice-of-life", "space opera", "bishōnen", "sakuga", "animated",
                      "animation", "showa", "lo-fi", "wuxia", "hanfu", "warrior", "aura"]),
        ]
        for (family, words) in rules where words.contains(where: { n.contains($0) }) { return family }
        switch collection {
        case "Anime", "Donghua", "World": return .anime
        case "Visions": return .paint
        case "3D": return nil
        default: return .faithful
        }
    }

    /// One Studio look: its words and its sample picture (a tile in a sample sheet).
    public struct Look: Sendable {
        public let name: String
        public let description: String
        public let collection: String
        public let samplePath: String?
        public let cols: Int
        public let rows: Int
        public let tile: Int

        public init(name: String, description: String, collection: String, samplePath: String?, cols: Int, rows: Int, tile: Int) {
            self.name = name; self.description = description; self.collection = collection
            self.samplePath = samplePath; self.cols = cols; self.rows = rows; self.tile = tile
        }
    }

    /// How a look's description changes its family's recipe: line weight, darkness and colour, shading levels,
    /// colour count, saturation, contrast, hand-drawn wobble and glow. Keys ending in * multiply, + add, others set.
    static let lookRules: [([String], [String: Double])] = [
        (["thick ink", "heavy ink", "thick outline", "bold outline", "carved contours"], ["ink_w*": 1.6, "ink_dark": 1.0]),
        (["crisp clean line", "clean line"], ["ink_dark": 0.95, "ink_soft*": 0.6]),
        (["delicate linework", "fine line", "fine-line", "delicate"], ["ink_w*": 0.6, "ink_dark": 0.75]),
        (["rough", "pencil", "sketch", "brushy"], ["ink_w*": 0.85, "boil": 0.5]),
        (["colored-pencil", "colored line", "coloured line"], ["ink_dark": 0.45]),
        (["flat cel", "flat planes", "flat bold", "flat color", "flat colour"], ["cel_levels": 3, "smooth_passes+": 1]),
        (["simple shading", "limited"], ["cel_levels": 2]),
        (["soft gradient", "airbrush", "soft", "glossy", "bloom", "detailed lighting", "luminous"], ["cel_levels+": 3, "ink_dark*": 0.75]),
        (["pastel", "hazy"], ["saturation*": 0.7, "brightness": 0.08, "ink_dark*": 0.6]),
        (["neon", "candy", "bright", "vivid", "brighter saturation", "bold color"], ["saturation*": 1.3]),
        (["muted", "desaturated", "gentle palette", "natural color", "faded"], ["saturation*": 0.72]),
        (["heavy shadows", "dramatic", "high contrast", "chiaroscuro", "gritty"], ["contrast*": 1.2]),
        (["film grain", "vhs", "film tones", "hand-drawn", "hand-painted"], ["boil": 0.25]),
        (["glow", "bloom", "luminous", "lens flare", "sparkle", "magic"], ["glow": 0.35]),
        (["rounded", "cute", "big eyes", "chibi", "oversized heads"], ["round": 2, "chaikin": 2, "saturation*": 1.1]),
        (["detailed", "intricate", "hyper-detailed", "ornate", "dense"], ["colors+": 6, "min_area*": 0.6]),
        (["minimal", "simple", "negative space"], ["colors+": -4, "min_area*": 2.0]),
    ]

    /// A family's recipe, tuned for one look: its description sets the line style and shading,
    /// and its sample picture sets the colours (the traced palette is repainted to match it).
    public static func recipe(_ family: Family, look: Look?, detail: Double = 0.6) -> [String: Any] {
        var r = recipe(family)
        defer { applyDetail(&r, detail) }
        guard let look else { return r }
        let words = look.description.lowercased()
        // keep "colors" etc. as numbers we can do sums on
        func number(_ key: String, _ fallback: Double) -> Double {
            if let d = r[key] as? Double { return d }
            if let i = r[key] as? Int { return Double(i) }
            return fallback
        }
        let defaults: [String: Double] = ["ink_w": 1.2, "ink_dark": 0.65, "ink_soft": 0.12, "saturation": 1.0, "contrast": 1.0,
                                          "colors": 12, "min_area": 12, "cel_levels": 0, "smooth_passes": 2]
        for (cues, changes) in lookRules where cues.contains(where: { words.contains($0) }) {
            for (key, value) in changes {
                if key.hasSuffix("*") {
                    let k = String(key.dropLast()); r[k] = number(k, defaults[k] ?? 1) * value
                } else if key.hasSuffix("+") {
                    let k = String(key.dropLast()); r[k] = number(k, defaults[k] ?? 0) + value
                } else {
                    r[key] = value
                }
            }
        }
        r["colors"] = max(4, Int(number("colors", 12).rounded()))
        r["cel_levels"] = max(0, Int(number("cel_levels", 0).rounded()))
        r["smooth_passes"] = max(0, Int(number("smooth_passes", 2).rounded()))
        r["round"] = Int(number("round", 1).rounded())
        r["chaikin"] = Int(number("chaikin", 1).rounded())
        if let path = look.samplePath, family != .ink, family != .blueprint, family != .chalk {
            r["look_sample"] = ["path": path, "cols": look.cols, "rows": look.rows, "tile": look.tile, "name": look.name] as [String: Any]
        }
        return r
    }

    /// The Detail slider (0…1; 0.6 leaves the look as it is). Lower: fewer colours, bigger and smoother shapes,
    /// fewer lines. Higher: more colours, smaller shapes kept, more lines.
    static func applyDetail(_ r: inout [String: Any], _ detail: Double) {
        let f = min(1, max(0, detail)) - 0.6
        guard abs(f) > 0.001 else { return }
        func num(_ k: String, _ fallback: Double) -> Double {
            (r[k] as? Double) ?? (r[k] as? Int).map(Double.init) ?? fallback
        }
        r["colors"] = max(4, Int((num("colors", 12) * (1 + 0.9 * f)).rounded()))
        r["min_area"] = num("min_area", 12) * pow(2, -4 * f)
        r["simplify"] = max(0.3, num("simplify", 0.8) * (1 - 0.8 * f))
        r["smooth_passes"] = max(1, Int((num("smooth_passes", 2) - 4 * f).rounded()))
        r["majority_passes"] = max(1, Int((num("majority_passes", 1) - 3 * f).rounded()))
        if detail < 0.35 { r["majority_radius"] = 2 }
        r["ink_threshold"] = num("ink_threshold", 0.18) * max(0.4, 1 - 1.2 * f)
        r["ink_min_area"] = num("ink_min_area", 30) * pow(2, -4 * f)
    }

    /// The trace settings for a family (keys are read by the Blender script).
    public static func recipe(_ family: Family) -> [String: Any] {
        switch family {
        case .faithful:
            return ["work": 900, "colors": 28, "cel_levels": 0, "smooth_passes": 1, "smooth_radius": 1,
                    "majority_passes": 1, "majority_radius": 1, "min_area": 4, "simplify": 0.5, "round": 1, "chaikin": 1, "ink": 0]
        case .anime:
            return ["work": 760, "colors": 16, "cel_levels": 5, "saturation": 1.2, "contrast": 1.06, "smooth_passes": 2,
                    "smooth_radius": 2, "majority_passes": 1, "majority_radius": 1, "min_area": 6, "simplify": 0.6, "round": 1,
                    "chaikin": 1, "ink": 1, "ink_threshold": 0.12, "ink_soft": 0.08, "ink_min_area": 16, "ink_w": 1.5, "ink_dark": 0.9]
        case .ink:
            return ["work": 760, "grey": true, "colors": 6, "cel_levels": 4, "saturation": 0.0, "contrast": 1.25,
                    "smooth_passes": 2, "smooth_radius": 2, "majority_passes": 2, "majority_radius": 1, "min_area": 10,
                    "simplify": 0.6, "round": 1, "chaikin": 1, "ink": 1, "ink_threshold": 0.08, "ink_soft": 0.06,
                    "ink_min_area": 12, "ink_w": 1.6, "ink_dark": 1.0, "bg": [0.96, 0.96, 0.94]]
        case .flat:
            return ["work": 640, "colors": 10, "saturation": 1.1, "smooth_passes": 4, "smooth_radius": 3, "majority_passes": 3,
                    "majority_radius": 2, "min_area": 40, "simplify": 1.2, "round": 2, "chaikin": 2, "ink": 0]
        case .poster:
            return ["work": 640, "colors": 8, "saturation": 1.3, "contrast": 1.15, "smooth_passes": 4, "smooth_radius": 3,
                    "majority_passes": 3, "majority_radius": 2, "min_area": 40, "simplify": 1.2, "round": 2, "chaikin": 2,
                    "ink": 1, "ink_threshold": 0.08, "ink_soft": 0.06, "ink_min_area": 30, "ink_w": 2.2, "ink_dark": 1.0]
        case .paint:
            return ["work": 760, "colors": 22, "saturation": 1.08, "smooth_passes": 3, "smooth_radius": 3, "majority_passes": 2,
                    "majority_radius": 2, "min_area": 10, "simplify": 0.9, "round": 2, "chaikin": 2, "ink": 1,
                    "ink_threshold": 0.3, "ink_soft": 0.3, "ink_w": 0.8, "ink_dark": 0.35]
        case .pixel:
            return ["work": 160, "colors": 16, "smooth_passes": 1, "smooth_radius": 1, "majority_passes": 1, "majority_radius": 1,
                    "min_area": 2, "simplify": 0.0, "round": 0, "chaikin": 0, "ink": 0, "sketch": false, "pixel": 8]
        case .neon:
            return ["work": 700, "colors": 10, "saturation": 1.5, "smooth_passes": 2, "smooth_radius": 2, "majority_passes": 2,
                    "majority_radius": 1, "min_area": 12, "simplify": 0.7, "round": 1, "chaikin": 1, "ink": 1,
                    "ink_threshold": 0.05, "ink_soft": 0.05, "ink_w": 1.3, "ink_dark": -0.8, "fill_dim": 0.18, "glow": 0.9,
                    "bg": [0.01, 0.0, 0.03]]
        case .blueprint:
            var r = recipe(.ink)
            r["tint"] = [0.35, 0.55, 1.0]; r["bg"] = [0.15, 0.3, 0.4]; r["fill_dim"] = 0.45
            r["ink_rgb"] = [0.95, 0.97, 1.0]; r["ink_w"] = 1.2
            return r
        case .chalk:
            var r = recipe(.ink)
            r["tint"] = [0.75, 0.95, 0.8]; r["bg"] = [0.08, 0.15, 0.12]; r["fill_dim"] = 0.35
            r["ink_rgb"] = [0.95, 0.95, 0.92]; r["ink_w"] = 1.4
            return r
        }
    }

    public struct Result: Sendable {
        public let still: URL
        public let movie: URL
        public let project: URL
        public let summary: String
    }

    /// Traces `image` in Blender (background) and writes still, movie and project into `folder`.
    public static func run(image: URL, family: Family, look: Look? = nil, detail: Double = 0.6, folder: URL,
                           size: Int = 1920, seconds: Double = 6) async throws -> Result {
        let blender = BlenderStageAdapter.blenderPath
        guard FileManager.default.isExecutableFile(atPath: blender) else {
            throw PrismError.local("Blender wasn't found in /Applications. Install Blender to use True Trace.")
        }
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw PrismError.local("Choose an image first. Not found: \(image.path)")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let still = folder.appendingPathComponent("True Trace.png")
        let movieBase = folder.appendingPathComponent("True Trace")
        let project = folder.appendingPathComponent("True Trace.blend")
        let scriptURL = folder.appendingPathComponent("true_trace.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let args: [String: Any] = ["image": image.path, "recipe": recipe(family, look: look, detail: detail), "still": still.path,
                                   "movie": movieBase.path, "project": project.path, "size": size, "seconds": seconds]
        let (status, text) = try await runBlender(blender: blender, script: scriptURL, args: args, folder: folder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard status == 0, FileManager.default.fileExists(atPath: still.path),
              let movieName = files.first(where: { $0.lowercased().hasSuffix(".mp4") }) else {
            let errors = text.components(separatedBy: .newlines).filter { $0.contains("Error") || $0.contains("rror:") }
            throw PrismError.local("Blender didn't finish the True Trace. \((errors.isEmpty ? text : errors.joined(separator: " ")).suffix(400))")
        }
        let lines = text.components(separatedBy: .newlines)
        let detail = lines.first { $0.hasPrefix("True Trace: ") }?.replacingOccurrences(of: "True Trace: ", with: "") ?? ""
        // What the colour check found, so a wrong-looking result can be traced back.
        let check = lines.first { $0.hasPrefix("Calibration: ") }?.replacingOccurrences(of: "Calibration: ", with: "") ?? "not run"
        let surfaces = lines.contains { $0.hasPrefix("Colour shapes: flat surfaces") }
        return Result(still: still, movie: folder.appendingPathComponent(movieName), project: project,
                      summary: "\(family.title) in Grease Pencil" + (detail.isEmpty ? "." : ": \(detail).")
                        + (surfaces ? " Colour drawn as flat surfaces under the ink." : "") + " Colour check: \(check).")
    }

    /// Runs a Python script in Blender with no window; Blender's messages go to blender.log in `folder`.
    /// Returns the exit status and the log.
    static func runBlender(blender: String, script: URL, args: [String: Any], folder: URL) async throws -> (Int32, String) {
        let json = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "{}"
        let log = folder.appendingPathComponent("blender.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: blender)
        process.arguments = ["-b", "--factory-startup", "--python-exit-code", "1", "--python", script.path, "--", json]
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
        return (process.terminationStatus, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }
}
