import Foundation

public struct MCPTool: Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var id: String { name }

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public struct MCPToolResult: Sendable {
    public var texts: [String]
    public var images: [Data]
    public var isError: Bool
}

/// A minimal Model Context Protocol client over a child process's stdin/stdout (one JSON object per line).
public final class StdioMCPClient: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 1
    private let lock = NSLock()

    public init(executable: URL, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    deinit { stop() }

    public func start() throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { self?.failAll(PrismError.mixar("the connector stopped.")) } else { self?.receive(chunk) }
        }
        p.terminationHandler = { [weak self] _ in self?.failAll(PrismError.mixar("the connector stopped.")) }
        try p.run()
        process = p
        input = stdinPipe.fileHandleForWriting
    }

    public func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        failAll(CancellationError())
    }

    private func receive(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int else { continue }
            lock.lock()
            let cont = pending.removeValue(forKey: id)
            lock.unlock()
            cont?.resume(returning: line)
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        all.values.forEach { $0.resume(throwing: error) }
    }

    private func send(_ object: [String: Any]) throws {
        try sendLine(try JSONSerialization.data(withJSONObject: object))
    }

    private func sendLine(_ payload: Data) throws {
        guard let input else { throw PrismError.mixar("the connector isn't running.") }
        var data = payload
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    /// Sends a request and waits for its answer (or the timeout).
    public func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> [String: Any] {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        let payload = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ] as [String: Any])
        let line: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    self.lock.lock()
                    self.pending[id] = cont
                    self.lock.unlock()
                    do { try self.sendLine(payload) } catch {
                        self.lock.lock()
                        let c = self.pending.removeValue(forKey: id)
                        self.lock.unlock()
                        c?.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                let err = PrismError.mixar("no answer within \(Int(timeout)) seconds.")
                // Release the waiting request too, so the group can finish.
                self.lock.lock()
                let waiting = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                waiting?.resume(throwing: err)
                throw err
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PrismError.emptyResponse }
            return first
        }
        lock.lock()
        pending.removeValue(forKey: id)
        lock.unlock()
        guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw PrismError.emptyResponse }
        if let err = obj["error"] as? [String: Any] {
            throw PrismError.mixar(err["message"] as? String ?? "the request failed.")
        }
        return obj["result"] as? [String: Any] ?? [:]
    }

    public func notify(_ method: String, params: [String: Any] = [:]) throws {
        try send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    public func initialize() async throws {
        _ = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Ethers Prism", "version": "1.0"]
        ], timeout: 30)
        try notify("notifications/initialized")
    }

    public static func parseTools(_ result: [String: Any]) -> [MCPTool] {
        (result["tools"] as? [[String: Any]] ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return MCPTool(name: name, description: (t["description"] as? String ?? "").trimmed)
        }
    }

    public func listTools() async throws -> [MCPTool] {
        Self.parseTools(try await request("tools/list", timeout: 60))
    }

    public func callTool(_ name: String, arguments: [String: Any], timeout: TimeInterval = 610) async throws -> MCPToolResult {
        let result = try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: timeout)
        var texts: [String] = []
        var images: [Data] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            if item["type"] as? String == "text", let t = item["text"] as? String { texts.append(t) }
            if item["type"] as? String == "image", let b64 = item["data"] as? String, let d = Data(base64Encoded: b64) {
                images.append(d)
            }
        }
        return MCPToolResult(texts: texts, images: images, isError: result["isError"] as? Bool ?? false)
    }
}

/// Mixar, the AI 3D editor built on Blender, exposes its scene and render tools through "Connect MCP".
public enum Mixar {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case connectOff
        case ready
    }

    static var connectorFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mixar/connector", isDirectory: true)
    }

    public static var launcher: URL { connectorFolder.appendingPathComponent("mixar-mcp") }

    public static func status() -> Status {
        let info = connectorFolder.appendingPathComponent("installation.json")
        guard FileManager.default.fileExists(atPath: launcher.path),
              let data = try? Data(contentsOf: info),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .notInstalled }
        return (obj["enabled"] as? Bool) == true ? .ready : .connectOff
    }

    /// Starts the connector and lists Mixar's tools. Listing is free; only AI generation in Mixar costs credits.
    public static func connect() async throws -> (StdioMCPClient, [MCPTool]) {
        switch status() {
        case .notInstalled:
            throw PrismError.mixar("not found. Install Mixar and open it once.")
        case .connectOff:
            throw PrismError.mixar("Connect MCP is off. In Mixar, open the profile menu (top right) → Connect MCP and turn it on.")
        case .ready:
            break
        }
        let client = StdioMCPClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [launcher.path])
        try client.start()
        do {
            try await client.initialize()
            return (client, try await client.listTools())
        } catch {
            client.stop()
            throw error
        }
    }
}
