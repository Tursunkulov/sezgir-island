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
        onCancel = nil
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        let c = connection
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    fileprivate func clientWentAway() {
        guard !isDone else { return }
        isDone = true
        let cancel = onCancel
        onCancel = nil
        cancel?()
        connection.cancel()
    }
}

/// Tiny HTTP server for the Claude Code hook script: POST /hook with the hook's JSON, header X-Island-Token.
///
/// It listens on a Unix domain socket inside ~/Library/Application Support (folder mode 0700), not on a
/// TCP port: other users and sandboxed apps can neither connect to it nor squat it while the island is
/// not running, so nobody else can see hook traffic or answer Claude Code's permission prompts.
@MainActor
final class HookServer {
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicIsland", isDirectory: true) // legacy folder name, read by the hook script
    }
    static var socketURL: URL { supportDir.appendingPathComponent("hook.sock") }

    nonisolated private static let maxHeader = 16 << 10
    nonisolated private static let maxBody = 8 << 20

    private var listener: NWListener?
    private let token: String
    private(set) var failure: String?
    var handler: ((_ body: [String: Any], _ reply: HookReply) -> Void)?
    var onFailure: ((String) -> Void)?

    init() {
        token = HookServer.loadOrCreateToken()
    }

    func start() {
        let path = Self.socketURL.path
        // sockaddr_un.sun_path holds 104 bytes including the terminator.
        guard path.utf8.count < 104 else { return fail("Слишком длинный путь к сокету: \(path)") }
        // Leftovers from the old TCP version.
        try? FileManager.default.removeItem(at: Self.supportDir.appendingPathComponent("port"))
        unlink(path) // stale socket from a previous run
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .unix(path: path)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(conn) } }
            }
            l.stateUpdateHandler = { [weak self] state in
                if case .ready = state { chmod(path, 0o600) }
                if case .failed(let e) = state {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail("Сервер хуков упал: \(e)") } }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            fail("Не удалось запустить сервер хуков: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unlink(Self.socketURL.path)
    }

    private func fail(_ message: String) {
        NSLog("SezgirIsland: \(message)")
        failure = message
        onFailure?(message)
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        // A request has 15 s to arrive in full; then the connection is dropped.
        let reading = Box(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if reading.value { conn.cancel() }
        }
        receive(conn, buffer: Data(), reading: reading)
    }

    private final class Box: @unchecked Sendable {
        var value: Bool
        init(_ v: Bool) { value = v }
    }

    private func receive(_ conn: NWConnection, buffer: Data, reading: Box) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                switch Self.parse(buf) {
                case .complete(let headers, let body):
                    reading.value = false
                    self.handle(conn, headers: headers, body: body)
                case .invalid:
                    reading.value = false
                    HookReply(connection: conn).sendRaw(status: "400 Bad Request", body: Data())
                case .incomplete:
                    if isComplete || error != nil {
                        reading.value = false
                        conn.cancel()
                    } else {
                        self.receive(conn, buffer: buf, reading: reading)
                    }
                }
            }
        }
    }

    private func handle(_ conn: NWConnection, headers: [String: String], body: Data) {
        let reply = HookReply(connection: conn)
        guard let t = headers["x-island-token"], Self.constantTimeEqual(t, token) else {
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

    nonisolated private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private enum Parsed { case incomplete, invalid, complete([String: String], Data) }

    nonisolated private static func parse(_ buf: Data) -> Parsed {
        guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > maxHeader ? .invalid : .incomplete
        }
        guard range.lowerBound - buf.startIndex <= maxHeader else { return .invalid }
        let head = String(decoding: buf[buf.startIndex..<range.lowerBound], as: UTF8.self)
        var headers: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let raw = headers["content-length"] ?? "0"
        guard let length = Int(raw), (0...maxBody).contains(length) else { return .invalid }
        let body = buf[range.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .complete(headers, Data(body.prefix(length)))
    }

    /// Token + a curl header file with it (so the token never shows up in `ps` output).
    private static func loadOrCreateToken() -> String {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
        let url = supportDir.appendingPathComponent("token")
        var token = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if token.isEmpty {
            token = UUID().uuidString + UUID().uuidString
            writePrivate(token, to: url)
        }
        writePrivate("X-Island-Token: \(token)\n", to: supportDir.appendingPathComponent("header"))
        return token
    }

    /// Create the file as 0600 from the start (no window where it is world-readable).
    private static func writePrivate(_ text: String, to url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url) // also drops a symlink someone might have put there
        fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }
}
