import SwiftUI

// MARK: - Spark

/// Eight-ray spark used as the "Claude is working" indicator.
struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            let long = i % 2 == 0 ? r : r * 0.78
            let w = r * 0.17
            let tip = CGPoint(x: c.x + cos(a) * long, y: c.y + sin(a) * long)
            let l = CGPoint(x: c.x + cos(a + .pi / 2) * w, y: c.y + sin(a + .pi / 2) * w)
            let rr = CGPoint(x: c.x + cos(a - .pi / 2) * w, y: c.y + sin(a - .pi / 2) * w)
            p.move(to: l)
            p.addQuadCurve(to: tip, control: CGPoint(x: (l.x + tip.x) / 2 + cos(a) * w * 0.2, y: (l.y + tip.y) / 2 + sin(a) * w * 0.2))
            p.addQuadCurve(to: rr, control: CGPoint(x: (rr.x + tip.x) / 2 + cos(a) * w * 0.2, y: (rr.y + tip.y) / 2 + sin(a) * w * 0.2))
            p.closeSubpath()
        }
        p.addEllipse(in: CGRect(x: c.x - r * 0.22, y: c.y - r * 0.22, width: r * 0.44, height: r * 0.44))
        return p
    }
}

// MARK: - Compact states

struct ClaudeWorkingCompact: View {
    @Environment(IslandModel.self) private var model
    let side: CGFloat

    var body: some View {
        let h = model.notch.height
        CompactRow(side: side) {
            ClaudeSpark(size: h - 15, spinning: true)
                .padding(.leading, 11)
        } right: {
            Group {
                if model.media.isPlaying && model.media.hasMedia {
                    AudioBars(color: model.media.accent, playing: true, height: 13)
                } else if let since = model.claude.workingSince {
                    Text(since, style: .timer)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(claudeOrange.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.trailing, 10)
        }
    }
}

struct ClaudeAttentionCompact: View {
    @Environment(IslandModel.self) private var model
    let side: CGFloat

    private var label: String {
        guard let r = model.claude.requests.first else { return "Ответ" }
        if case .question = r.kind { return "Вопрос" }
        return "Разрешение"
    }

    var body: some View {
        CompactRow(side: side) {
            HStack(spacing: 7) {
                ZStack {
                    // Core Animation pulse: costs the app nothing per frame.
                    PulseCircle(color: claudeOrange)
                        .frame(width: 20, height: 20)
                    SparkShape().fill(claudeOrange).frame(width: 12, height: 12)
                }
                Text("Claude ждёт")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, 9)
        } right: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(claudeOrange)
                if model.claude.requests.count > 1 {
                    Text("\(model.claude.requests.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(Capsule().fill(claudeOrange))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.trailing, 11)
        }
    }
}

struct ClaudeDoneToast: View {
    @Environment(IslandModel.self) private var model
    let side: CGFloat

    var body: some View {
        CompactRow(side: side) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: model.lastDoneSession?.id)
                Text("Claude готов")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, 10)
        } right: {
            HStack(spacing: 5) {
                Text(model.lastDoneSession?.name ?? "")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(claudeOrange)
            }
            .padding(.trailing, 11)
        }
    }
}

// MARK: - Shared controls

struct ActionButton: View {
    enum Kind { case primary, secondary, destructive }
    let title: String
    var kind: Kind = .secondary
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind == .primary ? .white : kind == .destructive ? Color(red: 1, green: 0.45, blue: 0.42) : .white.opacity(0.9))
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(kind == .primary ? claudeOrange.opacity(hover ? 1 : 0.92) : .white.opacity(hover ? 0.15 : 0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(IslandButtonStyle(circle: false))
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct IconPill: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hover ? 0.15 : 0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(IslandButtonStyle(circle: false))
        .help(help)
        .onHover { hover = $0 }
    }
}

struct SessionTag: View {
    let name: String
    var extra = 0

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill").font(.system(size: 9.5))
            Text(name).lineLimit(1)
            if extra > 0 {
                Text("+\(extra)")
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5).frame(height: 15)
                    .background(Capsule().fill(claudeOrange))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
    }
}

struct IslandTextField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var height: CGFloat = 32
    let onSubmit: () -> Void

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.33)))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(.white)
            .focused(focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(focused.wrappedValue ? 0.1 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused.wrappedValue ? claudeOrange.opacity(0.7) : .white.opacity(0.06), lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: focused.wrappedValue)
    }
}

// MARK: - Permission card

struct PermissionCard: View {
    @Environment(IslandModel.self) private var model
    let request: ClaudeCodeHub.Request
    @State private var note = ""
    @FocusState private var noteFocused: Bool
    /// Buttons wake up a moment after the card appears, so a double-click on the previous card
    /// can't approve this one unseen.
    @State private var armed = false

