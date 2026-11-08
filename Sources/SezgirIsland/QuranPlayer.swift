import AppKit
import AVFoundation
import Combine
import MediaPlayer
import Observation
import SwiftUI

struct Surah: Identifiable, Hashable {
    let id: Int
    let name: String      // transliterated, e.g. "Al-Fatihah"
    let arabic: String
    let russian: String   // meaning, e.g. "Открывающая Коран"
    let verses: Int
    let meccan: Bool

    static func by(id: Int) -> Surah? { all.indices.contains(id - 1) ? all[id - 1] : nil }

    /// Loose match for Cyrillic or Latin queries ("ясин", "Yasin", "бакара", "36", "корова").
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if let n = Int(q) { return id == n }
        if russian.lowercased().contains(q.lowercased()) || arabic.contains(q) { return true }
        let key = Surah.skeleton(q)
        return !key.isEmpty && Surah.skeleton(name).contains(key)
    }

    /// Surahs matching the query, best first: exact name, then name prefix, then anywhere.
    static func search(_ query: String) -> [Surah] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        let key = skeleton(q)
        func rank(_ s: Surah) -> Int {
            let core = skeleton(s.bareName)
            if core == key { return 0 }
            if core.hasPrefix(key) { return 1 }
            if s.russian.lowercased().hasPrefix(q.lowercased()) { return 1 }
            return 2
        }
        return all.filter { $0.matches(q) }.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Name without the Arabic article: "Al-Kahf" → "Kahf", "Ash-Shams" → "Shams".
    var bareName: String {
        if let r = name.range(of: #"^[A-Z][a-z]{1,2}-"#, options: .regularExpression) { return String(name[r.upperBound...]) }
        return name
    }

    /// Reduce a name to a rough consonant-ish skeleton so that different transliterations meet.
    static func skeleton(_ s: String) -> String {
        let cyr: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "g", "ғ": "g", "д": "d", "е": "e", "ё": "e", "ж": "j", "з": "z",
            "и": "i", "й": "", "к": "k", "қ": "k", "л": "l", "м": "m", "н": "n", "ң": "n", "о": "o", "ө": "o",
            "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ұ": "u", "ү": "u", "ф": "f", "х": "h", "һ": "h",
            "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sh", "ы": "i", "э": "e", "ә": "a", "ю": "u", "я": "a",
            "і": "i", "ь": "", "ъ": "",
        ]
        var out = ""
        for ch in s.lowercased().folding(options: .diacriticInsensitive, locale: nil) {
            if let m = cyr[ch] { out += m } else if ch.isLetter, ch.isASCII { out.append(ch) }
        }
        for (a, b) in [("kh", "h"), ("sh", "s"), ("th", "s"), ("dh", "z"), ("gh", "g"), ("ts", "s"),
                       ("q", "k"), ("w", "u"), ("v", "u"), ("j", "dj"), ("y", ""), ("e", "i"), ("o", "u")] {
            out = out.replacingOccurrences(of: a, with: b)
        }
        out = out.replacingOccurrences(of: "h", with: "")
        // Collapse doubled letters ("an-naba" ~ "наба").
        var collapsed = ""
        for ch in out where collapsed.last != ch { collapsed.append(ch) }
        return collapsed
    }
}

struct Reciter: Identifiable, Hashable {
    let id: Int       // quran.com chapter reciter id
    let name: String
    let style: String?

    static let all: [Reciter] = [
        .init(id: 7, name: "Мишари Рашид аль-Афаси", style: nil),
        .init(id: 3, name: "Абдуррахман ас-Судайс", style: nil),
        .init(id: 10, name: "Сауд аш-Шурайм", style: nil),
        .init(id: 6, name: "Махмуд Халиль аль-Хусари", style: nil),
        .init(id: 9, name: "Мухаммад Сиддик аль-Миншави", style: nil),
        .init(id: 2, name: "Абдульбасит Абдуссамад", style: nil),
        .init(id: 1, name: "Абдульбасит Абдуссамад", style: "мудджаввад"),
        .init(id: 4, name: "Абу Бакр аш-Шатри", style: nil),
        .init(id: 97, name: "Ясир ад-Даусари", style: nil),
        .init(id: 5, name: "Хани ар-Рифаи", style: nil),
    ]
    static let `default` = all[0]

