import SwiftUI

struct MusicPanel: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        if model.media.hasMedia { player } else { empty }
    }

    private var player: some View {
        let media = model.media
        return HStack(spacing: 18) {
            Button { media.openPlayerApp() } label: {
                ArtworkView(image: media.artwork, size: 100, radius: 20)
                    .shadow(color: media.accent.opacity(0.45), radius: 24, y: 4)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = media.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 28, height: 28)
                                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                                .offset(x: 8, y: 8)
                        }
                    }
                    .scaleEffect(media.isPlaying ? 1 : 0.94)
                    .animation(.spring(duration: 0.5, bounce: 0.3), value: media.isPlaying)
            }
            .buttonStyle(IslandButtonStyle(circle: false))
            .help("Открыть плеер")

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(media.title)
                            .font(.system(size: 15, weight: .semibold))
                            .contentTransition(.opacity)
                            .foregroundStyle(.white)
                        Text(media.artist.isEmpty ? media.album : media.artist)
                            .font(.system(size: 12.5, weight: .medium))
                            .contentTransition(.opacity)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .lineLimit(1)
                    Spacer(minLength: 6)
                    AudioBars(color: media.accent, playing: media.isPlaying, height: 16)
                        .padding(.top, 2)
                }

                Spacer(minLength: 6)
                ProgressScrubber()
                Spacer(minLength: 4)

                HStack(spacing: 26) {
                    Spacer()
                    ControlButton(icon: "backward.fill", size: 17) { media.previous() }
                    ControlButton(icon: media.isPlaying ? "pause.fill" : "play.fill", size: 25) { media.togglePlay() }
                    ControlButton(icon: "forward.fill", size: 17) { media.next() }
                    Spacer()
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
            Text("Сейчас ничего не играет")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 8) {
                Chip(title: "Яндекс Музыка", icon: "music.note", tint: .yellow) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ru.yandex.desktop.music") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
                Chip(title: "YouTube", icon: "play.rectangle.fill", tint: .red) {
                    NSWorkspace.shared.open(URL(string: "https://www.youtube.com")!)
                }
            }
        }
    }
}

struct ControlButton: View {
    let icon: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: size * 1.9, height: size * 1.9)
                .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
    }
}

struct ProgressScrubber: View {
    @Environment(IslandModel.self) private var model
    @State private var dragValue: Double?
    @State private var hover = false

    var body: some View {
        let media = model.media
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !media.isPlaying || dragValue != nil)) { ctx in
            let duration = max(media.duration, 1)
            let current = dragValue ?? media.elapsed(at: ctx.date)
            let active = hover || dragValue != nil

            HStack(spacing: 10) {
                Text(format(current)).modifier(TimeLabel())
                GeometryReader { g in
                    let frac = CGFloat(min(max(current / duration, 0), 1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule()
                            .fill(LinearGradient(colors: [media.accent.opacity(0.75), media.accent],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(active ? 7 : 5, g.size.width * frac))
                            .shadow(color: media.accent.opacity(active ? 0.6 : 0.3), radius: 6)
                    }
                    .frame(height: active ? 7 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                dragValue = Double(min(max(v.location.x / max(g.size.width, 1), 0), 1)) * duration
                            }
                            .onEnded { _ in
                                if let d = dragValue { media.seek(to: d) }
                                dragValue = nil
                            }
                    )
                    .onHover { hover = $0 }
                }
                .frame(height: 16)
                Text("-" + format(max(0, duration - current))).modifier(TimeLabel())
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
        }
    }

    private func format(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}

private struct TimeLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
            .frame(minWidth: 34)
    }
}
