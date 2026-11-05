import AppKit
import Observation

/// Live state of Claude Code sessions, fed by hooks (see HookInstaller).
/// Holds permission prompts / questions open until you answer them in the island.
@Observable
@MainActor
final class ClaudeCodeHub {
    enum SessionState { case idle, working, waiting, done }

    struct Session: Identifiable {
        let id: String
        var cwd: String
        var title: String?
        var state: SessionState = .idle
        var activity = "Сессия открыта"
        var started = Date()
        var updated = Date()
        var lastMessage: String?
        var name: String {
            if let title, !title.isEmpty { return title }
            let n = URL(fileURLWithPath: cwd).lastPathComponent
            return n.isEmpty ? "Claude Code" : n
        }
    }

    struct Question {
        struct Option { let label: String; let detail: String }
        let text: String
        let header: String
        let options: [Option]
        let multiSelect: Bool
    }

    enum RequestKind {
        case permission(suggestions: [Any])
        case question([Question])
    }

    struct Request: Identifiable {
        let id = UUID()
        let sessionID: String
        let toolName: String
        let input: [String: Any]
        let kind: RequestKind
        let reply: HookReply
        let created = Date()
    }

    enum SendResult { case continued, queued, notDelivered }

    // MARK: State

    private(set) var sessions: [String: Session] = [:]
    private(set) var requests: [Request] = []
    private(set) var queued: [String: [String]] = [:]
    private(set) var stopHoldDeadline: [String: Date] = [:]
    var selectedSessionID: String?

    @ObservationIgnored private var stopHolds: [String: HookReply] = [:]
    @ObservationIgnored private var stopTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var onAttention: (() -> Void)?
    @ObservationIgnored var onDone: ((Session) -> Void)?
    @ObservationIgnored var onRequestsCleared: (() -> Void)?

    /// How long Claude waits after finishing so you can send a follow-up from the island.
    static let replyWindow: TimeInterval = 25

    var orderedSessions: [Session] {
        sessions.values.sorted { a, b in
            if (a.state == .working) != (b.state == .working) { return a.state == .working }
            return a.updated > b.updated
        }
    }

    var isWorking: Bool { sessions.values.contains { $0.state == .working } }
    var hasRequests: Bool { !requests.isEmpty }
    var workingSince: Date? { sessions.values.filter { $0.state == .working }.map(\.started).min() }

    var selectedSession: Session? {
        if let id = selectedSessionID, let s = sessions[id] { return s }
        return orderedSessions.first
    }

    func canReplyNow(_ id: String) -> Bool { stopHolds[id] != nil }

    // MARK: Hook events