    var body: some View {
        let hub = model.claude
        let d = ClaudeCodeHub.describePermission(tool: request.toolName, input: request.input)
        let suggestions: [Any] = { if case .permission(let s) = request.kind { return s }; return [] }()
        let canAlways = !suggestions.isEmpty

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Image(systemName: d.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(claudeOrange)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(claudeOrange.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(d.subtitle ?? "Claude Code просит разрешение")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                SessionTag(name: hub.sessions[request.sessionID]?.name ?? "Claude Code", extra: hub.requests.count - 1)
            }

            ScrollView {
                Text(d.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(height: canAlways ? 44 : 56)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))

            if canAlways {
                Text("«Всегда» запомнит: " + ClaudeCodeHub.describeSuggestions(suggestions))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, -4)
            }

            HStack(spacing: 7) {
                IslandTextField(placeholder: "Или скажите Claude, что сделать иначе…", text: $note, focused: $noteFocused) {
                    if !note.trimmingCharacters(in: .whitespaces).isEmpty { hub.deny(request, message: note) }
                }
                IconPill(icon: "arrow.up.forward.app", help: "Ответить в приложении Claude") { hub.passToApp(request) }
                ActionButton(title: note.isEmpty ? "Запретить" : "Отправить", kind: note.isEmpty ? .destructive : .secondary) {
                    hub.deny(request, message: note)
                }
                if canAlways {
                    ActionButton(title: "Всегда", disabled: !armed) { hub.allow(request, always: true) }
                        .help("Разрешить и запомнить: " + ClaudeCodeHub.describeSuggestions(suggestions))
                }
                ActionButton(title: "Разрешить", kind: .primary, disabled: !armed) { hub.allow(request) }
            }
        }
        .onChange(of: noteFocused) { _, f in model.isEditing = f }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { armed = true } }
        .onDisappear { model.isEditing = false }
    }
}

// MARK: - Question card

struct QuestionCard: View {
    @Environment(IslandModel.self) private var model
    let request: ClaudeCodeHub.Request
    let questions: [ClaudeCodeHub.Question]
    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var picked: [String] = []
    @State private var other = ""
    @FocusState private var otherFocused: Bool
    @State private var armed = false

    private var q: ClaudeCodeHub.Question { questions[min(index, questions.count - 1)] }
    private var isLast: Bool { index >= questions.count - 1 }

    var body: some View {
        let hub = model.claude
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(q.header.isEmpty ? "Вопрос" : q.header)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(claudeOrange)
                    .padding(.horizontal, 8).frame(height: 19)
                    .background(Capsule().fill(claudeOrange.opacity(0.16)))
                if questions.count > 1 {
                    Text("\(index + 1) из \(questions.count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
                if q.multiSelect {
                    Text("можно несколько")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                SessionTag(name: hub.sessions[request.sessionID]?.name ?? "Claude Code", extra: hub.requests.count - 1)
            }

            Text(q.text)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .id("q\(index)")
                .transition(.islandBlur)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, opt in
                    OptionButton(index: i + 1, option: opt, selected: picked.contains(opt.label), multi: q.multiSelect) {
                        if armed { tap(opt.label) }
                    }
                }
            }
            .id("o\(index)")
            .transition(.islandBlur)

            HStack(spacing: 7) {
                IslandTextField(placeholder: "Свой вариант…", text: $other, focused: $otherFocused) { commitCurrent() }
                IconPill(icon: "arrow.up.forward.app", help: "Ответить в приложении Claude") { hub.passToApp(request) }
                if q.multiSelect || !other.isEmpty {
                    ActionButton(title: isLast ? "Ответить" : "Далее", kind: .primary,
                                 disabled: !armed || (picked.isEmpty && other.trimmingCharacters(in: .whitespaces).isEmpty)) { commitCurrent() }
                }
            }
        }
        .onChange(of: otherFocused) { _, f in model.isEditing = f }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { armed = true } }
        .onDisappear { model.isEditing = false }
    }

    private func tap(_ label: String) {
        if q.multiSelect {
            withAnimation(.smooth(duration: 0.2)) {
                if let i = picked.firstIndex(of: label) { picked.remove(at: i) } else { picked.append(label) }
            }
        } else {
            record(label)
        }
    }

    private func commitCurrent() {
        var values = q.options.map(\.label).filter { picked.contains($0) }
        let o = other.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { values.append(o) }
        guard !values.isEmpty else { return }
        record(values.joined(separator: ","))
    }

    private func record(_ value: String) {
        answers[q.text] = value
        if isLast {
            model.claude.answer(request, answers: answers)
        } else {
            withAnimation(IslandModel.tabSpring) {
                index += 1
                picked = []
                other = ""
            }
        }
    }
}

