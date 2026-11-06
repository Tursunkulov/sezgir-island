import SwiftUI

let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)

struct IslandRootView: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        let l = model.layout
        let shape = NotchShape(topRadius: l.topRadius, bottomRadius: l.bottomRadius)

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(model.expanded ? 0.55 : 0), radius: 16, y: 8)

            content(l)
                .padding(.horizontal, l.topRadius)
                .frame(width: l.frameWidth, height: l.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: l.frameWidth, height: l.height)
        .opacity(model.mode == .idle && !model.screenHasNotch ? 0 : 1)
        .animation(model.expanded ? IslandModel.openSpring : IslandModel.closeSpring, value: model.mode)
        .contextMenu {
            Toggle("Claude Code в острове", isOn: Binding(
                get: { model.claudeHooksInstalled },
                set: { model.setClaudeHooks($0) }))
            Toggle("Намаз всегда у выреза", isOn: Binding(
                get: { model.prayerAlwaysVisible },
                set: { v in withAnimation(IslandModel.openSpring) { model.prayerAlwaysVisible = v } }))
            Toggle("Запускать при входе", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
            Divider()
            Button("Выйти из Sezgir Island") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(_ l: IslandLayout) -> some View {
        switch model.mode {
        case .idle:
            Color.clear
        case .music:
            CompactMusic(side: l.side).transition(.islandCompact)
        case .claudeWorking:
            ClaudeWorkingCompact(side: l.side).transition(.islandCompact)
        case .claudeAttention:
            ClaudeAttentionCompact(side: l.side).transition(.islandCompact)
        case .prayerSoon, .prayerIdle:
            PrayerSoonCompact(side: l.side).transition(.islandCompact)
        case .toast(.prayerNow):
            PrayerSoonCompact(side: l.side, now: true).transition(.islandCompact)
        case .toast(.claudeDone):
            ClaudeDoneToast(side: l.side).transition(.islandCompact)
        case .toast(.track):
            TrackToast(side: l.side).transition(.islandCompact)
        case .toast(let kind):
            BatteryToast(kind: kind, side: l.side).transition(.islandCompact)
        case .expanded:
            ExpandedIsland()
                .transition(.asymmetric(
                    insertion: .islandOpen.animation(.spring(response: 0.42, dampingFraction: 0.82).delay(0.05)),
                    removal: .islandOpen.animation(.easeIn(duration: 0.14))))
        }
    }
}

// MARK: - Transitions

struct BlurFade: ViewModifier {
    var amount: Double
    var scale: Double = 0.06
    var lift: Double = 0
    func body(content: Content) -> some View {
        content
            .blur(radius: 8 * amount)
            .opacity(1 - amount)
            .scaleEffect(1 - scale * amount, anchor: .top)
            .offset(y: -lift * amount)
    }
}

extension AnyTransition {
    static var islandBlur: AnyTransition {
        .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
    }

    /// Expanded content grows out of the camera: starts smaller, blurred and tucked up under the notch.
    static var islandOpen: AnyTransition {
        .modifier(active: BlurFade(amount: 1, scale: 0.18, lift: 10),
                  identity: BlurFade(amount: 0, scale: 0.18, lift: 10))
    }

    /// Ears next to the camera: fade in a beat after the shape starts growing, leave quickly.
    static var islandCompact: AnyTransition {
        .asymmetric(
            insertion: islandBlur.animation(.smooth(duration: 0.32).delay(0.08)),
            removal: islandBlur.animation(.easeIn(duration: 0.12)))
    }
}

// MARK: - Compact (live activity) layouts

struct CompactRow<Left: View, Right: View>: View {
    @Environment(IslandModel.self) private var model
    let side: CGFloat
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: side, height: model.notch.height, alignment: .leading)
            Spacer(minLength: model.notch.width)
            right.frame(width: side, height: model.notch.height, alignment: .trailing)
        }
        .frame(height: model.notch.height)
    }
}

struct CompactMusic: View {
    @Environment(IslandModel.self) private var model
    let side: CGFloat