    func handle(_ o: [String: Any], reply: HookReply) {
        guard let event = o["hook_event_name"] as? String,
              let sid = o["session_id"] as? String else { reply.send(nil); return }

        pruneStale()
        var s = sessions[sid] ?? Session(id: sid, cwd: o["cwd"] as? String ?? "")
        if let cwd = o["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
        if let t = o["session_title"] as? String, !t.isEmpty { s.title = t }
        s.updated = Date()
        let tool = o["tool_name"] as? String ?? ""
        let input = o["tool_input"] as? [String: Any] ?? [:]
        var response: [String: Any]?

        switch event {
        case "SessionStart":
            if s.state != .working { s.state = .idle; s.activity = "Сессия открыта" }

        case "UserPromptSubmit":
            releaseStopHold(sid)
            s.state = .working
            s.started = Date()
            s.activity = "Думает…"

        case "PreToolUse":
            s.state = .working
            s.activity = Self.activity(tool: tool, input: input)
            if tool == "AskUserQuestion", !Self.claudeAppIsFrontmost, let qs = Self.parseQuestions(input), !qs.isEmpty {
                s.state = .waiting
                s.activity = "Задаёт вопрос"
                sessions[sid] = s
                hold(Request(sessionID: sid, toolName: tool, input: input, kind: .question(qs), reply: reply))
                return
            }

        case "PostToolUse":
            if let text = takeQueued(sid) {
                response = ["hookSpecificOutput": [
                    "hookEventName": "PostToolUse",
                    "additionalContext": "Новое сообщение от пользователя (отправлено из Sezgir Island, пока ты работал): \(text)",
                ]]
                s.activity = "Получил ваше сообщение"
            }

        case "PermissionRequest":
            if tool == "AskUserQuestion" { break } // answered via PreToolUse
            s.state = .waiting
            s.activity = "Ждёт разрешения"
            sessions[sid] = s
            let suggestions = o["permission_suggestions"] as? [Any] ?? []
            hold(Request(sessionID: sid, toolName: tool, input: input, kind: .permission(suggestions: suggestions), reply: reply))
            return

        case "Notification":
            let type = o["notification_type"] as? String ?? ""
            if type == "permission_prompt" || type == "agent_needs_input" || type == "elicitation_dialog",
               !requests.contains(where: { $0.sessionID == sid }) {
                s.state = .waiting
                s.activity = (o["message"] as? String) ?? "Нужен ваш ответ в Claude"
                sessions[sid] = s
                onAttention?()
            }

        case "Stop":
            s.lastMessage = (o["last_assistant_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text = takeQueued(sid) {
                s.activity = "Получил ваше сообщение"
                sessions[sid] = s
                reply.send(["decision": "block", "reason": Self.wrap(text)])
                return
            }
            s.state = .done
            s.activity = "Готово"
            sessions[sid] = s
            // You're already in the Claude app: reply there, don't keep the turn open.
            if Self.claudeAppIsFrontmost || (o["stop_hook_active"] as? Bool ?? false) {
                reply.send(nil)
            } else {
                holdStop(sid, reply: reply)
            }
            onDone?(s)
            return

        case "SessionEnd":
            sessions[sid] = nil
            releaseStopHold(sid)
            for r in requests where r.sessionID == sid { r.reply.send(nil) }
            requests.removeAll { $0.sessionID == sid }
            queued[sid] = nil
            reply.send(nil)
            return

        default:
            break
        }
        sessions[sid] = s
        reply.send(response)
    }

    private func hold(_ r: Request) {
        r.reply.onCancel = { [weak self] in
            // Answered in the Claude app, interrupted, or timed out.
            self?.remove(r.id, newState: nil)
        }
        requests.append(r)
        selectedSessionID = r.sessionID
        NSSound(named: "Tink")?.play()
        onAttention?()
    }

    private func remove(_ id: UUID, newState: SessionState?) {
        guard let r = requests.first(where: { $0.id == id }) else { return }
        requests.removeAll { $0.id == id }
        if var s = sessions[r.sessionID] {
            if let newState { s.state = newState; s.activity = newState == .working ? "Продолжает…" : s.activity }
            else if s.state == .waiting { s.state = .working; s.activity = "Продолжает…" }
            sessions[r.sessionID] = s
        }
        if requests.isEmpty { onRequestsCleared?() }
    }

    // MARK: Answering

    func allow(_ r: Request, always: Bool = false) {
        var decision: [String: Any] = ["behavior": "allow"]
        if always, case .permission(let suggestions) = r.kind, !suggestions.isEmpty {
            decision["updatedPermissions"] = suggestions
        }
        r.reply.send(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
        remove(r.id, newState: .working)
    }

    func deny(_ r: Request, message: String?) {
        let msg = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (msg?.isEmpty == false)
            ? "Пользователь отклонил это действие и пишет: \(msg!)"
            : "Пользователь отклонил это действие в Sezgir Island."
        r.reply.send(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                             "decision": ["behavior": "deny", "message": text]]])
        remove(r.id, newState: .working)
    }

    /// Hands the prompt back to the Claude app's own dialog.
    func passToApp(_ r: Request) {
        r.reply.send(nil)
        remove(r.id, newState: nil)
        if var s = sessions[r.sessionID] { s.state = .waiting; s.activity = "Ждёт ответа в Claude"; sessions[r.sessionID] = s }
        NSWorkspace.shared.open(URL(string: "claude://code/needs-input")!)
    }

    func answer(_ r: Request, answers: [String: String]) {
        var input = r.input
        input["answers"] = answers
        r.reply.send(["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "Ответ дан в Sezgir Island",
            "updatedInput": input,
        ]])
        remove(r.id, newState: .working)
    }

    // MARK: Messages to a session

    func send(_ text: String, to sid: String) -> SendResult {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, var s = sessions[sid] else { return .notDelivered }
        if let hold = stopHolds[sid] {
            stopHolds[sid] = nil
            stopTimers[sid]?.cancel(); stopTimers[sid] = nil
            stopHoldDeadline[sid] = nil
            hold.send(["decision": "block", "reason": Self.wrap(t)])
            s.state = .working; s.started = Date(); s.activity = "Получил ваше сообщение"
            sessions[sid] = s
            return .continued
        }
        if s.state == .working || s.state == .waiting {
            queued[sid, default: []].append(t)
            return .queued
        }
        return .notDelivered
    }

    /// While you're typing a reply, keep Claude waiting a bit longer.
    func extendReplyWindow(_ sid: String) {
        guard stopHolds[sid] != nil else { return }
        scheduleStopRelease(sid, after: 120)
    }

    private func holdStop(_ sid: String, reply: HookReply) {
        releaseStopHold(sid)
        stopHolds[sid] = reply
        reply.onCancel = { [weak self] in
            self?.stopHolds[sid] = nil
            self?.stopHoldDeadline[sid] = nil
        }
        scheduleStopRelease(sid, after: Self.replyWindow)
    }

