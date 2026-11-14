import Foundation

/// Sculpt 3D: the 3D looks. Blender turns the picture into a rounded 3D model (the subject is cut out and
/// inflated like clay; a full-frame picture becomes a carved relief), paints the picture onto it, gives it the
/// look's material and studio lighting, and renders a still and a turntable. No image model is involved.
public enum Sculpt3D {

    public enum Finish: String, CaseIterable, Sendable {
        case clay, whiteClay, felt, knit, vinyl, balloon, porcelain, marble, wood, glass, metal, cgi, lowPoly, origami

        public var title: String {
            switch self {
            case .clay: return "Modelling clay"
            case .whiteClay: return "White clay"
            case .felt: return "Needle felt"
            case .knit: return "Knitted yarn"
            case .vinyl: return "Glossy vinyl"
            case .balloon: return "Balloon"
            case .porcelain: return "Glazed porcelain"
            case .marble: return "Carved marble"
            case .wood: return "Carved wood"
            case .glass: return "Glass"
            case .metal: return "Sculpted metal"
            case .cgi: return "CGI render"
            case .lowPoly: return "Low-poly facets"
            case .origami: return "Folded paper"
            }
        }
    }

    /// Which finish makes a Studio 3D look, or nil when it isn't a 3D look Blender can build.
    public static func finish(look name: String) -> Finish? {
        let n = name.lowercased()
        let rules: [(Finish, [String])] = [
            (.whiteClay, ["clay render"]),
            (.clay, ["claymation", "stop-motion"]),
            (.felt, ["needle felt"]),
            (.knit, ["knitted"]),
            (.balloon, ["balloon"]),
            (.vinyl, ["vinyl toy", "toy brick"]),
            (.porcelain, ["porcelain"]),
            (.marble, ["marble", "surreal minimal sculpture"]),
            (.wood, ["wood carving"]),
            (.glass, ["glass and crystal"]),
            (.metal, ["sculpted metal"]),
            (.lowPoly, ["low-poly"]),
            (.origami, ["origami"]),
            (.cgi, ["photorealistic cgi", "cinematic 3d animation", "donghua 3d", "3d cultivation", "3d sci-fi", "isometric diorama"]),
        ]
        for (finish, words) in rules where words.contains(where: { n.contains($0) }) { return finish }
        return nil
    }