    var body: some View {
        let h = model.notch.height
        CompactRow(side: side) {
            ArtworkView(image: model.media.artwork, size: h - 10, radius: 6)
                .padding(.leading, 9)
        } right: {
            AudioBars(color: model.media.accent, playing: model.media.isPlaying, height: 13)
                .padding(.trailing, 11)
        }
    }
}

struct TrackToast: View {
    @Environment(IslandModel.self) private var model
    let side: CGFloat

    var body: some View {
        let h = model.notch.height
        CompactRow(side: side) {
            HStack(spacing: 8) {
                ArtworkView(image: model.media.artwork, size: h - 10, radius: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.media.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Сейчас играет")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .lineLimit(1)
            }
            .padding(.leading, 9)
        } right: {
            HStack(spacing: 8) {
                Text(model.media.artist)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                AudioBars(color: model.media.accent, playing: model.media.isPlaying, height: 13)
            }
            .padding(.trailing, 11)
        }
    }
}

struct BatteryToast: View {
    @Environment(IslandModel.self) private var model
    let kind: Toast
    let side: CGFloat

    private var tint: Color {
        switch kind {
        case .charging: .green
        case .lowBattery: .red
        default: .white
        }
    }

    private var label: String {
        switch kind {
        case .charging: "Зарядка"
        case .lowBattery: "Мало заряда"
        default: "От батареи"
        }
    }

    private var icon: String {
        switch kind {
        case .charging: "bolt.fill"
        case .lowBattery: "exclamationmark.triangle.fill"
        default: "powerplug.portrait"
        }
    }

    var body: some View {
        let b = model.battery
        CompactRow(side: side) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: kind == .charging)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, 11)
        } right: {
            HStack(spacing: 6) {
                Text("\(b.level)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                BatteryGlyph(level: b.level, charging: kind == .charging || b.isCharging, plugged: b.isPluggedIn)
            }
            .padding(.trailing, 11)
        }
    }
}

// MARK: - Expanded

struct ExpandedIsland: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        // Room to the left of the camera for the tab bar.
        let earWidth = max(0, (model.layout.width - model.notch.width) / 2 - 18)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TabSwitcher()
                    .frame(width: earWidth, alignment: .leading)
                Spacer(minLength: model.notch.width + 8)
                BatteryBadge()
            }
            .padding(.horizontal, 14)
            .frame(height: model.notch.height)

            ZStack {
                switch model.tab {
                case .music: MusicPanel().transition(.islandBlur)
                case .claude: ClaudePanel().transition(.islandBlur)
                case .prayer: PrayerPanel().transition(.islandBlur)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }
}

/// Segmented tab bar: icon + label when there's room, big icon-only buttons otherwise.
/// Also switchable with ⌘1 / ⌘2 / ⌘3 and a two-finger horizontal swipe.
struct TabSwitcher: View {
    @Environment(IslandModel.self) private var model
    @Namespace private var ns

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(labels: true)
            bar(labels: false)
        }
    }

    private func bar(labels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(IslandTab.allCases, id: \.self) { t in
                TabButton(tab: t, selected: model.tab == t, showLabel: labels, ns: ns) {
                    model.select(tab: t)
                }
            }
        }
        .padding(2.5)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.05), lineWidth: 1))
        .fixedSize()
    }
}

