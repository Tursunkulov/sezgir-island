import AppKit
import SwiftUI

let quranGold = Color(red: 0.93, green: 0.80, blue: 0.52)

// MARK: - Player

struct QuranPlayerView: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        let q = model.quran
        let s = q.surah ?? q.lastSurah ?? Surah.all[0]
        HStack(spacing: 16) {
            Button { model.surahPickerOpen = true } label: {
                SurahArt(surah: s, size: 84)
                    .shadow(color: prayerGreen.opacity(q.isPlaying ? 0.4 : 0.2), radius: 20, y: 4)
                    .scaleEffect(q.isPlaying ? 1 : 0.94)
                    .animation(.spring(duration: 0.5, bounce: 0.3), value: q.isPlaying)
            }
            .buttonStyle(IslandButtonStyle(circle: false))
            .help("Выбрать суру")

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(s.id). \(s.name)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.opacity)
                        ReciterMenu()
                    }
                    .lineLimit(1)
                    Spacer(minLength: 6)
                    if let e = q.error {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.yellow)
                            .help(e)
                            .padding(.top, 2)
                    } else {
                        AudioBars(color: prayerGreen, playing: q.isPlaying, height: 16)
                            .padding(.top, 2)
                    }
                    SmallIconButton(icon: "list.bullet", help: "Список сур") { model.surahPickerOpen = true }
                    if model.media.hasMedia {
                        SmallIconButton(icon: "play.rectangle.fill", help: "Вернуться к \(model.media.title.isEmpty ? "плееру" : model.media.title)") {
                            withAnimation(IslandModel.tabSpring) { model.playerPick = .system }
                        }
                    }
                }

                Spacer(minLength: 6)
                ProgressScrubber(accent: prayerGreen, duration: q.duration, playing: q.isPlaying,
                                 elapsed: { _ in q.currentTime }, seek: { q.seek(to: $0) })
                Spacer(minLength: 4)

                HStack(spacing: 22) {
                    Spacer()
                    ControlButton(icon: "backward.fill", size: 15) { q.previous() }
                        .disabled(q.surah == nil)
                    ZStack {
                        ControlButton(icon: q.isPlaying || q.isLoading ? "pause.fill" : "play.fill", size: 22) {
                            if q.surah == nil { q.resume() } else { q.toggle() }
                        }
                        if q.isLoading {
                            ProgressView().controlSize(.small).allowsHitTesting(false).offset(y: 22)
                        }
                    }
                    ControlButton(icon: "forward.fill", size: 15) {
                        if q.surah == nil { q.play(Surah.by(id: s.id + 1) ?? s) } else { q.next() }
                    }
                    Spacer()
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// "Cover" for a surah: Arabic name on a deep green tile with a thin gold frame.
struct SurahArt: View {
    let surah: Surah
    let size: CGFloat

    var body: some View {
        let r = size * 0.21
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.33, blue: 0.27),
                                              Color(red: 0.02, green: 0.15, blue: 0.13)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: r * 0.7, style: .continuous)
                .strokeBorder(quranGold.opacity(0.35), lineWidth: max(0.5, size / 120))
                .padding(size * 0.07)
            if size > 40 {
                VStack(spacing: size * 0.02) {
                    Text(surah.arabic)
                        .font(.custom("Geeza Pro", size: size * 0.24).weight(.bold))
                        .foregroundStyle(quranGold)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, size * 0.12)
                    Text("\(surah.id)")
                        .font(.system(size: size * 0.12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
            } else {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(quranGold)
            }
        }
        .frame(width: size, height: size)
        .id(surah.id)
        .transition(.opacity)
    }
}

/// Reciter name that opens a native menu of reciters.
/// (A SwiftUI `Menu` restyles its label, so we pop an NSMenu ourselves.)
private struct ReciterMenu: View {
    @Environment(IslandModel.self) private var model
    @State private var hover = false

    var body: some View {
        let q = model.quran
        Button(action: showMenu) {
            HStack(spacing: 4) {
                Text(q.reciter.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(hover ? 0.85 : 0.55))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Выбрать чтеца")
        .onHover { hover = $0 }
    }

    private func showMenu() {
        let q = model.quran
        let menu = NSMenu()
        let header = NSMenuItem(title: "Чтец", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for r in Reciter.all {
            let item = MenuClosureItem(title: r.title) { q.setReciter(r) }
            item.state = r == q.reciter ? .on : .off
            menu.addItem(item)
        }
        // Keep the island open while the menu is up.
        let wasEditing = model.isEditing
        model.isEditing = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        model.isEditing = wasEditing
    }
}

final class MenuClosureItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

struct SmallIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 0.9 : 0.6))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hover ? 0.14 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .help(help)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - Surah picker

struct SurahPicker: View {
    @Environment(IslandModel.self) private var model
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [Surah] { Surah.search(query) }

    var body: some View {
        let current = model.quran.surah?.id ?? model.quran.lastSurah?.id
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                IslandTextField(placeholder: "Сура: название, перевод или номер — «Ясин», «Корова», 67",
                                text: $query, focused: $focused, height: 30) {
                    if let first = results.first { pick(first) }
                }
                IconPill(icon: "xmark", help: "Закрыть") { close() }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { s in
                            SurahRow(surah: s, current: s.id == current,
                                     playing: s.id == model.quran.surah?.id && model.quran.isPlaying) { pick(s) }
                                .id(s.id)
                        }
                        if results.isEmpty {
                            Text("Ничего не нашлось")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 10).frame(height: 26)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onAppear {
                    if let current { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
        .onAppear {
            model.panel?.makeKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
        }
        .onDisappear { model.isEditing = false }
        .onChange(of: focused) { _, f in model.isEditing = f && !query.isEmpty }
        .onChange(of: query) { _, q in model.isEditing = focused && !q.isEmpty }
        .onExitCommand { close() }
    }

    private func pick(_ s: Surah) {
        model.quran.play(s)
        withAnimation(IslandModel.tabSpring) {
            model.playerPick = .quran
            model.surahPickerOpen = false
        }
    }

    private func close() {
        withAnimation(IslandModel.tabSpring) { model.surahPickerOpen = false }
    }
}

private struct SurahRow: View {
    let surah: Surah
    let current: Bool
    let playing: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if playing {
                        AudioBars(color: prayerGreen, playing: true, height: 10)
                    } else {
                        Text("\(surah.id)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(current ? prayerGreen : .white.opacity(0.4))
                    }
                }
                .frame(width: 24)
                Text(surah.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(surah.russian)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 6)
                Text("\(surah.verses) аят\(ayatSuffix(surah.verses))")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
                Text(surah.arabic)
                    .font(.custom("Geeza Pro", size: 13).weight(.semibold))
                    .foregroundStyle(quranGold.opacity(0.85))
            }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(current ? prayerGreen.opacity(0.14) : .white.opacity(hover ? 0.11 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(circle: false))
        .onHover { hover = $0 }
    }

    private func ayatSuffix(_ n: Int) -> String {
        let d = n % 10, h = n % 100
        if d == 1 && h != 11 { return "" }
        if (2...4).contains(d) && !(12...14).contains(h) { return "а" }
        return "ов"
    }
}
