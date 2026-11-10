import Foundation

public enum AdapterStatus: Hashable, Sendable {
    case ready
    case unfinished(String)

    public var isReady: Bool { if case .ready = self { return true } else { return false } }
    public var note: String? { if case .unfinished(let n) = self { return n } else { return nil } }
}

public struct OutputCapabilities: Hashable, Sendable {
    public var kind: OutputKind
    /// The person can edit the result by hand; edits become history states.
    public var editable: Bool
    public var exportFormats: [String]
    public var needsImageProvider: Bool
    public var needsVideoProvider: Bool

    public init(kind: OutputKind, editable: Bool, exportFormats: [String], needsImageProvider: Bool = false,
                needsVideoProvider: Bool = false) {
        self.kind = kind
        self.editable = editable
        self.exportFormats = exportFormats
        self.needsImageProvider = needsImageProvider
        self.needsVideoProvider = needsVideoProvider
    }
}

/// What an adapter returns. Media bytes are handed to storage by the app; the adapter never touches files.
public struct Generated: Sendable {
    public var output: Output
    public var asset: Data?
    public var assetExtension: String?

    public init(output: Output, asset: Data? = nil, assetExtension: String? = nil) {
        self.output = output
        self.asset = asset
        self.assetExtension = assetExtension
    }
}

/// A field of work plugged into the instrument. Adding a field means writing one adapter and
/// listing it in `Domains.all`; sessions, history and storage never change.
public protocol DomainAdapter: Sendable {
    var id: String { get }
    var name: String { get }
    var symbol: String { get }
    var status: AdapterStatus { get }
    var capabilities: OutputCapabilities { get }
    /// Kinds of dimensions that tend to matter here (guides dial suggestions).
    var dialHint: String { get }
    func compile(_ input: CompileInput) -> CompiledRequest
    func suggestDials(for goal: String, using providers: ProviderSet) async throws -> [Dial]
    func preview(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated
    func render(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated
}

extension DomainAdapter {
    public func suggestDials(for goal: String, using providers: ProviderSet) async throws -> [Dial] {
        let raw = try await providers.text(for: .dialDesigner)
            .complete(DialSuggester.request(goal: goal, adapterName: name, hint: dialHint))
        return try DialSuggester.parse(raw)
    }

    public func generate(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        request.input.quality == .preview
            ? try await preview(request, using: providers)
            : try await render(request, using: providers)
    }
}

// MARK: - Text-shaped fields

public struct TextAdapter: DomainAdapter {
    public let id: String
    public let name: String
    public let symbol: String
    public let status: AdapterStatus
    public let capabilities: OutputCapabilities
    public let dialHint: String
    public let role: String
    public let format: String
    public let previewTokens: Int
    public let renderTokens: Int
    /// Which agent does this field's work.
    public let agent: AgentRole

    public init(id: String, name: String, symbol: String, status: AdapterStatus, capabilities: OutputCapabilities,
                dialHint: String, role: String, format: String, previewTokens: Int, renderTokens: Int,
                agent: AgentRole = .writer) {
        self.agent = agent
        self.id = id
        self.name = name
        self.symbol = symbol
        self.status = status
        self.capabilities = capabilities
        self.dialHint = dialHint
        self.role = role
        self.format = format
        self.previewTokens = previewTokens
        self.renderTokens = renderTokens
    }

    public func compile(_ input: CompileInput) -> CompiledRequest {
        let text = Compiler.buildText(role: role, format: format, input: input,
                                      previewTokens: previewTokens, renderTokens: renderTokens)
        return CompiledRequest(input: input, text: text, seed: Compiler.seed(for: text.user))
    }

    public func preview(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request, providers)
    }

    public func render(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request, providers)
    }

    private func run(_ request: CompiledRequest, _ providers: ProviderSet) async throws -> Generated {
        let worker = providers.text(for: agent)
        let raw = try await worker.complete(request.text)
        let text = OutputCleaner.clean(raw, kind: capabilities.kind)
        return Generated(output: Output(kind: capabilities.kind, text: text, provider: worker.name,
                                        model: worker.model, agent: agent.title))
    }
}

// MARK: - Images

public struct ImageAdapter: DomainAdapter {
    public static let promptMarker = "[[IMAGE-PROMPT]]"

    public let id = "image"
    public let name = "Image"
    public let symbol = "photo"
    public let status = AdapterStatus.ready
    public let capabilities = OutputCapabilities(kind: .image, editable: false, exportFormats: ["png", "svg"],
                                                 needsImageProvider: true)
    public let dialHint = "realism, visual complexity, color intensity, lighting contrast, composition, symbolic depth, mood"

    public init() {}

    /// Claude turns the goal, dials and constraints into a prompt for the image model.
    public func compile(_ input: CompileInput) -> CompiledRequest {
        let text = Compiler.buildText(
            role: "\(Self.promptMarker) You are an art director who writes prompts for an image-generation model.",
            format: #"JSON only: {"prompt": "one rich, comma-separated visual description", "negative": "comma-separated things to keep out"}. Put every 'Must avoid' requirement into negative. Keep the prompt under 75 words."#,
            input: input, previewTokens: 400, renderTokens: 500)
        var withSchema = text
        withSchema.schema = Schemas.imagePrompt
        return CompiledRequest(input: input, text: withSchema, seed: Compiler.seed(for: text.user))
    }

