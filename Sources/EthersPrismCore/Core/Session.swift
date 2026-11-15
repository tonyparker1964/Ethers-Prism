import Foundation

public enum OutputKind: String, Codable, Hashable, Sendable {
    case text, code, image, storyboard, video, audio
}

public enum Quality: String, Codable, Hashable, Sendable {
    case preview, render
}

/// How a history state came to exist.
public enum Origin: String, Codable, Hashable, Sendable {
    case preview, render, manualEdit, sweep, imported

    public var label: String {
        switch self {
        case .preview: return "Preview"
        case .render: return "Full render"
        case .manualEdit: return "Manual edit"
        case .sweep: return "Sweep pick"
        case .imported: return "Imported"
        }
    }
}

/// What a generation produced. Media lives in an asset file referenced by a relative path.
public struct Output: Codable, Hashable, Sendable {
    public var kind: OutputKind
    public var text: String?
    public var assetPath: String?
    /// The prompt actually sent to an image model, when there was one.
    public var imagePrompt: String?
    public var provider: String
    public var model: String
    public var promptModel: String?
    /// Which agent made this (for example "Writer").
    public var agent: String?
    /// The Checker's review, added after generation. Never changes the result itself.
    public var review: Review?
    /// Beats: the sample files that were played, so a rating can teach Prism which sounds you like.
    public var samples: [String]?
    /// Beats: your rating, +1 (like) or -1 (not for me).
    public var rating: Int?

    public init(kind: OutputKind, text: String? = nil, assetPath: String? = nil, imagePrompt: String? = nil,
                provider: String, model: String, promptModel: String? = nil, agent: String? = nil, review: Review? = nil,
                samples: [String]? = nil) {
        self.kind = kind
        self.text = text
        self.assetPath = assetPath
        self.imagePrompt = imagePrompt
        self.provider = provider
        self.model = model
        self.promptModel = promptModel
        self.agent = agent
        self.review = review
        self.samples = samples
        self.rating = nil
    }
}

/// Everything that decides what gets generated. Two equal states compile to the same request.
public struct ImageReference: Codable, Hashable, Sendable {
    public var path: String
    public var denoise: Double

    public init(path: String, denoise: Double = 0.25) {
        self.path = path
        self.denoise = denoise
    }
}

public struct WorkingState: Codable, Hashable, Sendable {
    public var goal: String
    public var domainID: String
    public var dials: [Dial]
    public var constraints: [Constraint]
    public var imageReference: ImageReference?

    public init(goal: String, domainID: String, dials: [Dial], constraints: [Constraint], imageReference: ImageReference? = nil) {
        self.goal = goal
        self.domainID = domainID
        self.dials = dials
        self.constraints = constraints
        self.imageReference = imageReference
    }

    /// Equality that ignores lock state, which never changes what is generated.
    public func generatesSame(as other: WorkingState) -> Bool {
        func strip(_ d: [Dial]) -> [Dial] { d.map { var x = $0; x.locked = false; x.value = x.value.rounded(); return x } }
        return goal.trimmed == other.goal.trimmed && domainID == other.domainID
            && strip(dials) == strip(other.dials) && constraints == other.constraints && imageReference == other.imageReference
    }
}

/// A saved state in the history tree.
public struct Snapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var parentID: UUID?
    public var createdAt: Date
    public var state: WorkingState
    public var origin: Origin
    public var output: Output
    public var chosen: Bool
    public var note: String?

    public init(id: UUID = UUID(), parentID: UUID?, createdAt: Date = Date(), state: WorkingState,
                origin: Origin, output: Output, chosen: Bool = false, note: String? = nil) {
        self.id = id
        self.parentID = parentID
        self.createdAt = createdAt
        self.state = state
        self.origin = origin
        self.output = output
        self.chosen = chosen
        self.note = note
    }

    public var quality: Quality { origin == .render ? .render : .preview }
}

public struct Session: Codable, Identifiable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var goal: String
    public var domainID: String
    public var dials: [Dial]
    public var constraints: [Constraint]
    public var imageReference: ImageReference?
    public var snapshots: [Snapshot]
    public var currentSnapshotID: UUID?
    public var templateID: UUID?
    /// Reserved for linking sessions in different fields under one shared project goal.
    public var projectID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String = "Untitled", goal: String = "", domainID: String = "text",
                dials: [Dial] = [], constraints: [Constraint] = [], templateID: UUID? = nil) {
        self.schemaVersion = Session.currentSchemaVersion
        self.id = id
        self.title = title
        self.goal = goal
        self.domainID = domainID
        self.dials = dials
        self.constraints = constraints
        self.snapshots = []
        self.currentSnapshotID = nil
        self.templateID = templateID
        self.projectID = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var workingState: WorkingState {
        get { WorkingState(goal: goal, domainID: domainID, dials: dials, constraints: constraints, imageReference: imageReference) }
        set {
            goal = newValue.goal
            domainID = newValue.domainID
            dials = newValue.dials
            constraints = newValue.constraints
            imageReference = newValue.imageReference
        }
    }

    public mutating func setGoal(_ text: String) {
        goal = text
        title = text.trimmed.isEmpty ? "Untitled" : String(text.trimmed.prefix(48))
    }
}

/// A reusable editor: dial definitions, defaults and constraints, without any history.
public struct EditorTemplate: Codable, Identifiable, Hashable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var summary: String
    public var domainID: String
    public var dials: [Dial]
    public var constraints: [Constraint]
    public var builtIn: Bool

    public init(id: UUID = UUID(), name: String, summary: String, domainID: String,
                dials: [Dial], constraints: [Constraint], builtIn: Bool = false) {
        self.schemaVersion = Session.currentSchemaVersion
        self.id = id
        self.name = name
        self.summary = summary
        self.domainID = domainID
        self.dials = dials
        self.constraints = constraints
        self.builtIn = builtIn
    }

    /// Captures a session's editor (not its history or goal).
    public static func from(_ session: Session, name: String, summary: String) -> EditorTemplate {
        EditorTemplate(name: name, summary: summary, domainID: session.domainID,
                       dials: session.dials.map { var d = $0; d.locked = false; return d },
                       constraints: session.constraints)
    }

    /// A brand new session for a new goal. Nothing from any earlier session's history is copied.
    public func makeSession(goal: String) -> Session {
        var s = Session(domainID: domainID, dials: dials.map { $0.withNewID() },
                        constraints: constraints.map { $0.withNewID() }, templateID: id)
        s.setGoal(goal)
        return s
    }
}
