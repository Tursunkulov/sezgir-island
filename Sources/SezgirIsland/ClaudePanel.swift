import SwiftUI

/// Claude tab: a pending permission/question first, then Claude Code sessions, otherwise quick ask.
struct ClaudePanel: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        let hub = model.claude
        ZStack {
            if let r = hub.requests.first {
                Group {
                    switch r.kind {
                    case .permission: PermissionCard(request: r)
                    case .question(let qs): QuestionCard(request: r, questions: qs)
                    }
                }
                .id(r.id)
                .transition(.islandBlur)
            } else if !hub.sessions.isEmpty {
                SessionsPanel().transition(.islandBlur)
            } else {
                VStack(spacing: 0) {
                    QuickAskPanel()
                    if let e = model.claudeHooksError {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.yellow.opacity(0.85))
                            .lineLimit(1)
                            .padding(.top, 4)
                    } else if !model.claudeHooksInstalled { ConnectClaudeCodeBanner() }
                }
                .transition(.islandBlur)
            }
        }
        .animation(IslandModel.tabSpring, value: hub.requests.first?.id)
        .animation(IslandModel.tabSpring, value: hub.sessions.isEmpty)
    }
}

struct QuickAskPanel: View {
    @Environment(IslandModel.self) private var model
    @FocusState private var focused: Bool

    private static let claudeIcon: NSImage? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    var body: some View {
        @Bindable var model = model
        let canSend = !model.claudeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Group {
                    if let icon = Self.claudeIcon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "sparkle").font(.system(size: 18, weight: .bold)).foregroundStyle(claudeOrange)
                    }
                }
                .frame(width: 34, height: 34)
                .shadow(color: claudeOrange.opacity(focused ? 0.55 : 0.25), radius: focused ? 14 : 8)

                TextField("", text: $model.claudeText,
                          prompt: Text("Спросите Claude о чём угодно…").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit { model.askClaude() }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(.white.opacity(focused ? 0.1 : 0.07)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(focused ? claudeOrange.opacity(0.75) : .white.opacity(0.08), lineWidth: 1))
                    .animation(.easeOut(duration: 0.18), value: focused)

                Button { model.askClaude() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? claudeOrange : .white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(IslandButtonStyle(circle: false))
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.2), value: canSend)
                .help("Отправить в Claude.app")
            }

            HStack(spacing: 6) {
                Chip(title: "Новый чат", icon: "plus.bubble.fill", tint: claudeOrange) { model.open(.newChat) }
                Chip(title: "Claude Code", icon: "chevron.left.forwardslash.chevron.right", tint: claudeOrange) { model.open(.newCode) }
                Chip(title: "Продолжить", icon: "arrow.uturn.forward", tint: claudeOrange) { model.open(.continueCode) }
                Chip(title: "Ждут ответа", icon: "bell.badge.fill", tint: claudeOrange) { model.open(.needsInput) }
                Chip(title: "Буфер", icon: "doc.on.clipboard", tint: .white.opacity(0.7)) { model.pasteClipboardIntoClaude() }
            }

            HStack {
                Label("⌃⌥C — открыть отовсюду", systemImage: "keyboard")
                Spacer()
                Text("⏎ откроет Claude.app с вопросом")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.32))
            .labelStyle(.titleAndIcon)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .onChange(of: focused) { _, f in model.isEditing = f }
        .onChange(of: model.claudeFocusToken) { _, _ in focused = true }
        .onAppear {
            // Focus only when ⌃⌥C / paste asked for it, not on every hover.
            if model.claudeFocusPending {
                model.claudeFocusPending = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
            }
        }
        .onDisappear { model.isEditing = false }
    }
}

/// Shown until Claude Code hooks are connected. Your click writes them into ~/.claude/settings.json.
struct ConnectClaudeCodeBanner: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            ClaudeSpark(size: 13, spinning: false)
            Text("Отвечать Claude Code прямо из острова")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 6)
            ActionButton(title: "Подключить Claude Code", kind: .primary) {
                withAnimation(IslandModel.tabSpring) { model.setClaudeHooks(true) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(claudeOrange.opacity(0.1)))
        .padding(.top, 6)
    }
}
