import AppKit
import SwiftUI
import Observation
import ServiceManagement

enum IslandTab: Hashable { case music, claude, prayer }
enum Toast: Equatable { case charging, unplugged, lowBattery, track, claudeDone, prayerNow }
enum IslandMode: Equatable { case idle, music, claudeWorking, claudeAttention, prayerSoon, toast(Toast), expanded }

struct IslandLayout {
    var width: CGFloat       // body width (without top flares)
    var height: CGFloat
    var side: CGFloat        // width of each "ear" next to the camera in compact modes
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var frameWidth: CGFloat { width + topRadius * 2 }
}

enum ClaudeLink: String {
    case newChat = "claude://claude.ai/new"
    case newCode = "claude://code/new"
    case continueCode = "claude://code/continue?session=last"
    case needsInput = "claude://code/needs-input"
}

@Observable
@MainActor
final class IslandModel {
    static let windowSize = CGSize(width: 780, height: 360)
    static let openSpring = Animation.spring(duration: 0.52, bounce: 0.24)
    static let closeSpring = Animation.spring(duration: 0.46, bounce: 0.02)
    static let tabSpring = Animation.spring(duration: 0.4, bounce: 0.12)
    static let contentFade = Animation.smooth(duration: 0.38)

    var expanded = false
    var tab: IslandTab = .music
    var toast: Toast?
    var notch = CGSize(width: 190, height: 32)
    var screenHasNotch = true
    var claudeText = ""
    var isEditing = false
    var claudeFocusToken = 0
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    var claudeHooksInstalled = HookInstaller.isInstalled
    var lastDoneSession: ClaudeCodeHub.Session?

    let media = NowPlaying()
    let battery = BatteryMonitor()
    let claude = ClaudeCodeHub()
    let prayer = PrayerTimes()
    var prayerAlert: PrayerTimes.Entry?
    @ObservationIgnored private let hookServer = HookServer()

    @ObservationIgnored weak var panel: NotchPanel?
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var expandTask: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var demoLock = false

    // MARK: Derived state

    var mode: IslandMode {
        if expanded { return .expanded }
        if let toast { return .toast(toast) }
        if claude.hasRequests || claude.sessions.values.contains(where: { $0.state == .waiting }) { return .claudeAttention }
        if claude.isWorking { return .claudeWorking }
        if let n = prayer.next, n.prayer.isPrayer, n.date.timeIntervalSinceNow < 10 * 60 { return .prayerSoon }
        if media.hasMedia && media.isPlaying { return .music }
        return .idle
    }

    var isPinned: Bool {
        demoLock || isEditing || (tab == .claude && (!claudeText.isEmpty || claude.hasRequests))
    }

    /// Height of the panel under the notch row; grows for Claude cards.
    var expandedContentHeight: CGFloat {
        guard tab == .claude else { return tab == .prayer ? 168 : 152 }
        if let r = claude.requests.first {
            if case .question(let qs) = r.kind {
                let opts = qs.first?.options.count ?? 2
                return opts > 2 ? 232 : 182
            }
            return 200
        }
        if claude.sessions.isEmpty { return claudeHooksInstalled ? 152 : 200 }
        return 190
    }

    var layout: IslandLayout {
        let w = notch.width, h = notch.height
        switch mode {
        case .idle:
            return .init(width: w, height: h, side: 0, topRadius: 6, bottomRadius: 10)
        case .music, .claudeWorking:
            let s = h + 10
            return .init(width: w + s * 2, height: h, side: s, topRadius: 8, bottomRadius: 13)
        case .prayerSoon, .toast(.prayerNow):
            let s: CGFloat = 120
            return .init(width: w + s * 2, height: h, side: s, topRadius: 8, bottomRadius: 13)
        case .claudeAttention:
            let s: CGFloat = 118
            return .init(width: w + s * 2, height: h, side: s, topRadius: 8, bottomRadius: 13)
        case .toast(.claudeDone):
            let s: CGFloat = 140
            return .init(width: w + s * 2, height: h, side: s, topRadius: 8, bottomRadius: 13)
        case .toast(.track):
            let s: CGFloat = 150
            return .init(width: w + s * 2, height: h, side: s, topRadius: 8, bottomRadius: 13)
        case .toast:
            let s: CGFloat = 104
            return .init(width: w + s * 2, height: h, side: s, topRadius: 8, bottomRadius: 13)
        case .expanded:
            return .init(width: max(w + 520, 720), height: h + expandedContentHeight, side: 0, topRadius: 16, bottomRadius: 34)
        }
    }

    // MARK: Lifecycle

    func start() {
        configureScreen()
        media.onTrackChange = { [weak self] in self?.showToast(.track, for: 3.2) }
        battery.onEvent = { [weak self] event in
            switch event {
            case .pluggedIn: self?.showToast(.charging, for: 3)
            case .unplugged: self?.showToast(.unplugged, for: 2.5)
            case .low: self?.showToast(.lowBattery, for: 4)
            }
        }
        media.start()
        battery.start()
        startClaudeCode()
        prayer.onPrayerTime = { [weak self] e in
            self?.prayerAlert = e
            self?.showToast(.prayerNow, for: 60)
        }
        prayer.start()
        installMonitors()
        applyDemoIfRequested()
        enableLoginItemOnFirstInstall()
    }