private struct TabButton: View {
    @Environment(IslandModel.self) private var model
    let tab: IslandTab
    let selected: Bool
    let showLabel: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon
                    .frame(width: 14, height: 14)
                if showLabel {
                    Text(tab.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(selected ? .white : .white.opacity(hover ? 0.85 : 0.55))
            .padding(.horizontal, showLabel ? 9 : 0)
            .frame(minWidth: showLabel ? 0 : 34)
            .frame(height: 25)
            .background {
                if selected {
                    Capsule().fill(.white.opacity(0.16))
                        .matchedGeometryEffect(id: "tab", in: ns)
                } else if hover {
                    Capsule().fill(.white.opacity(0.07))
                }
            }
            .overlay(alignment: .topTrailing) { badge }
            .contentShape(Capsule())
        }
        .buttonStyle(IslandButtonStyle(circle: false))
        .help("\(tab.title)  ⌘\(tab.number)")
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    @ViewBuilder private var icon: some View {
        switch tab {
        case .music:
            if model.media.isPlaying && model.media.hasMedia {
                AudioBars(color: selected ? model.media.accent : .white.opacity(0.7), playing: true, height: 11)
            } else {
                Image(systemName: "music.note").font(.system(size: 12, weight: .bold))
            }
        case .claude:
            ClaudeSpark(size: 12.5, spinning: model.claude.isWorking,
                        color: selected || model.claude.isWorking || model.claude.hasRequests ? claudeOrange : .white.opacity(hover ? 0.85 : 0.55))
        case .prayer:
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(selected ? prayerGreen : .white.opacity(hover ? 0.85 : 0.55))
                .symbolRenderingMode(.hierarchical)
        }
    }

    @ViewBuilder private var badge: some View {
        if tab == .claude && model.claude.hasRequests && !selected {
            Circle().fill(claudeOrange)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                .offset(x: 1, y: -1)
                .transition(.scale)
        } else if tab == .prayer && !selected, let n = model.prayer.next, n.prayer.isPrayer,
                  n.date.timeIntervalSinceNow < 30 * 60 {
            Circle().fill(prayerGreen)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                .offset(x: 1, y: -1)
                .transition(.scale)
        }
    }
}

extension IslandTab: CaseIterable {
    static var allCases: [IslandTab] { [.music, .claude, .prayer] }
    var title: String {
        switch self {
        case .music: "Музыка"
        case .claude: "Claude"
        case .prayer: "Намаз"
        }
    }
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

struct BatteryBadge: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        let b = model.battery
        if b.hasBattery {
            HStack(spacing: 6) {
                Text("\(b.level)%")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                BatteryGlyph(level: b.level, charging: b.isCharging, plugged: b.isPluggedIn)
            }
        } else {
            Text(Date(), style: .time)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: - Shared pieces

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity.combined(with: .scale(1.06)))
            } else {
                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct AudioBars: View {
    let color: Color
    let playing: Bool
    let height: CGFloat

    private let speeds: [Double] = [6.1, 8.3, 5.2, 7.4]
    private let phases: [Double] = [0, 1.7, 3.1, 4.4]

    var body: some View {
        // One Canvas draw per frame instead of laying out four views.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, sz in
                let w: CGFloat = 2.8, gap: CGFloat = 2.2
                for i in 0..<4 {
                    let wave = abs(sin(t * speeds[i] + phases[i])) * 0.6 + abs(sin(t * speeds[i] * 0.37 + phases[i])) * 0.4
                    let v = playing ? 0.25 + 0.75 * wave : 0.2
                    let h = max(w, sz.height * v)
                    let r = CGRect(x: CGFloat(i) * (w + gap), y: (sz.height - h) / 2, width: w, height: h)
                    g.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(color))
                }
            }
        }
        .frame(width: 4 * 2.8 + 3 * 2.2, height: height)
    }
}

struct BatteryGlyph: View {
    let level: Int
    let charging: Bool
    let plugged: Bool

    private var fill: Color {
        if charging || plugged { return .green }
        if level <= 20 { return .red }
        return .white
    }

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.6, style: .continuous)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .fill(fill)
                    .frame(width: max(2, 20 * CGFloat(min(max(level, 0), 100)) / 100))
                    .padding(2)
            }
            .frame(width: 25, height: 12)
            .overlay {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7.5, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.4))
                .frame(width: 1.6, height: 4.5)
        }
    }
}

struct IslandButtonStyle: ButtonStyle {
    var circle = true

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, circle: circle)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let circle: Bool
        @State private var hover = false

        var body: some View {
            configuration.label
                .background {
                    if circle {
                        Circle().fill(.white.opacity(hover ? 0.11 : 0))
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.86 : 1)
                .brightness(hover && !circle ? 0.08 : 0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hover)
                .onHover { hover = $0 }
        }
    }
}

struct Chip: View {
    let title: String
    let icon: String
    var tint: Color = .white
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(.white.opacity(hover ? 0.14 : 0.07)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(IslandButtonStyle(circle: false))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}