struct OptionButton: View {
    let index: Int
    let option: ClaudeCodeHub.Question.Option
    let selected: Bool
    let multi: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    if multi {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(selected ? claudeOrange : .white.opacity(0.3), lineWidth: 1.5)
                            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? claudeOrange : .clear))
                        if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .black)).foregroundStyle(.white) }
                    } else {
                        Text("\(index)")
                            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(selected || hover ? .white : .white.opacity(0.5))
                    }
                }
                .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? claudeOrange.opacity(0.22) : .white.opacity(hover ? 0.12 : 0.065)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? claudeOrange.opacity(0.8) : .white.opacity(hover ? 0.12 : 0.05), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(IslandButtonStyle(circle: false))
        .help(option.detail)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - Sessions + message box

struct SessionsPanel: View {
    @Environment(IslandModel.self) private var model
    @State private var message = ""
    @State private var status: String?
    @FocusState private var focused: Bool

    var body: some View {
        let hub = model.claude
        let sessions = Array(hub.orderedSessions.prefix(2))
        let selected = hub.selectedSession

        VStack(alignment: .leading, spacing: 8) {
            ForEach(sessions) { s in
                SessionRow(session: s, selected: s.id == selected?.id)
                    .onTapGesture { withAnimation(.smooth(duration: 0.2)) { hub.selectedSessionID = s.id } }
                    .contextMenu { Button("Убрать из острова") { hub.dismiss(s.id) } }
            }
            if sessions.count == 1, let s = selected, let last = s.lastMessage, !last.isEmpty, s.state == .done {
                Text(last)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                IslandTextField(placeholder: placeholder(selected), text: $message, focused: $focused, height: 36) { send() }
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(message.isEmpty ? .white.opacity(0.1) : claudeOrange))
                        .contentShape(Circle())
                }
                .buttonStyle(IslandButtonStyle(circle: false))
                .disabled(message.isEmpty)
            }

            HStack(spacing: 6) {
                if let status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green.opacity(0.9))
                        .transition(.opacity)
                } else {
                    ReplyHint(session: selected)
                }
                Spacer()
                MiniLink(title: "Новая сессия", icon: "plus") { model.open(.newCode) }
                MiniLink(title: "Новый чат", icon: "bubble.left") { model.open(.newChat) }
                MiniLink(title: "Открыть", icon: "arrow.up.forward.app") { model.open(.needsInput) }
            }
            .font(.system(size: 10.5, weight: .medium))
        }
        .onChange(of: focused) { _, f in
            model.isEditing = f
            if f, let id = selected?.id { hub.extendReplyWindow(id) }
        }
        .onDisappear { model.isEditing = false }
        .onChange(of: message) { _, _ in
            if let id = selected?.id { hub.extendReplyWindow(id) }
        }
    }

    private func placeholder(_ s: ClaudeCodeHub.Session?) -> String {
        guard let s else { return "Сообщение для Claude…" }
        switch s.state {
        case .done: return model.claude.canReplyNow(s.id) ? "Ответить «\(s.name)»…" : "Новое задание для «\(s.name)»…"
        case .working: return "Подсказать Claude по ходу работы…"
        case .waiting: return "Ответить Claude…"
        case .idle: return "Сообщение для «\(s.name)»…"
        }
    }

    private func send() {
        let text = message
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        switch model.sendToClaudeCode(text) {
        case .continued: show("Отправлено — Claude продолжает")
        case .queued: show("Claude увидит это после текущего шага")
        case .notDelivered:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            model.open(.needsInput)
            show("Скопировано — вставьте в Claude (⌘V)")
        }
        message = ""
    }

    private func show(_ s: String) {
        withAnimation(.smooth(duration: 0.25)) { status = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.smooth(duration: 0.25)) { status = nil }
        }
    }
}

struct ReplyHint: View {
    @Environment(IslandModel.self) private var model
    let session: ClaudeCodeHub.Session?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let s = session, let deadline = model.claude.stopHoldDeadline[s.id], deadline > ctx.date {
                Label("Claude ждёт ответа ещё \(Int(deadline.timeIntervalSince(ctx.date)))с", systemImage: "hourglass")
                    .foregroundStyle(claudeOrange.opacity(0.9))
            } else if session?.state == .working {
                Label("⏎ — сообщение дойдёт на следующем шаге", systemImage: "paperplane")
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                Label("⌃⌥C — открыть отовсюду", systemImage: "keyboard")
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

struct MiniLink: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .foregroundStyle(.white.opacity(hover ? 0.9 : 0.45))
                .padding(.horizontal, 7).frame(height: 20)
                .background(Capsule().fill(.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SessionRow: View {
    let session: ClaudeCodeHub.Session
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Group {
                switch session.state {
                case .working: ClaudeSpark(size: 14, spinning: true)
                case .waiting:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
                        .symbolEffect(.pulse, options: .repeating)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .idle: Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.white.opacity(0.3))
                }
            }
            .font(.system(size: 14))
            .frame(width: 18)

            Text(session.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            Text(session.activity)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 6)
            if session.state == .working {
                Text(session.started, style: .timer)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(selected ? 0.08 : 0.0)))
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.3), value: session.activity)
    }
}
