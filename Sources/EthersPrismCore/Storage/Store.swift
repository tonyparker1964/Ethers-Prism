import Foundation

/// File-based persistence. Layout under the root folder:
///   Sessions/<id>.json        versioned session files
///   Assets/<session id>/...   generated media, referenced by relative path
///   Templates/<id>.json       reusable editors
public struct Store: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("Ethers Prism", isDirectory: true)
        }
        for dir in [sessionsDir, assetsDir, templatesDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public var sessionsDir: URL { root.appendingPathComponent("Sessions", isDirectory: true) }
    public var assetsDir: URL { root.appendingPathComponent("Assets", isDirectory: true) }
    public var templatesDir: URL { root.appendingPathComponent("Templates", isDirectory: true) }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Sessions

    public func save(_ session: Session) throws {
        try Self.encoder().encode(session).write(to: sessionsDir.appendingPathComponent("\(session.id.uuidString).json"),
                                                 options: .atomic)
    }

    public func loadAll() -> [Session] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decodeSession(Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent("\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: assetsDir.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    /// Decodes and validates a session file. Unsafe asset paths are dropped, never followed.
    public static func decodeSession(_ data: Data) throws -> Session {
        let session: Session
        do {
            session = try decoder().decode(Session.self, from: data)
        } catch {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let v = obj["schemaVersion"] as? Int, v > Session.currentSchemaVersion {
                throw PrismError.unsupportedVersion(v)
            }
            throw PrismError.invalidFile("it isn't an Ethers Prism session.")
        }
        guard session.schemaVersion <= Session.currentSchemaVersion else {
            throw PrismError.unsupportedVersion(session.schemaVersion)
        }
        var s = session
        for i in s.snapshots.indices {
            if let p = s.snapshots[i].output.assetPath, !isSafeRelative(p) { s.snapshots[i].output.assetPath = nil }
        }
        if let cur = s.currentSnapshotID, s.snapshot(cur) == nil { s.currentSnapshotID = s.snapshots.last?.id }
        return s
    }

    /// Imports a session file. A session whose id already exists gets a new id.
    public func importSession(from url: URL) throws -> Session {
        var s = try Self.decodeSession(Data(contentsOf: url))
        if FileManager.default.fileExists(atPath: sessionsDir.appendingPathComponent("\(s.id.uuidString).json").path) {
            s.id = UUID()
        }
        s.updatedAt = Date()
        try save(s)
        return s
    }

    public func exportData(_ session: Session) throws -> Data {
        try Self.encoder().encode(session)
    }

    // MARK: Assets

    /// Writes media for a session and returns its portable relative path.
    public func saveAsset(_ data: Data, ext: String, sessionID: UUID, name: String) throws -> String {
        let safeExt = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        let file = "\(name).\(safeExt.isEmpty ? "bin" : safeExt)"
        let dir = assetsDir.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(file), options: .atomic)
        return "Assets/\(sessionID.uuidString)/\(file)"
    }

    /// Resolves a stored relative path, refusing anything that could leave the store.
    public func assetURL(_ relative: String?) -> URL? {
        guard let relative, Self.isSafeRelative(relative) else { return nil }
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return url
    }

    public static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              !path.contains(":") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "Assets", parts.count >= 3 else { return false }
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    // MARK: Templates

    public func saveTemplate(_ t: EditorTemplate) throws {
        try Self.encoder().encode(t).write(to: templatesDir.appendingPathComponent("\(t.id.uuidString).json"),
                                           options: .atomic)
    }

    public func deleteTemplate(_ id: UUID) {
        try? FileManager.default.removeItem(at: templatesDir.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Loads templates, writing the built-in examples once so they can be edited like any other.
    public func loadTemplates() -> [EditorTemplate] {
        let seededFlag = templatesDir.appendingPathComponent(".seeded")
        if !FileManager.default.fileExists(atPath: seededFlag.path) {
            for t in EditorTemplate.examples { try? saveTemplate(t) }
            try? Data().write(to: seededFlag)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder().decode(EditorTemplate.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.builtIn ? 0 : 1, $0.name) < ($1.builtIn ? 0 : 1, $1.name) }
    }
}
