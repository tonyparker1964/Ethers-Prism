import Foundation

/// One adjustable quality with two named ends. 0 = lowPole, 100 = highPole.
public struct Dial: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// What the dial is about, in a sentence.
    public var detail: String
    public var lowPole: String
    public var highPole: String
    public var value: Double {
        didSet { value = Dial.clamp(value) }
    }
    public var locked: Bool

    public init(id: UUID = UUID(), name: String, detail: String = "", lowPole: String, highPole: String,
                value: Double = 50, locked: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.lowPole = lowPole
        self.highPole = highPole
        self.value = Dial.clamp(value)
        self.locked = locked
    }

    public static func clamp(_ v: Double) -> Double {
        v.isFinite ? min(max(v, 0), 100) : 50
    }

    public var intValue: Int { Int(value.rounded()) }

    private enum CodingKeys: String, CodingKey {
        case id, name, detail, lowPole, highPole, value, locked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        lowPole = try c.decode(String.self, forKey: .lowPole)
        highPole = try c.decode(String.self, forKey: .highPole)
        value = Dial.clamp(try c.decodeIfPresent(Double.self, forKey: .value) ?? 50)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }

    /// The same dial definition with a fresh identity (used when copying into a new session).
    public func withNewID() -> Dial {
        var d = self
        d.id = UUID()
        return d
    }
}

public enum DialIssue: Hashable, Sendable {
    case emptyName(UUID)
    case emptyPole(UUID)
    case duplicateID(UUID)
    case duplicateName(String)

    public var message: String {
        switch self {
        case .emptyName: return "A dial needs a name."
        case .emptyPole: return "Both ends of a dial need a description."
        case .duplicateID: return "Two dials share the same identity."
        case .duplicateName(let n): return "Two dials are both named “\(n)”."
        }
    }
}

public enum DialRules {
    public static func issues(in dials: [Dial]) -> [DialIssue] {
        var out: [DialIssue] = []
        var ids = Set<UUID>()
        var names = Set<String>()
        for d in dials {
            if d.name.trimmed.isEmpty { out.append(.emptyName(d.id)) }
            if d.lowPole.trimmed.isEmpty || d.highPole.trimmed.isEmpty { out.append(.emptyPole(d.id)) }
            if !ids.insert(d.id).inserted { out.append(.duplicateID(d.id)) }
            let key = d.name.trimmed.lowercased()
            if !key.isEmpty, !names.insert(key).inserted { out.append(.duplicateName(d.name.trimmed)) }
        }
        return out
    }
}

/// Fixed requirements. These are never put on a slider, because a slider implies they can be reduced.
public enum ConstraintKind: String, Codable, CaseIterable, Hashable, Sendable {
    case mustInclude, mustAvoid, accuracy, accessibility, other

    public var label: String {
        switch self {
        case .mustInclude: return "Must include"
        case .mustAvoid: return "Must avoid"
        case .accuracy: return "Accuracy"
        case .accessibility: return "Accessibility"
        case .other: return "Requirement"
        }
    }
}

public struct Constraint: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: ConstraintKind
    public var text: String
    public var isActive: Bool

    public init(id: UUID = UUID(), kind: ConstraintKind, text: String, isActive: Bool = true) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isActive = isActive
    }

    public func withNewID() -> Constraint {
        var c = self
        c.id = UUID()
        return c
    }
}

public extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum DialCommands {
    /// Validate the entire batch before returning the updated dial values.
    public static func apply(_ text: String, to dials: [Dial]) throws -> [Dial] {
        var updated = dials
        var seen = Set<Int>()
        for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
            guard !line.trimmed.isEmpty else { continue }
            let fields = line.split(separator: "=", omittingEmptySubsequences: false)
            let prefix = "Line \(offset + 1)"
            guard fields.count == 2, !String(fields[0]).trimmed.isEmpty,
                  let value = Double(String(fields[1]).trimmed), value.isFinite, (0...100).contains(value) else {
                throw PrismError.local("\(prefix) must use Dial name = value, from 0 to 100.")
            }
            let name = String(fields[0]).trimmed
            let matches = dials.indices.filter { dials[$0].name.trimmed.lowercased() == name.lowercased() }
            guard let index = matches.first else {
                throw PrismError.local("\(prefix) refers to an unknown dial named “\(name)”.")
            }
            guard matches.count == 1, seen.insert(index).inserted else {
                throw PrismError.local("\(prefix) has a duplicate dial name “\(name)”.")
            }
            updated[index].value = value
        }
        return updated
    }
}
