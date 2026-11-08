import SwiftUI

struct MusicPanel: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        ZStack {
            if model.surahPickerOpen {
                SurahPicker().transition(.islandBlur)
            } else {
                switch model.playerSource {
                case .quran: QuranPlayerView().transition(.islandBlur)
                case .system: player.transition(.islandBlur)
                case nil: empty.transition(.islandBlur)
                }
            }
        }
        .animation(IslandModel.tabSpring, value: model.surahPickerOpen)
        .animation(IslandModel.tabSpring, value: model.playerSource)
    }

    private var player: some View {
        let media = model.media
        return HStack(spacing: 16) {
            Button { media.openPlayerApp() } label: {
                ArtworkView(image: media.artwork, size: 84, radius: 17)
                    .shadow(color: media.accent.opacity(0.45), radius: 20, y: 4)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = media.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                                .offset(x: 7, y: 7)
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
                            .font(.system(size: 14, weight: .semibold))
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
                    SmallIconButton(icon: "book.closed.fill", help: "Коран") {
                        withAnimation(IslandModel.tabSpring) { model.playerPick = .quran }
                        if model.quran.surah == nil { model.surahPickerOpen = true }
                    }
                }

                Spacer(minLength: 6)
                ProgressScrubber(accent: media.accent, duration: media.duration, playing: media.isPlaying,
                                 elapsed: { media.elapsed(at: $0) }, seek: { media.seek(to: $0) })
                Spacer(minLength: 4)

                HStack(spacing: 22) {
                    Spacer()
                    ControlButton(icon: "backward.fill", size: 15) { media.previous() }
                    ControlButton(icon: media.isPlaying ? "pause.fill" : "play.fill", size: 22) { media.togglePlay() }
                    ControlButton(icon: "forward.fill", size: 15) { media.next() }
                    Spacer()
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
            Text("Сейчас ничего не играет")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 8) {
                Chip(title: "Коран", icon: "book.closed.fill", tint: prayerGreen) {
                    model.quran.resume()
                }
                Chip(title: "Выбрать суру", icon: "list.bullet", tint: prayerGreen) {
                    model.surahPickerOpen = true
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
                .frame(width: size * 1.8, height: size * 1.8)
                .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
    }
}

struct ProgressScrubber: View {
    let accent: Color
    let duration: Double
    let playing: Bool
    let elapsed: (Date) -> Double
    let seek: (Double) -> Void
    @State private var dragValue: Double?
    @State private var hover = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 4, paused: !playing || dragValue != nil)) { ctx in
            let duration = max(self.duration, 1)
            let current = min(dragValue ?? elapsed(ctx.date), duration)
            let active = hover || dragValue != nil

            HStack(spacing: 10) {
                Text(format(current)).modifier(TimeLabel())
                GeometryReader { g in
                    let frac = CGFloat(min(max(current / duration, 0), 1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule()
                            .fill(LinearGradient(colors: [accent.opacity(0.75), accent],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(active ? 7 : 5, g.size.width * frac))
                            .shadow(color: accent.opacity(active ? 0.6 : 0.3), radius: 6)
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
                                if let d = dragValue { seek(d) }
                                dragValue = nil
                            }
                    )
                    .onHover { hover = $0 }
                }
                .frame(height: 16)
                Text(self.duration > 0 ? "-" + format(max(0, duration - current)) : "--:--").modifier(TimeLabel())
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