    func configureScreen() {
        let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
        screen = s
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notch = CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
            screenHasNotch = true
        } else {
            notch = CGSize(width: 190, height: max(24, s.frame.maxY - s.visibleFrame.maxY))
            screenHasNotch = false
        }
        let ws = Self.windowSize
        panel?.setFrame(NSRect(x: s.frame.midX - ws.width / 2, y: s.frame.maxY - ws.height,
                               width: ws.width, height: ws.height), display: true)
    }

    // MARK: Geometry & mouse

    private var islandRect: CGRect {
        guard let s = screen else { return .zero }
        let l = layout
        return CGRect(x: s.frame.midX - l.frameWidth / 2, y: s.frame.maxY - l.height,
                      width: l.frameWidth, height: l.height)
    }

    private var notchRect: CGRect {
        guard let s = screen else { return .zero }
        return CGRect(x: s.frame.midX - notch.width / 2, y: s.frame.maxY - notch.height,
                      width: notch.width, height: notch.height)
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { // Esc
                MainActor.assumeIsolated { self?.collapse(restoreFocus: true) }
                return nil
            }
            // ⌘1 / ⌘2 / ⌘3 — switch tabs
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               let n = Int(e.charactersIgnoringModifiers ?? ""), (1...IslandTab.allCases.count).contains(n) {
                MainActor.assumeIsolated { self?.select(tab: IslandTab.allCases[n - 1]) }
                return nil
            }
            return e
        }) { monitors.append(m) }
        // Two-finger horizontal swipe over the open island — previous / next tab.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handleSwipe(e) }
            return e
        }) { monitors.append(m) }
    }

    func select(tab t: IslandTab) {
        guard t != tab else { return }
        withAnimation(Self.tabSpring) { tab = t }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    @ObservationIgnored private var swipeAccumulated: CGFloat = 0
    @ObservationIgnored private var swipeLocked = false

    private func handleSwipe(_ e: NSEvent) {
        guard expanded, e.hasPreciseScrollingDeltas else { return }
        if e.phase == .began || e.phase == .mayBegin { swipeAccumulated = 0; swipeLocked = false }
        if e.phase == .ended || e.phase == .cancelled { swipeAccumulated = 0; swipeLocked = false; return }
        guard !swipeLocked, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.5 else { return }
        swipeAccumulated += e.scrollingDeltaX
        guard abs(swipeAccumulated) > 50 else { return }
        let tabs = IslandTab.allCases
        let i = tabs.firstIndex(of: tab) ?? 0
        // Fingers to the left → next tab (like paging).
        let j = swipeAccumulated < 0 ? min(i + 1, tabs.count - 1) : max(i - 1, 0)
        swipeLocked = true
        swipeAccumulated = 0
        select(tab: tabs[j])
    }

    func mouseMoved() {
        let p = NSEvent.mouseLocation
        let rect = islandRect
        panel?.ignoresMouseEvents = !rect.insetBy(dx: -1, dy: -1).contains(p)
        let hot = expanded ? rect.insetBy(dx: -14, dy: -14) : rect.union(notchRect).insetBy(dx: -8, dy: -6)

        if hot.contains(p) {
            collapseTask?.cancel(); collapseTask = nil
            if !expanded && expandTask == nil {
                expandTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, let self else { return }
                    self.expandTask = nil
                    self.expand()
                }
            }
        } else {
            expandTask?.cancel(); expandTask = nil
            if expanded && !isPinned && collapseTask == nil {
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, let self else { return }
                    self.collapseTask = nil
                    self.collapse(restoreFocus: false)
                }
            }
        }
    }

    private func clickedOutside() {
        guard expanded, !demoLock, !islandRect.contains(NSEvent.mouseLocation) else { return }
        collapse(restoreFocus: false)
    }

    // MARK: Transitions

    func expand(tab: IslandTab? = nil) {
        if let tab, tab != self.tab {
            withAnimation(Self.tabSpring) { self.tab = tab }
        }
        guard !expanded else { return }
        toastTask?.cancel()
        withAnimation(Self.openSpring) {
            expanded = true
            toast = nil
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        refreshMouseState()
    }

    func collapse(restoreFocus: Bool) {
        guard expanded, !demoLock else { return }
        expandTask?.cancel(); expandTask = nil
        collapseTask?.cancel(); collapseTask = nil
        withAnimation(Self.closeSpring) { expanded = false }
        isEditing = false
        if panel?.isKeyWindow == true {
            if restoreFocus { NSWorkspace.shared.frontmostApplication?.activate() }
            panel?.resignKey()
        }
        refreshMouseState()
    }

    private func refreshMouseState() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
    }

    func showToast(_ t: Toast, for seconds: Double) {
        guard !expanded else { return }
        toastTask?.cancel()
        withAnimation(Self.openSpring) { toast = t }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            withAnimation(Self.closeSpring) { if self.toast == t { self.toast = nil } }
        }
    }

    // MARK: Claude

    func toggleClaude() {
        if expanded && tab == .claude {
            collapse(restoreFocus: true)
            return
        }
        expand(tab: .claude)
        panel?.makeKey()
        claudeFocusToken += 1
    }

    func askClaude() {
        let text = claudeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let q = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "claude://claude.ai/new?q=\(q)") else { return }
        claudeText = ""
        collapse(restoreFocus: false)
        NSWorkspace.shared.open(url)
    }

    func open(_ link: ClaudeLink) {
        guard let url = URL(string: link.rawValue) else { return }
        collapse(restoreFocus: false)
        NSWorkspace.shared.open(url)
    }

    func pasteClipboardIntoClaude() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return }
        claudeText = claudeText.isEmpty ? s : claudeText + " " + s
        panel?.makeKey()
        claudeFocusToken += 1
    }

    // MARK: Claude Code

    private func startClaudeCode() {
        hookServer.handler = { [weak self] body, reply in
            guard let self else { return }
            if UserDefaults.standard.bool(forKey: "debugHooks"), let action = body["debug_action"] as? String {
                self.debugAction(action)
                reply.send(["ok": true])
                return
            }
            self.claude.handle(body, reply: reply)
        }
        hookServer.start()
        claude.onAttention = { [weak self] in
            guard let self else { return }
            self.toast = nil
            self.expand(tab: .claude)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        claude.onDone = { [weak self] session in
            guard let self else { return }
            self.lastDoneSession = session
            self.claude.selectedSessionID = session.id
            if !self.expanded { self.showToast(.claudeDone, for: ClaudeCodeHub.replyWindow) }
        }
        claude.onRequestsCleared = { [weak self] in
            guard let self, self.expanded else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated {
                    if !self.islandRect.contains(NSEvent.mouseLocation) && !self.claude.hasRequests {
                        self.isEditing = false
                        self.collapse(restoreFocus: true)
                    }
                }
            }
        }
    }

    /// Test-only: drive the first pending card without clicking (launch with `-debugHooks YES`).
    private func debugAction(_ a: String) {
        guard let r = claude.requests.first else {
            if a.hasPrefix("send:") { _ = sendToClaudeCode(String(a.dropFirst(5))) }
            return
        }
        switch a {
        case "allow": claude.allow(r)
        case "always": claude.allow(r, always: true)
        case "deny": claude.deny(r, message: nil)
        case "app": claude.passToApp(r)
        default:
            if a.hasPrefix("deny:") { claude.deny(r, message: String(a.dropFirst(5))) }
            if a.hasPrefix("answer:"), case .question(let qs) = r.kind, let q = qs.first {
                claude.answer(r, answers: [q.text: String(a.dropFirst(7))])
            }
        }
    }

    func setClaudeHooks(_ on: Bool) {
        do { on ? try HookInstaller.install() : try HookInstaller.uninstall() }
        catch { NSLog("SezgirIsland: hooks \(on ? "install" : "uninstall") failed: \(error)") }
        claudeHooksInstalled = HookInstaller.isInstalled
    }

    /// Message box in the Claude tab: goes to the selected Claude Code session if there is one.
    func sendToClaudeCode(_ text: String) -> ClaudeCodeHub.SendResult {
        guard let s = claude.selectedSession else { return .notDelivered }
        let r = claude.send(text, to: s.id)
        if r == .continued { collapseSoon() }
        return r
    }

    private func collapseSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.isEditing = false; self?.collapse(restoreFocus: true) }
        }
    }

    // MARK: Settings

    /// First run from /Applications: turn on launch at login once. The right-click menu can turn it off.
    private func enableLoginItemOnFirstInstall() {
        let key = "didSetUpLoginItem"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled { setLaunchAtLogin(true) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SezgirIsland: launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Demo (for screenshots): `SezgirIsland -demo music|claude|charging|track|compact`

    private func applyDemoIfRequested() {
        guard let demo = UserDefaults.standard.string(forKey: "demo") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch demo {
                case "music": self.expand(tab: .music); self.demoLock = true
                case "claude": self.expand(tab: .claude); self.demoLock = true
                case "charging": self.showToast(.charging, for: 3600)
                case "track": self.showToast(.track, for: 3600)
                case "done": self.showToast(.claudeDone, for: 3600)
                case "prayer": self.expand(tab: .prayer); self.demoLock = true
                case "citysearch": self.expand(tab: .prayer); self.demoLock = true
                case "prayernow": self.prayerAlert = self.prayer.today.first(where: { $0.prayer == .asr }); self.showToast(.prayerNow, for: 3600)
                default: break
                }
            }
        }
    }
}
