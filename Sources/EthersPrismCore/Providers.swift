import Foundation

/// Anything that can answer a compiled request. Swap providers without touching the core.
public protocol ModelProvider: Sendable {
    func complete(_ request: CompiledRequest) async throws -> String
}

public struct AnthropicProvider: ModelProvider {
    public var apiKey: String
    public var model: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    private struct MessagesResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    public func complete(_ request: CompiledRequest) async throws -> String {
        guard !apiKey.trimmed.isEmpty else { throw PrismError.missingAPIKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(apiKey.trimmed, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PrismError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        let text = decoded.content.compactMap(\.text).joined()
        guard !text.trimmed.isEmpty else { throw PrismError.emptyResponse }
        return text
    }
}

/// Works with no key and no network, so the instrument can be tried and tested offline.
public struct MockProvider: ModelProvider {
    public init() {}

    public func complete(_ request: CompiledRequest) async throws -> String {
        try? await Task.sleep(nanoseconds: 250_000_000)
        let seed = request.user.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }

        if request.system.contains(AxisSuggester.marker) {
            return """
            [{"name":"Detail","low":"bare essentials","high":"richly detailed"},
             {"name":"Tone","low":"serious","high":"playful"},
             {"name":"Technical accuracy","low":"loose analogy","high":"textbook precise"},
             {"name":"Historical reference","low":"none","high":"steeped in history"},
             {"name":"Energy","low":"calm","high":"intense"},
             {"name":"Audience","low":"beginners","high":"experts"}]
            """
        }

        let dials = request.user.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        let goal = request.user.components(separatedBy: "\n").first ?? ""
        let system = request.system.lowercased()

        if system.contains("svg") { return Self.svg(seed: seed) }
        if system.contains("storyboard") {
            return """
            ## Scene 1 — Opening (0:00–0:20)
            Visual: Offline demo scene \(seed % 97)
            Narration: \(goal)
            On-screen text: Ethers Prism demo

            ## Scene 2 — How the dials shape it (0:20–0:50)
            Visual: Shapes rearranging as the dials move
            Narration: This storyboard reflects:
            \(dials.joined(separator: "\n"))
            """
        }
        return """
        **Offline demo output** (variation \(seed % 997))

        \(goal)

        This draft would be shaped by your dials:
        \(dials.joined(separator: "\n"))

        Add an Anthropic API key in Settings to generate real results.
        """
    }

    static func svg(seed: Int) -> String {
        var rng = UInt64(seed) | 1
        func next() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % 1000)
        }
        let hue = seed % 360
        var shapes = ""
        for _ in 0..<(4 + seed % 6) {
            shapes += "<circle cx=\"\(next() % 800)\" cy=\"\(next() % 600)\" r=\"\(20 + next() % 120)\" "
                + "fill=\"hsl(\((hue + next() % 90) % 360),70%,60%)\" fill-opacity=\"0.7\"/>"
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 800 600\">"
            + "<rect width=\"800\" height=\"600\" fill=\"hsl(\(hue),40%,15%)\"/>\(shapes)"
            + "<text x=\"24\" y=\"576\" fill=\"white\" font-family=\"sans-serif\" font-size=\"20\">Offline demo</text></svg>"
    }
}

/// Sessions are portable JSON files.
public struct SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("Ethers Prism/Sessions", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public func save(_ session: Session) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(session).write(to: url(for: session.id), options: .atomic)
    }

    public func loadAll() -> [Session] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Session.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
