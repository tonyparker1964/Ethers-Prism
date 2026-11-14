import Foundation
import CoreGraphics

/// One slider in the Studio inspector: its key, label, range and neutral value.
public struct StudioControl: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let range: ClosedRange<Double>
    public let neutral: Double
    public let unit: String
    /// Snap size, if the slider moves in steps.
    public let step: Double?

    public init(_ id: String, _ label: String, _ range: ClosedRange<Double>, neutral: Double = 0, unit: String = "",
                step: Double? = nil) {
        self.id = id; self.label = label; self.range = range; self.neutral = neutral; self.unit = unit; self.step = step
    }

    /// How the value is shown next to the slider.
    public func format(_ v: Double) -> String {
        switch unit {
        case "EV": return String(format: "%+.2f EV", v)
        case "%": return "\(Int(v.rounded()))%"
        case "×": return v == v.rounded() ? "\(Int(v))×" : String(format: "%.1f×", v)
        default: return v == 0 ? "0" : String(format: "%+d", Int(v.rounded()))
        }
    }
}

/// Everything a Studio edit changes. Values are stored by control id so presets and saved projects stay
/// readable and new controls can be added later without breaking old files.
public struct StudioEdit: Codable, Equatable, Hashable, Sendable {
    public var values: [String: Double]
    /// Quarter turns clockwise (0...3).
    public var quarterTurns: Int
    /// Crop in unit coordinates of the rotated image (origin top-left); nil means the whole image.
    public var crop: UnitRect?
    /// Enhance tab: 1, 2 or 4.
    public var upscale: Int

    public init(values: [String: Double] = [:], quarterTurns: Int = 0, crop: UnitRect? = nil, upscale: Int = 2) {
        self.values = values; self.quarterTurns = quarterTurns; self.crop = crop; self.upscale = upscale
    }

    public subscript(_ id: String) -> Double {
        get { values[id] ?? StudioControls.byID[id]?.neutral ?? 0 }
        set {
            let neutral = StudioControls.byID[id]?.neutral ?? 0
            if abs(newValue - neutral) < 0.0001 { values[id] = nil } else { values[id] = newValue }
        }
    }

    public func isChanged(_ id: String) -> Bool { values[id] != nil }

    /// True when nothing (colour, realism, enhance, crop or rotation) differs from the original.
    public var isIdentity: Bool { values.isEmpty && quarterTurns == 0 && crop == nil }

    /// The slider values only (for presets: crop and rotation belong to one picture).
    public var look: [String: Double] { values }
}

/// A rectangle in unit coordinates (0...1), origin top-left.
public struct UnitRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    /// Clamped to the unit square, at least 2% on each side.
    public var clamped: UnitRect {
        let x0 = min(max(x, 0), 0.98), y0 = min(max(y, 0), 0.98)
        return UnitRect(x: x0, y: y0, width: min(max(width, 0.02), 1 - x0), height: min(max(height, 0.02), 1 - y0))
    }
    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)
}

/// How an upscale treats detail (after DaVinci Resolve's Super Scale modes).
public enum UpscaleMode: Int, CaseIterable, Identifiable, Sendable {
    case standard = 0, sharper = 1, smoother = 2
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .standard: return "Standard"
        case .sharper: return "Sharper"
        case .smoother: return "Smoother"
        }
    }
    /// Multipliers for detail recovery, edge refinement and noise reduction.
    public var weights: (detail: Double, edges: Double, noise: Double) {
        switch self {
        case .standard: return (1, 1, 1)
        case .sharper: return (1.35, 1.3, 0.8)
        case .smoother: return (0.55, 0.45, 1.5)
        }
    }
}

extension StudioEdit {
    /// Kept in `values` under "upscaleMode" (0 = Standard).
    public var upscaleMode: UpscaleMode {
        get { UpscaleMode(rawValue: Int(values["upscaleMode"] ?? 0)) ?? .standard }
        set { values["upscaleMode"] = newValue == .standard ? nil : Double(newValue.rawValue) }
    }
    /// The 4K Upscale slider (1×–4×).
    public var upscaleFactor: Double { self["upscaleFactor"] }
}

public enum StudioTab: String, CaseIterable, Identifiable, Sendable {
    case adjust, realism, enhance
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .adjust: return "Adjust"
        case .realism: return "Realism"
        case .enhance: return "Enhance"
        }
    }
}

