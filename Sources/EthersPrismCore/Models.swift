import Foundation

/// One dial: a single dimension with two named ends. 0 = lowPole, 100 = highPole.
public struct Dial: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var lowPole: String
    public var highPole: String
    public var value: Double
    public var locked: Bool

    public init(id: UUID = UUID(), name: String, lowPole: String, highPole: String,
                value: Double = 50, locked: Bool = false) {
        self.id = id
        self.name = name
        self.lowPole = lowPole
        self.highPole = highPole
        self.value = min(max(value, 0), 100)
        self.locked = locked
    }
}

public enum OutputKind: String, Codable, Sendable {
    case text, code, svg, storyboard
}

/// Preview = fast, cheap draft. Render = full quality, only when asked.
public enum Quality: String, Codable, Sendable {
    case preview, render
}

/// A state the person visited: the dials at that moment plus what they produced.
public struct Snapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var parentID: UUID?
    public var createdAt: Date
    public var axes: [Dial]
    public var quality: Quality
    public var output: String
    public var chosen: Bool

    public init(id: UUID = UUID(), parentID: UUID?, createdAt: Date = Date(), axes: [Dial],
                quality: Quality, output: String, chosen: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.createdAt = createdAt
        self.axes = axes
        self.quality = quality
        self.output = output
        self.chosen = chosen
    }
}

public struct TreeRow: Identifiable, Hashable, Sendable {
    public var snapshot: Snapshot
    public var depth: Int
    public var id: UUID { snapshot.id }
}

public struct Session: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var goal: String
    public var domainID: String
    public var axes: [Dial]
    public var snapshots: [Snapshot]
    public var currentSnapshotID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String = "Untitled", goal: String = "",
                domainID: String = "text", axes: [Dial] = []) {
        self.id = id
        self.title = title
        self.goal = goal
        self.domainID = domainID
        self.axes = axes
        self.snapshots = []
        self.currentSnapshotID = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

public enum PrismError: LocalizedError, Equatable {
    case missingAPIKey
    case badAxisJSON
    case emptyResponse
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Anthropic API key in Settings (⌘,), or switch the provider to Offline demo."
        case .badAxisJSON:
            return "The AI's dial suggestions couldn't be read. Try Suggest Dials again."
        case .emptyResponse:
            return "The AI returned an empty response."
        case .http(let code, let body):
            return "The AI service returned an error (\(code)). \(body.prefix(300))"
        }
    }
}

public extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