    public func preview(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request, providers)
    }

    public func render(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request, providers)
    }

    public struct ImagePrompt: Decodable, Hashable, Sendable {
        public var prompt: String
        public var negative: String?
    }

    public static func parsePrompt(_ input: String) -> ImagePrompt {
        let raw = OutputCleaner.stripThinking(input)
        if let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e {
            let slice = String(raw[s...e])
            for candidate in [slice, JSONRepair.repair(slice, keys: ["prompt", "negative"])] {
                if let p = try? JSONDecoder().decode(ImagePrompt.self, from: Data(candidate.utf8)), !p.prompt.trimmed.isEmpty {
                    return p
                }
            }
        }
        return ImagePrompt(prompt: OutputCleaner.stripFences(raw.trimmed), negative: nil)
    }

    private func run(_ request: CompiledRequest, _ providers: ProviderSet) async throws -> Generated {
        guard let imageProvider = providers.image else { throw PrismError.missingImageProvider }
        let director = providers.text(for: .artDirector)
        let p = Self.parsePrompt(try await director.complete(request.text))
        let avoid = request.input.state.constraints.filter { $0.isActive && $0.kind == .mustAvoid }.map(\.text)
        let negative = ([p.negative ?? ""] + avoid).map(\.trimmed).filter { !$0.isEmpty }.joined(separator: ", ")
        let result = try await imageProvider.generate(
            ImageJob(prompt: p.prompt, negative: negative, quality: request.input.quality, seed: request.seed))
        return Generated(
            output: Output(kind: .image, imagePrompt: p.prompt, provider: imageProvider.name,
                           model: imageProvider.model, promptModel: "Art Director: \(director.name) \(director.model)",
                           agent: "Art Director + Renderer"),
            asset: result.data, assetExtension: result.fileExtension)
    }
}

// MARK: - Registry

public enum Domains {
    public static let all: [any DomainAdapter] = [text, ImageAdapter(), BlenderStageAdapter(), BlenderAnimationAdapter(), TextToVideoAdapter(), ImageToVideoAdapter(), video, music, code, research]

    public static func adapter(for id: String) -> any DomainAdapter {
        all.first { $0.id == id } ?? text
    }

    public static let text = TextAdapter(
        id: "text", name: "Text", symbol: "text.alignleft", status: .ready,
        capabilities: OutputCapabilities(kind: .text, editable: true, exportFormats: ["md", "txt"]),
        dialHint: "tone, detail, reading level, symbolic depth, structure, directness, warmth, voice",
        role: "You are a skilled writer: stories and characters, community and business communication, educational explanations and reflective prompts.",
        format: "Plain prose with light Markdown (bold, italic, lists). Add headings only if the dials call for structure.",
        previewTokens: 600, renderTokens: 4000)

    public static let video = TextAdapter(
        id: "video", name: "Video Storyboard", symbol: "rectangle.split.3x1",
        status: .unfinished("Storyboard only. For real clips use Text to Video or Image to Video."),
        capabilities: OutputCapabilities(kind: .storyboard, editable: true, exportFormats: ["md"]),
        dialHint: "pacing, visual detail, historical reference, technical accuracy, humor, narration style",
        role: "You are a director and educational video producer.",
        format: "A storyboard. For every scene use exactly:\n## Scene N — Title (start–end)\nVisual: what is on screen\nNarration: what is said\nOn-screen text: captions or labels",
        previewTokens: 800, renderTokens: 4000)

    public static let music = TextAdapter(
        id: "music", name: "Music", symbol: "music.note",
        status: .unfinished("Direction and structure sketch only. No audio is generated."),
        capabilities: OutputCapabilities(kind: .text, editable: true, exportFormats: ["md"]),
        dialHint: "energy, complexity, era, mood, instrumentation, genre strictness, groove",
        role: "You are a composer and producer.",
        format: "A written music sketch: tempo, key and instrumentation, then each section with bar count, chords, and a short description of melody and rhythm.",
        previewTokens: 600, renderTokens: 3000)

    public static let code = TextAdapter(
        id: "code", name: "Code", symbol: "chevron.left.forwardslash.chevron.right",
        status: .unfinished("Outline or code preview only. Code is never run or checked."),
        capabilities: OutputCapabilities(kind: .code, editable: true, exportFormats: ["txt"]),
        dialHint: "simplicity vs performance, safety, flexibility, dependencies, comment density",
        role: "You are a senior software engineer.",
        format: "A single code file with brief comments. No prose before or after.",
        previewTokens: 1200, renderTokens: 6000, agent: .coder)

    public static let research = TextAdapter(
        id: "research", name: "Research", symbol: "magnifyingglass",
        status: .unfinished("Research plan and explanation structure only. Nothing is looked up or verified."),
        capabilities: OutputCapabilities(kind: .text, editable: true, exportFormats: ["md"]),
        dialHint: "breadth, depth, skepticism, recency focus, speculation, audience",
        role: "You are a careful research planner.",
        format: "A research plan: key questions, what evidence would answer each, likely sources to check, and an outline for the explanation. Never state findings as verified.",
        previewTokens: 700, renderTokens: 3000)
}
