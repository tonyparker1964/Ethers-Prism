import Foundation

/// Any server that speaks the OpenAI chat format: LM Studio, Ollama and others.
public struct OpenAICompatibleTextProvider: TextProvider {
    public let name: String
    public var model: String
    public var baseURL: String

    public init(name: String, baseURL: String, model: String) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    static func url(_ base: String, _ path: String) -> URL? {
        var b = base.trimmed
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/v1") { b.removeLast(3) }
        return URL(string: b + path)
    }

    /// Qwen3 general models think out loud by default; this asks them not to, which is much faster.
    static func wantsNoThink(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("qwen3") && !m.contains("coder")
    }

    public func complete(_ request: TextRequest) async throws -> String {
        guard !model.trimmed.isEmpty else { throw PrismError.local("Choose a model for this agent in Settings → Agents.") }
        guard let url = Self.url(baseURL, "/v1/chat/completions") else {
            throw PrismError.local("\(name)'s address in Settings isn't a valid URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600 // the first call may have to load the model from disk
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let user = Self.wantsNoThink(model) ? request.user + "\n/no_think" : request.user
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": request.system], ["role": "user", "content": user]],
            "max_tokens": request.maxTokens,
            "temperature": 0.7,
            "stream": false
        ]
        var payload = body
        if let schema = request.schema, let obj = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) {
            payload["response_format"] = ["type": "json_schema",
                                          "json_schema": ["name": "answer", "strict": true, "schema": obj] as [String: Any]] as [String: Any]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw e
        } catch {
            throw PrismError.local("\(name) isn't reachable at \(baseURL). Open \(name) and start its local server.")
        }
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PrismError.local(Self.friendlyError(status: status, data: data, server: name, model: model))
        }
        let text = try JSONDecoder().decode(ChatResponse.self, from: data).choices.first?.message.content ?? ""
        let cleaned = OutputCleaner.stripThinking(text)
        guard !cleaned.isEmpty else { throw PrismError.emptyResponse }
        return cleaned
    }

    /// Turns a server error into a sentence a person can act on.
    static func friendlyError(status: Int, data: Data, server: String, model: String) -> String {
        var message = String(data: data, encoding: .utf8) ?? ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { message = m }
            else if let m = obj["error"] as? String { message = m }
        }
        if message.lowercased().contains("no models loaded") || message.lowercased().contains("not found") {
            return "\(server) can't find the model “\(model)”. In Settings → Agents, press Check Connection and pick one of the listed models."
        }
        return "\(server) returned an error (\(status)): \(message.prefix(300))"
    }

    /// Model ids the server offers, for the Settings pickers.
    public static func models(baseURL: String) async throws -> [String] {
        guard let url = url(baseURL, "/v1/models") else { throw PrismError.local("That address isn't a valid URL.") }
        let data: Data
        do {
            data = try await URLSession.shared.data(from: url).0
        } catch {
            throw PrismError.local("Nothing is answering at \(baseURL). Is the local server running?")
        }
        struct List: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]
        }
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }
}

/// Large local language models and ComfyUI can't both fit in 24 GB, so they take turns.
public enum LocalMemory {
    /// True for models of 20B parameters or more, read from the model name ("30b", "32B", "70b").
    public static func isLarge(_ model: String) -> Bool {
        let m = model.lowercased()
        var best = 0
        var digits = ""
        for ch in m {
            if ch.isNumber {
                digits.append(ch)
            } else {
                if ch == "b", let n = Int(digits) { best = max(best, n) }
                digits = ""
            }
        }
        return best >= 20
    }

    /// Asks ComfyUI to release its models. Failures are ignored: ComfyUI may simply not be running.
    public static func freeComfyUI(baseURL: String) async {
        guard let url = URL(string: baseURL.trimmed)?.appendingPathComponent("free") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["unload_models": true, "free_memory": true])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Finds loaded model instance ids in LM Studio's /api/v1/models answer, wherever they appear.
    public static func loadedInstanceIDs(in json: Any) -> [String] {
        var out: [String] = []
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                if let instances = d["loaded_instances"] as? [[String: Any]] {
                    out += instances.compactMap { $0["id"] as? String }
                }
                d.values.forEach(walk)
            } else if let a = v as? [Any] {
                a.forEach(walk)
            }
        }
        walk(json)
        return Array(Set(out)).sorted()
    }

    /// Unloads large models from LM Studio so ComfyUI has room. Small models are left loaded.
    public static func unloadLargeLMStudioModels(baseURL: String) async {
        await unloadLMStudioModels(baseURL: baseURL, onlyLarge: true)
    }

    /// Unloads LM Studio models: only large ones, or all of them (video needs every gigabyte).
    public static func unloadLMStudioModels(baseURL: String, onlyLarge: Bool) async {
        guard let list = OpenAICompatibleTextProvider.url(baseURL, "/api/v1/models"),
              let unload = OpenAICompatibleTextProvider.url(baseURL, "/api/v1/models/unload"),
              let data = try? await URLSession.shared.data(from: list).0,
              let json = try? JSONSerialization.jsonObject(with: data) else { return }
        for id in loadedInstanceIDs(in: json) where !onlyLarge || isLarge(id) {
            var req = URLRequest(url: unload)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["instance_id": id])
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}

/// Frees ComfyUI's memory before a large local model runs.
public struct MemoryAwareTextProvider: TextProvider {
    public var inner: any TextProvider
    public var comfyURL: String
    public var name: String { inner.name }
    public var model: String { inner.model }

    public init(inner: any TextProvider, comfyURL: String) {
        self.inner = inner
        self.comfyURL = comfyURL
    }

    public func complete(_ request: TextRequest) async throws -> String {
        if LocalMemory.isLarge(inner.model) { await LocalMemory.freeComfyUI(baseURL: comfyURL) }
        return try await inner.complete(request)
    }
}

/// Unloads large LM Studio models before ComfyUI renders.
public struct MemoryAwareImageProvider: ImageProvider {
    public var inner: any ImageProvider
    public var lmStudioURL: String
    public var name: String { inner.name }
    public var model: String { inner.model }
    public var previewCostNote: String { inner.previewCostNote }

    public init(inner: any ImageProvider, lmStudioURL: String) {
        self.inner = inner
        self.lmStudioURL = lmStudioURL
    }

    public func generate(_ job: ImageJob) async throws -> ImageResult {
        await LocalMemory.unloadLargeLMStudioModels(baseURL: lmStudioURL)
        return try await inner.generate(job)
    }
}