    var title: String { style.map { "\(name) (\($0))" } ?? name }
    var shortName: String { name.components(separatedBy: " ").suffix(style == nil ? 1 : 2).joined(separator: " ") }
}

/// Built-in Quran player: streams full-surah recitations from quran.com.
@Observable
@MainActor
final class QuranPlayer {
    private(set) var surah: Surah?
    private(set) var reciter: Reciter
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var duration: Double = 0
    var error: String?

    /// Called when the next surah starts on its own (for the compact "now playing" toast).
    @ObservationIgnored var onAutoAdvance: (() -> Void)?
    /// Called right before playback starts, so other audio can be paused.
    @ObservationIgnored var willPlay: (() -> Void)?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var bag = Set<AnyCancellable>()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var urlCache: [String: URL] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastSavedSecond = -1
    @ObservationIgnored private var pendingStart = false
    /// "reciter/surah" of the AVPlayerItem that is loaded right now.
    @ObservationIgnored private var itemKey: String?
    @ObservationIgnored private var itemBag = Set<AnyCancellable>()
    @ObservationIgnored private let defaults = UserDefaults.standard

    var lastSurah: Surah? { Surah.by(id: defaults.integer(forKey: "quranSurah")) }

    init() {
        let rid = defaults.object(forKey: "quranReciter") as? Int ?? Reciter.default.id
        reciter = Reciter.all.first { $0.id == rid } ?? .default
        player.automaticallyWaitsToMinimizeStalling = true

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.statusChanged(status) }
            }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                    self.finished()
                }
            }
            .store(in: &bag)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                      queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        setUpRemoteCommands()
    }

    // MARK: Playback

    var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    private func key(_ s: Surah, _ r: Reciter) -> String { "\(r.id)/\(s.id)" }

    /// The loaded AVPlayerItem really is the surah + reciter shown in the UI.
    private var itemMatches: Bool {
        guard let s = surah, player.currentItem != nil else { return false }
        return itemKey == key(s, reciter)
    }

    /// Resume the last surah where it stopped, or start from Al-Fatihah.
    func resume() {
        if itemMatches { play(); return }
        let s = surah ?? lastSurah ?? Surah.all[0]
        // Only reuse the saved spot if it belongs to this surah with this reciter.
        let pos = defaults.string(forKey: "quranPositionKey") == key(s, reciter)
            ? defaults.double(forKey: "quranPosition") : 0
        play(s, from: pos)
    }

    func play(_ s: Surah, from position: Double = 0) {
        willPlay?()
        // Stop the previous surah right away so it can't keep playing (or overwrite the saved spot).
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemKey = nil
        itemBag.removeAll()
        withAnimation(.smooth(duration: 0.35)) {
            surah = s
            error = nil
            isLoading = true
            duration = 0
        }
        pendingStart = true
        defaults.set(s.id, forKey: "quranSurah")
        loadTask?.cancel()
        let reciter = reciter
        loadTask = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool {
                guard !Task.isCancelled else { return false }
                return self.surah == s && self.reciter == reciter
            }
            do {
                let url = try await self.audioURL(surah: s.id, reciter: reciter.id)
                guard current() else { return }
                let item = AVPlayerItem(url: url)
                self.attach(item, key: self.key(s, reciter))
                if position > 1 {
                    await self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                }
                guard current() else { return }
                self.player.play()
                if let d = try? await item.asset.load(.duration), d.seconds.isFinite, d.seconds > 0,
                   self.player.currentItem === item {
                    self.duration = d.seconds
                    self.updateNowPlaying()
                }
            } catch {
                guard current() else { return }
                self.failed("Не удалось загрузить суру. Проверьте интернет.")
            }
        }
    }

    /// Load a surah without starting it (used for screenshots / demo).
    func cue(_ s: Surah) {
        surah = s
        let reciter = reciter
        Task { [weak self] in
            guard let self, let url = try? await self.audioURL(surah: s.id, reciter: reciter.id),
                  self.surah == s, self.reciter == reciter else { return }
            let item = AVPlayerItem(url: url)
            self.attach(item, key: self.key(s, reciter))
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite, self.player.currentItem === item {
                self.duration = d.seconds
            }
        }
    }

    func play() {
        guard itemMatches else { resume(); return }
        willPlay?()
        player.play()
    }

    func pause() {
        if pendingStart { loadTask?.cancel(); pendingStart = false; withAnimation { isLoading = false } }
        player.pause()
        saveProgress()
    }

    func toggle() {
        if isPlaying || isLoading { pause() } else { play() }
    }

    func next() {
        guard let s = surah, let n = Surah.by(id: s.id + 1) else { return }
        play(n)
    }

    /// Like a music player: restart the surah unless we are at its very beginning.
    func previous() {
        guard let s = surah else { return }
        if itemMatches, currentTime > 5 { seek(to: 0); return }
        if let p = Surah.by(id: s.id - 1) { play(p) } else { seek(to: 0) }
    }

    func seek(to seconds: Double) {
        guard itemMatches, seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func setReciter(_ r: Reciter) {
        guard r != reciter else { return }
        let wasActive = pendingStart || isPlaying || itemMatches
        reciter = r
        defaults.set(r.id, forKey: "quranReciter")
        // Recitations differ in length, so start the current surah over with the new voice.
        if let s = surah, wasActive { play(s) }
    }

    // MARK: Internals

    /// Hosts quran.com actually serves recitations from; anything else in the API reply is ignored.
    private static let audioHosts = ["quranicaudio.com", "quran.com", "qurancdn.com"]

    private func audioURL(surah: Int, reciter: Int) async throws -> URL {
        let key = "\(reciter)/\(surah)"
        if let u = urlCache[key] { return u }
        let api = URL(string: "https://api.quran.com/api/v4/chapter_recitations/\(reciter)/\(surah)")!
        let (data, response) = try await URLSession.shared.data(from: api)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = json["audio_file"] as? [String: Any],
              let s = file["audio_url"] as? String, let url = URL(string: s),
              url.scheme == "https", let host = url.host?.lowercased(),
              Self.audioHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw URLError(.badServerResponse)
        }
        urlCache[key] = url
        return url
    }

    /// Make `item` current and watch it for load / playback failures.
    private func attach(_ item: AVPlayerItem, key: String) {
        itemBag.removeAll()
        player.replaceCurrentItem(with: item)
        itemKey = key
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                MainActor.assumeIsolated {
                    guard let self, status == .failed, self.player.currentItem === item else { return }
                    self.failed("Не удалось воспроизвести суру.")
                }
            }
            .store(in: &itemBag)
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.failed("Воспроизведение прервалось. Проверьте интернет.") }
            }
            .store(in: &itemBag)
    }

    private func failed(_ message: String) {
        pendingStart = false
        player.pause()
        withAnimation { isLoading = false; isPlaying = false; error = message }
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        let playing = status == .playing
        if playing { pendingStart = false; if error != nil { error = nil } }
        let loading = !playing && (pendingStart || status == .waitingToPlayAtSpecifiedRate)
        if playing != isPlaying || loading != isLoading {
            withAnimation(.smooth(duration: 0.35)) {
                isPlaying = playing
                isLoading = loading
            }
        }
        if status == .paused { saveProgress() }
        updateNowPlaying()
    }

    private func tick(_ t: Double) {
        guard isPlaying, t.isFinite else { return }
        let sec = Int(t)
        if sec / 5 != lastSavedSecond / 5 { lastSavedSecond = sec; saveProgress() }
    }

    private func saveProgress() {
        guard itemMatches, !pendingStart, let s = surah else { return }
        defaults.set(currentTime, forKey: "quranPosition")
        defaults.set(key(s, reciter), forKey: "quranPositionKey")
    }

    private func finished() {
        guard let s = surah else { return }
        defaults.set(0.0, forKey: "quranPosition")
        if let n = Surah.by(id: s.id + 1) {
            play(n)
            onAutoAdvance?()
        } else {
            withAnimation { isPlaying = false }
        }
    }

    // MARK: System Now Playing (media keys, Control Center)

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }; return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }; return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }; return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }; return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let s = surah else { center.nowPlayingInfo = nil; return }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "\(s.id). \(s.name) — \(s.russian)",
            MPMediaItemPropertyArtist: reciter.title,
            MPMediaItemPropertyAlbumTitle: "Коран",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        center.playbackState = isPlaying ? .playing : .paused
    }
}