    /// Settings read by the Blender script.
    public static func recipe(_ finish: Finish) -> [String: Any] {
        var r: [String: Any] = ["name": finish.title, "grid": 300, "depth": 0.8, "detail": 0.25, "roughness": 0.5]
        switch finish {
        case .clay:
            r.merge(["posterize": 6, "tex_blur": 2, "saturation": 1.15, "roughness": 0.85, "subsurface": 0.12,
                     "bump": "fingerprints", "bump_strength": 0.12, "bg": [0.33, 0.3, 0.27], "floor": [0.55, 0.5, 0.45]]) { $1 }
        case .whiteClay:
            r.merge(["mono": [0.85, 0.84, 0.82], "picture_mix": 0.0, "roughness": 0.9, "bg": [0.7, 0.7, 0.7],
                     "floor": [0.8, 0.8, 0.8]]) { $1 }
        case .felt:
            r.merge(["posterize": 7, "tex_blur": 3, "roughness": 1.0, "sheen": 0.6, "bump": "fuzz", "bump_strength": 0.3,
                     "bg": [0.4, 0.36, 0.32]]) { $1 }
        case .knit:
            r.merge(["posterize": 6, "tex_blur": 3, "roughness": 1.0, "sheen": 0.4, "bump": "knit", "bump_strength": 0.35,
                     "bg": [0.4, 0.36, 0.32]]) { $1 }
        case .vinyl:
            r.merge(["posterize": 5, "tex_blur": 3, "saturation": 1.25, "roughness": 0.22, "coat": 0.6,
                     "bg": [0.85, 0.85, 0.88], "floor": [0.9, 0.9, 0.92]]) { $1 }
        case .balloon:
            r.merge(["depth": 1.0, "posterize": 4, "tex_blur": 4, "saturation": 1.3, "roughness": 0.12, "coat": 1.0,
                     "bg": [0.88, 0.86, 0.9], "floor": [0.92, 0.9, 0.94]]) { $1 }
        case .porcelain:
            r.merge(["mono": [0.95, 0.95, 0.97], "picture_mix": 0.35, "roughness": 0.08, "coat": 1.0, "subsurface": 0.1,
                     "bg": [0.12, 0.13, 0.16], "floor": [0.2, 0.2, 0.22]]) { $1 }
        case .marble:
            r.merge(["mono": [0.92, 0.9, 0.88], "picture_mix": 0.0, "pattern": "marble", "roughness": 0.3,
                     "subsurface": 0.15, "bg": [0.06, 0.06, 0.07], "floor": [0.15, 0.15, 0.16]]) { $1 }
        case .wood:
            r.merge(["mono": [0.55, 0.36, 0.2], "picture_mix": 0.1, "pattern": "wood", "vein": [0.35, 0.2, 0.1],
                     "roughness": 0.6, "bg": [0.2, 0.16, 0.13], "floor": [0.3, 0.24, 0.18]]) { $1 }
        case .glass:
            r.merge(["mono": [0.85, 0.95, 1.0], "picture_mix": 0.3, "transmission": 1.0, "roughness": 0.03,
                     "bg": [0.03, 0.04, 0.06], "floor": [0.06, 0.07, 0.09], "rim": 2.0]) { $1 }
        case .metal:
            r.merge(["mono": [0.85, 0.7, 0.4], "picture_mix": 0.2, "metallic": 1.0, "roughness": 0.3,
                     "bump": "hammered", "bump_strength": 0.08, "bg": [0.05, 0.05, 0.06], "floor": [0.12, 0.12, 0.13]]) { $1 }
        case .cgi:
            r.merge(["roughness": 0.5, "subsurface": 0.05, "dof": 2.8, "bg": [0.1, 0.1, 0.12], "floor": [0.2, 0.2, 0.22]]) { $1 }
        case .lowPoly:
            r.merge(["posterize": 6, "tex_blur": 4, "decimate": 0.03, "flat_shading": true, "roughness": 0.7,
                     "bg": [0.75, 0.78, 0.82]]) { $1 }
        case .origami:
            r.merge(["posterize": 4, "tex_blur": 5, "decimate": 0.015, "flat_shading": true, "roughness": 0.9,
                     "bg": [0.9, 0.88, 0.85], "floor": [0.92, 0.9, 0.87]]) { $1 }
        }
        return r
    }

    public struct Result: Sendable {
        public let still: URL
        public let movie: URL
        public let project: URL
        public let model: URL?
        public let summary: String
    }

    /// Builds and renders the 3D look in Blender (background), writing everything into `folder`.
    public static func run(image: URL, finish: Finish, folder: URL, size: Int = 1920, seconds: Double = 5) async throws -> Result {
        let blender = BlenderStageAdapter.blenderPath
        guard FileManager.default.isExecutableFile(atPath: blender) else {
            throw PrismError.local("Blender wasn't found in /Applications. Install Blender to build 3D looks.")
        }
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw PrismError.local("Choose an image first. Not found: \(image.path)")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let still = folder.appendingPathComponent("\(finish.title).png")
        let movieBase = folder.appendingPathComponent("\(finish.title) turntable")
        let project = folder.appendingPathComponent("\(finish.title).blend")
        let model = folder.appendingPathComponent("\(finish.title).glb")
        let scriptURL = folder.appendingPathComponent("sculpt_3d.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let args: [String: Any] = ["image": image.path, "recipe": recipe(finish), "still": still.path, "movie": movieBase.path,
                                   "project": project.path, "model": model.path, "size": size, "seconds": seconds]
        let (status, text) = try await TrueTrace.runBlender(blender: blender, script: scriptURL, args: args, folder: folder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard status == 0, FileManager.default.fileExists(atPath: still.path),
              let movieName = files.first(where: { $0.lowercased().hasSuffix(".mp4") }) else {
            let errors = text.components(separatedBy: .newlines).filter { $0.contains("Error") || $0.contains("rror:") }
            throw PrismError.local("Blender didn't finish the 3D look. \((errors.isEmpty ? text : errors.joined(separator: " ")).suffix(400))")
        }
        let detail = text.components(separatedBy: .newlines).first { $0.hasPrefix("Sculpt 3D: ") }?
            .replacingOccurrences(of: "Sculpt 3D: ", with: "") ?? ""
        return Result(still: still, movie: folder.appendingPathComponent(movieName), project: project,
                      model: FileManager.default.fileExists(atPath: model.path) ? model : nil,
                      summary: "\(finish.title) in Blender 3D" + (detail.isEmpty ? "." : ": \(detail)."))
    }
}
