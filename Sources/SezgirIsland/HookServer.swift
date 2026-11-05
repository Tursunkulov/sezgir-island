import Foundation
import Network

/// One held HTTP request from the Claude Code hook script. Answer it with `send`,
/// or learn via `onCancel` that Claude Code gave up (timeout, answered in the app, interrupted).
@MainActor
final class HookReply {
    private let connection: NWConnection
    private(set) var isDone = false
    var onCancel: (() -> Void)?

    init(connection: NWConnection) { self.connection = connection }

    func send(_ object: [String: Any]?) {
        let body = object.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        sendRaw(status: "200 OK", body: body)
    }

    func sendRaw(status: String, body: Data) {
        guard !isDone else { return }
        isDone = true
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        let c = connection
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    fileprivate func clientWentAway() {
        guard !isDone else { return }
        isDone = true
        onCancel?()
        connection.cancel()
    }
}

/// Tiny localhost HTTP server: POST /hook with the hook's JSON, header X-Island-Token.
@MainActor
final class HookServer {
    static let port: UInt16 = 47_823
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicIsland", isDirectory: true) // legacy folder name, read by the hook script
    }

    private var listener: NWListener?
    private let token: String
    var handler: ((_ body: [String: Any], _ reply: HookReply) -> Void)?

    init() {
        token = HookServer.loadOrCreateToken()
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(conn) } }
            }
            l.stateUpdateHandler = { state in
                if case .failed(let e) = state { NSLog("SezgirIsland: hook server failed: \(e)") }
            }
            l.start(queue: .main)
            listener = l
            try? "\(Self.port)".write(to: Self.supportDir.appendingPathComponent("port"), atomically: true, encoding: .utf8)
        } catch {
            NSLog("SezgirIsland: hook server error: \(error)")
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let (headers, body) = Self.parse(buf) {
                    self.handle(conn, headers: headers, body: body)
                } else if isComplete || error != nil || buf.count > 8 << 20 {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buf)
                }
            }
        }
    }

    private func handle(_ conn: NWConnection, headers: [String: String], body: Data) {
        let reply = HookReply(connection: conn)
        guard headers["x-island-token"] == token else {
            reply.sendRaw(status: "403 Forbidden", body: Data())
            return
        }
        watchForClose(conn, reply: reply)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            reply.send(nil)
            return
        }
        handler?(obj, reply) ?? reply.send(nil)
    }

    /// curl keeps the socket open while it waits for our answer; EOF means the hook was killed.
    private func watchForClose(_ conn: NWConnection, reply: HookReply) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            MainActor.assumeIsolated {
                if reply.isDone { return }
                if isComplete || error != nil { reply.clientWentAway() }
                else { self?.watchForClose(conn, reply: reply) }
            }
        }
    }

    nonisolated private static func parse(_ buf: Data) -> ([String: String], Data)? {
        guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<range.lowerBound], as: UTF8.self)
        var headers: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[range.upperBound...]
        guard body.count >= length else { return nil }
        return (headers, Data(body.prefix(length)))
    }

    private static func loadOrCreateToken() -> String {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let url = supportDir.appendingPathComponent("token")
        if let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        let t = UUID().uuidString + UUID().uuidString
        try? t.write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }
}