    private func scheduleStopRelease(_ sid: String, after seconds: TimeInterval) {
        stopTimers[sid]?.cancel()
        stopHoldDeadline[sid] = Date().addingTimeInterval(seconds)
        stopTimers[sid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.releaseStopHold(sid)
        }
    }

    private func releaseStopHold(_ sid: String) {
        stopTimers[sid]?.cancel(); stopTimers[sid] = nil
        stopHoldDeadline[sid] = nil
        stopHolds.removeValue(forKey: sid)?.send(nil)
    }

    private func takeQueued(_ sid: String) -> String? {
        guard let q = queued[sid], !q.isEmpty else { return nil }
        queued[sid] = nil
        return q.joined(separator: "\n")
    }

    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-45 * 60)
        for (id, s) in sessions where s.updated < cutoff && s.state != .working && stopHolds[id] == nil
            && !requests.contains(where: { $0.sessionID == id }) {
            sessions[id] = nil
        }
    }

    func dismiss(_ sid: String) {
        releaseStopHold(sid)
        sessions[sid] = nil
        queued[sid] = nil
    }

    private static func wrap(_ text: String) -> String {
        "Новое сообщение от пользователя (из Sezgir Island): \(text)"
    }

    static var claudeAppIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.anthropic.claudefordesktop"
    }

    // MARK: Descriptions

    static func activity(tool: String, input: [String: Any]) -> String {
        func file(_ k: String = "file_path") -> String {
            URL(fileURLWithPath: input[k] as? String ?? "").lastPathComponent
        }
        switch tool {
        case "Bash": return "Терминал: " + oneLine(input["description"] as? String ?? input["command"] as? String ?? "")
        case "Read": return "Читает \(file())"
        case "Edit", "MultiEdit": return "Редактирует \(file())"
        case "Write": return "Пишет \(file())"
        case "NotebookEdit": return "Редактирует \(file("notebook_path"))"
        case "Grep": return "Ищет «\(oneLine(input["pattern"] as? String ?? ""))»"
        case "Glob": return "Ищет файлы \(input["pattern"] as? String ?? "")"
        case "WebFetch": return "Открывает \(URL(string: input["url"] as? String ?? "")?.host ?? "страницу")"
        case "WebSearch": return "Гуглит «\(oneLine(input["query"] as? String ?? ""))»"
        case "Agent", "Task": return "Агент: " + oneLine(input["description"] as? String ?? "")
        case "AskUserQuestion": return "Задаёт вопрос"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                return "MCP: " + (parts.last.map(String.init) ?? tool)
            }
            return tool
        }
    }

    struct PermissionDescription { let icon: String; let title: String; let subtitle: String?; let detail: String }

    static func describePermission(tool: String, input: [String: Any]) -> PermissionDescription {
        func s(_ k: String) -> String { input[k] as? String ?? "" }
        switch tool {
        case "Bash":
            return .init(icon: "terminal.fill", title: "Выполнить команду", subtitle: s("description").nilIfEmpty, detail: s("command"))
        case "Edit", "MultiEdit":
            let new = s("new_string")
            return .init(icon: "pencil", title: "Изменить \(URL(fileURLWithPath: s("file_path")).lastPathComponent)",
                         subtitle: s("file_path"), detail: new.isEmpty ? s("file_path") : new)
        case "Write":
            return .init(icon: "doc.badge.plus", title: "Записать \(URL(fileURLWithPath: s("file_path")).lastPathComponent)",
                         subtitle: s("file_path"), detail: String(s("content").prefix(600)))
        case "WebFetch":
            return .init(icon: "globe", title: "Открыть страницу", subtitle: s("prompt").nilIfEmpty, detail: s("url"))
        case "WebSearch":
            return .init(icon: "magnifyingglass", title: "Поиск в интернете", subtitle: nil, detail: s("query"))
        case "Read":
            return .init(icon: "doc.text", title: "Прочитать файл", subtitle: nil, detail: s("file_path"))
        default:
            let json = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            let title = tool.hasPrefix("mcp__") ? "MCP: \(tool.dropFirst(5).replacingOccurrences(of: "__", with: " · "))" : tool
            return .init(icon: "puzzlepiece.extension.fill", title: title, subtitle: nil, detail: String(json.prefix(800)))
        }
    }

    static func parseQuestions(_ input: [String: Any]) -> [Question]? {
        guard let arr = input["questions"] as? [[String: Any]] else { return nil }
        return arr.compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Question.Option? in
                guard let l = o["label"] as? String else { return nil }
                return .init(label: l, detail: o["description"] as? String ?? "")
            }
            return Question(text: text, header: q["header"] as? String ?? "", options: opts,
                            multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    private static func oneLine(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > 60 ? String(t.prefix(60)) + "…" : t
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
