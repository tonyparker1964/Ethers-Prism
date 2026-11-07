import Foundation

public struct CompiledRequest: Sendable, Equatable {
    public var system: String
    public var user: String
    public var maxTokens: Int

    public init(system: String, user: String, maxTokens: Int) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
    }
}

/// A field of work plugged into the instrument. The core only knows goals, dials and history;
/// everything specific to writing, images, video, music, code or research lives here.
public protocol DomainAdapter: Sendable {
    var id: String { get }
    var name: String { get }
    /// SF Symbol name for the sidebar and picker.
    var symbol: String { get }
    var outputKind: OutputKind { get }
    /// Kinds of dimensions that tend to matter in this field (guides dial suggestions).
    var axisHint: String { get }
    func compile(goal: String, axes: [Dial], quality: Quality) -> CompiledRequest
}

/// Most domains differ only in role, format and budget, so one configurable adapter covers them.
/// Write your own type conforming to DomainAdapter when a field needs more.
public struct BasicAdapter: DomainAdapter {
    public let id: String
    public let name: String
    public let symbol: String
    public let outputKind: OutputKind
    public let axisHint: String
    public let role: String
    public let format: String
    public let previewTokens: Int
    public let renderTokens: Int

    public init(id: String, name: String, symbol: String, outputKind: OutputKind, axisHint: String,
                role: String, format: String, previewTokens: Int, renderTokens: Int) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.outputKind = outputKind
        self.axisHint = axisHint
        self.role = role
        self.format = format
        self.previewTokens = previewTokens
        self.renderTokens = renderTokens
    }

    public func compile(goal: String, axes: [Dial], quality: Quality) -> CompiledRequest {
        Compiler.compile(goal: goal, axes: axes, quality: quality, role: role, format: format,
                         maxTokens: quality == .preview ? previewTokens : renderTokens)
    }
}

public enum Domains {
    /// Add a new field by appending an adapter here.
    public static let all: [any DomainAdapter] = [text, image, video, music, code, research]

    public static func adapter(for id: String) -> any DomainAdapter {
        all.first { $0.id == id } ?? text
    }

    public static let text = BasicAdapter(
        id: "text", name: "Writing", symbol: "text.alignleft", outputKind: .text,
        axisHint: "tone, structure, depth, audience, length, voice, formality",
        role: "You are a skilled writer.",
        format: "Plain prose with light Markdown (bold, italic, lists). No title unless the dials call for structure.",
        previewTokens: 600, renderTokens: 4000)

    public static let image = BasicAdapter(
        id: "image", name: "Image", symbol: "photo", outputKind: .svg,
        axisHint: "detail, palette, abstraction, mood, composition, line style",
        role: "You are an illustrator who draws in SVG.",
        format: "A single complete, valid SVG document with viewBox=\"0 0 800 600\" and nothing else. No external images or fonts. In a preview use fewer elements.",
        previewTokens: 2500, renderTokens: 8000)

    public static let video = BasicAdapter(
        id: "video", name: "Video", symbol: "film", outputKind: .storyboard,
        axisHint: "pacing, visual detail, historical reference, technical accuracy, humor, narration style",
        role: "You are a director and educational video producer.",
        format: """
        A storyboard. For every scene use exactly this block:
        ## Scene N — Title (start–end)
        Visual: what is on screen
        Narration: what is said
        On-screen text: captions or labels
        """,
        previewTokens: 800, renderTokens: 4000)

    public static let music = BasicAdapter(
        id: "music", name: "Music", symbol: "music.note", outputKind: .text,
        axisHint: "energy, complexity, era, mood, instrumentation, genre strictness, groove",
        role: "You are a composer and producer.",
        format: "A music sketch: tempo, key and instrumentation first, then each section with bar count, chord progression, and a short description of melody and rhythm.",
        previewTokens: 600, renderTokens: 3000)

    public static let code = BasicAdapter(
        id: "code", name: "Code", symbol: "chevron.left.forwardslash.chevron.right", outputKind: .code,
        axisHint: "simplicity vs performance, safety, flexibility, dependencies, comment density",
        role: "You are a senior software engineer.",
        format: "A single code file with brief comments. No prose before or after.",
        previewTokens: 1200, renderTokens: 6000)

    public static let research = BasicAdapter(
        id: "research", name: "Research", symbol: "magnifyingglass", outputKind: .text,
        axisHint: "confidence threshold, recency, breadth, speculation, skepticism, technical depth",
        role: "You are a careful research analyst.",
        format: "A structured brief: key claim, evidence, confidence, assumptions, and what would change the conclusion. Mark uncertain statements clearly. Never invent citations.",
        previewTokens: 700, renderTokens: 4000)
}