public enum StudioControls {
    public static let adjust: [StudioControl] = [
        StudioControl("exposure", "Exposure", -2...2, unit: "EV"),
        StudioControl("brightness", "Brightness", -100...100),
        StudioControl("contrast", "Contrast", -100...100),
        StudioControl("highlights", "Highlights", -100...100),
        StudioControl("shadows", "Shadows", -100...100),
        StudioControl("saturation", "Saturation", -100...100),
        StudioControl("vibrance", "Vibrance", -100...100),
        StudioControl("temperature", "White Balance", -100...100),
        StudioControl("sharpness", "Sharpness", 0...100, unit: "%"),
    ]
    public static let realism: [StudioControl] = [
        StudioControl("photorealism", "Photorealism", 0...100, unit: "%"),
        StudioControl("microtexture", "Microtexture", 0...100, unit: "%"),
        StudioControl("skinDetail", "Skin Detail Preservation", 0...100, unit: "%"),
        StudioControl("surfaceDetail", "Surface Detail", 0...100, unit: "%"),
        StudioControl("depth", "Depth Enhancement", 0...100, unit: "%"),
        StudioControl("localContrast", "Local Contrast", 0...100, unit: "%"),
        StudioControl("highlightRecovery", "Highlight Recovery", 0...100, unit: "%"),
        StudioControl("shadowRecovery", "Shadow Recovery", 0...100, unit: "%"),
        StudioControl("edgeRefinement", "Edge Refinement", 0...100, unit: "%"),
        StudioControl("noiseReduction", "Noise Reduction", 0...100, unit: "%"),
    ]
    /// Applied when the picture is made bigger (Enhance to 4K, Upscale, export at 2×/4×/4K).
    public static let enhance: [StudioControl] = [
        StudioControl("upscaleFactor", "4K Upscale", 1...4, neutral: 2, unit: "×", step: 0.5),
        StudioControl("enhanceDetail", "Detail Recovery", 0...100, neutral: 60, unit: "%"),
        StudioControl("enhanceNoise", "Noise Reduction", 0...100, neutral: 30, unit: "%"),
        StudioControl("enhanceEdges", "Edge Refinement", 0...100, neutral: 40, unit: "%"),
        StudioControl("enhanceTexture", "Texture Preservation", 0...100, neutral: 70, unit: "%"),
    ]

    public static func controls(for tab: StudioTab) -> [StudioControl] {
        switch tab {
        case .adjust: return adjust
        case .realism: return realism
        case .enhance: return enhance
        }
    }

    public static let all: [StudioControl] = adjust + realism + enhance
    public static let byID: [String: StudioControl] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

/// A saved set of slider values.
public struct StudioPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var values: [String: Double]
    public var builtIn: Bool

    public init(id: UUID = UUID(), name: String, values: [String: Double], builtIn: Bool = false) {
        self.id = id; self.name = name; self.values = values; self.builtIn = builtIn
    }

    public static let builtIns: [StudioPreset] = [
        StudioPreset(name: "Natural Realism", values: ["photorealism": 45, "microtexture": 30, "skinDetail": 70,
                                                      "localContrast": 25, "noiseReduction": 20, "vibrance": 10], builtIn: true),
        StudioPreset(name: "Cinematic", values: ["contrast": 18, "highlights": -25, "shadows": 15, "saturation": -10,
                                                "temperature": -12, "depth": 45, "localContrast": 30], builtIn: true),
        StudioPreset(name: "Crisp Detail", values: ["sharpness": 35, "microtexture": 55, "surfaceDetail": 45,
                                                   "edgeRefinement": 40, "enhanceDetail": 80], builtIn: true),
        StudioPreset(name: "Soft Portrait", values: ["noiseReduction": 45, "skinDetail": 85, "highlightRecovery": 35,
                                                    "vibrance": 12, "temperature": 8], builtIn: true),
    ]
}

/// One saved state in a project's history.
public struct StudioVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var label: String
    public var edit: StudioEdit

    public init(id: UUID = UUID(), date: Date = Date(), label: String, edit: StudioEdit) {
        self.id = id; self.date = date; self.label = label; self.edit = edit
    }
}

/// The edit of one library picture, autosaved. The picture itself is never changed.
public struct StudioProject: Codable, Identifiable, Hashable, Sendable {
    /// The library picture's content hash.
    public var id: String
    public var imagePath: String
    public var edit: StudioEdit
    public var history: [StudioVersion]
    public var updatedAt: Date

    public init(id: String, imagePath: String, edit: StudioEdit = StudioEdit(), history: [StudioVersion] = []) {
        self.id = id; self.imagePath = imagePath; self.edit = edit; self.history = history; self.updatedAt = Date()
    }

    /// Adds a history entry (the newest 60 are kept).
    public mutating func record(_ label: String) {
        if history.last?.edit == edit { return }
        history.append(StudioVersion(label: label, edit: edit))
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }
}

/// Saves Studio projects and presets as JSON in `<root>/Studio`.
public final class StudioStore {
    public let folder: URL
    private var projectsFolder: URL { folder.appendingPathComponent("Projects", isDirectory: true) }
    private var presetsURL: URL { folder.appendingPathComponent("presets.json") }

    public init(root: URL) {
        folder = root.appendingPathComponent("Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectsFolder, withIntermediateDirectories: true)
    }

    public func load(_ id: String) -> StudioProject? {
        guard let data = try? Data(contentsOf: projectsFolder.appendingPathComponent("\(id).json")) else { return nil }
        return try? Self.decoder.decode(StudioProject.self, from: data)
    }

    public func save(_ project: StudioProject) throws {
        var p = project
        p.updatedAt = Date()
        try Self.encoder.encode(p).write(to: projectsFolder.appendingPathComponent("\(p.id).json"), options: .atomic)
    }

    public func loadPresets() -> [StudioPreset] {
        guard let data = try? Data(contentsOf: presetsURL), let saved = try? Self.decoder.decode([StudioPreset].self, from: data)
        else { return [] }
        return saved
    }

    public func savePresets(_ presets: [StudioPreset]) throws {
        try Self.encoder.encode(presets.filter { !$0.builtIn }).write(to: presetsURL, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
