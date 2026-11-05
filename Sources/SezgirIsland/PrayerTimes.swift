import AppKit
import Observation

/// Prayer times from the Spiritual Administration of Muslims of Kazakhstan (api.muftyat.kz).
/// A whole year is fetched per city and cached on disk, so it works offline.
@Observable
@MainActor
final class PrayerTimes {
    struct City: Codable, Equatable, Identifiable {
        let id: Int
        let title: String
        let lat: String
        let lng: String
        let timezone: String
        let region: String?
        var district: String? = nil
        var tz: TimeZone { TimeZone(secondsFromGMT: (Int(timezone) ?? 5) * 3600) ?? .current }
        var shortTitle: String {
            title.replacingOccurrences(of: " қаласы", with: "").replacingOccurrences(of: " (ст.)", with: "")
        }
        static let almaty = City(id: 72, title: "Алматы қаласы", lat: "43.238293", lng: "76.945465",
                                 timezone: "5", region: "Республикалық маңызы бар қалалар")
    }

    enum Prayer: String, CaseIterable, Identifiable {
        case fajr, sunrise, dhuhr, asr, maghrib, isha
        var id: String { rawValue }
        var name: String {
            switch self {
            case .fajr: "Фаджр"; case .sunrise: "Восход"; case .dhuhr: "Зухр"
            case .asr: "Аср"; case .maghrib: "Магриб"; case .isha: "Иша"
            }
        }
        var kazakh: String {
            switch self {
            case .fajr: "Таң"; case .sunrise: "Күн"; case .dhuhr: "Бесін"
            case .asr: "Екінті"; case .maghrib: "Ақшам"; case .isha: "Құптан"
            }
        }
        var icon: String {
            switch self {
            case .fajr: "sun.haze.fill"; case .sunrise: "sunrise.fill"; case .dhuhr: "sun.max.fill"
            case .asr: "sun.min.fill"; case .maghrib: "sunset.fill"; case .isha: "moon.stars.fill"
            }
        }
        /// Sunrise isn't a prayer: it only marks the end of Fajr.
        var isPrayer: Bool { self != .sunrise }
    }

    struct Entry: Identifiable {
        let prayer: Prayer
        let date: Date
        var id: Prayer { prayer }
    }

    private(set) var city: City
    private(set) var today: [Entry] = []
    private(set) var next: Entry?
    private(set) var current: Entry?
    private(set) var loading = false
    /// Updated every tick; read it instead of Date() so views and modes refresh with the clock.
    private(set) var now = Date()
    private(set) var error: String?
    var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "prayerSound") }
    }

    @ObservationIgnored var onPrayerTime: ((Entry) -> Void)?
    @ObservationIgnored var onSoon: ((Entry) -> Void)?
    @ObservationIgnored private var days: [String: [String: String]] = [:] // "yyyy-MM-dd" → raw times
    @ObservationIgnored private var loadedYears: Set<Int> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var announced: Set<String> = []

    init() {
        if let data = UserDefaults.standard.data(forKey: "prayerCity"),
           let c = try? JSONDecoder().decode(City.self, from: data) {
            city = c
        } else {
            city = .almaty
        }
        soundEnabled = UserDefaults.standard.object(forKey: "prayerSound") as? Bool ?? true
    }

    func start() {
        Task { await load() }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func select(_ c: City) {
        guard c != city else { return }
        city = c
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: "prayerCity") }
        days = [:]
        loadedYears = []
        today = []
        next = nil
        current = nil
        Task { await load() }
    }

    // MARK: Time keeping

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = city.tz
        return c
    }

    private func key(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = city.tz
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func entries(for day: Date) -> [Entry] {
        guard let raw = days[key(for: day)] else { return [] }
        let start = calendar.startOfDay(for: day)
        return Prayer.allCases.compactMap { p in
            guard let hm = raw[p.rawValue]?.split(separator: ":"), hm.count == 2,
                  let h = Int(hm[0]), let m = Int(hm[1]),
                  let d = calendar.date(bySettingHour: h, minute: m, second: 0, of: start) else { return nil }
            return Entry(prayer: p, date: d)
        }
    }

    func tick() {
        let now = Date()
        self.now = now
        let year = calendar.component(.year, from: now)
        if !loadedYears.contains(year) || (calendar.component(.month, from: now) == 12 && !loadedYears.contains(year + 1)) {
            Task { await load() }
        }
        let t = entries(for: now)
        today = t
        // After sunrise Fajr is over and nothing is "current" until Zuhr.
        current = t.last(where: { $0.date <= now }).flatMap { $0.prayer.isPrayer ? $0 : nil }
        let upcoming = t.first(where: { $0.date > now })
            ?? entries(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now).first
        next = upcoming

        guard let n = upcoming else { return }
        let left = n.date.timeIntervalSince(now)
        let id = "\(key(for: n.date))-\(n.prayer.rawValue)"
        if n.prayer.isPrayer, left <= 10 * 60, left > 9 * 60, !announced.contains(id + "-soon") {
            announced.insert(id + "-soon")
            onSoon?(n)
        }
        // Fire for a prayer that started within the last minute.
        if let c = t.last(where: { $0.date <= now }), now.timeIntervalSince(c.date) < 60, c.prayer.isPrayer {
            let cid = "\(key(for: c.date))-\(c.prayer.rawValue)"
            if !announced.contains(cid) {
                announced.insert(cid)
                if soundEnabled { NSSound(named: "Glass")?.play() }
                onPrayerTime?(c)
            }
        }
    }

    // MARK: Loading

    private var cacheDir: URL { HookServer.supportDir.appendingPathComponent("prayer", isDirectory: true) }

    func load() async {
        let now = Date()
        let year = calendar.component(.year, from: now)
        var years = [year]
        if calendar.component(.month, from: now) == 12 { years.append(year + 1) }
        loading = true
        defer { loading = false; tick() }
        for y in years where !loadedYears.contains(y) {
            let file = cacheDir.appendingPathComponent("\(city.id)-\(y).json")
            if let data = try? Data(contentsOf: file), ingest(data) {
                loadedYears.insert(y)
                continue
            }
            guard let url = URL(string: "https://api.muftyat.kz/prayer-times/\(y)/\(city.lat)/\(city.lng)") else { continue }
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200, ingest(data) else { throw URLError(.badServerResponse) }
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try? data.write(to: file)
                loadedYears.insert(y)
                error = nil
            } catch {
                if y == year { self.error = "Нет связи с muftyat.kz" }
            }
        }
    }

    private func ingest(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["result"] as? [[String: Any]], !list.isEmpty else { return false }
        for d in list {
            guard let date = d["Date"] as? String else { continue }
            days[date] = d.compactMapValues { $0 as? String }
        }
        return true
    }

    static func searchCities(_ query: String) async -> [City] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var found = await fetchCities([URLQueryItem(name: "search", value: q)])
        // muftyat.kz only knows Cyrillic names: "Almaty" → "алматы".
        if q.range(of: "[A-Za-z]", options: .regularExpression) != nil {
            let cyr = transliterate(q)
            for c in await fetchCities([URLQueryItem(name: "search", value: cyr)]) where !found.contains(c) {
                found.append(c)
            }
        }
        // Cities first, then the rest.
        return found.sorted { a, b in
            let ca = a.title.hasSuffix("қаласы"), cb = b.title.hasSuffix("қаласы")
            return ca != cb ? ca : false
        }
    }

    static func nearestCity(lat: Double, lng: Double) async -> City? {
        await fetchCities([URLQueryItem(name: "lat", value: String(lat)), URLQueryItem(name: "lng", value: String(lng))]).first
    }

    private static func fetchCities(_ items: [URLQueryItem]) async -> [City] {
        var c = URLComponents(string: "https://api.muftyat.kz/cities/")!
        c.queryItems = [URLQueryItem(name: "format", value: "json")] + items
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]],
              let json = try? JSONSerialization.data(withJSONObject: results) else { return [] }
        return (try? JSONDecoder().decode([City].self, from: json)) ?? []
    }

    static func transliterate(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("shch", "щ"), ("sh", "ш"), ("ch", "ч"), ("zh", "ж"), ("kh", "х"), ("ts", "ц"),
                       ("ya", "я"), ("yu", "ю"), ("yo", "ё"), ("ye", "е")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        let map: [Character: String] = [
            "a": "а", "b": "б", "c": "к", "d": "д", "e": "е", "f": "ф", "g": "г", "h": "х", "i": "и",
            "j": "ж", "k": "к", "l": "л", "m": "м", "n": "н", "o": "о", "p": "п", "q": "к", "r": "р",
            "s": "с", "t": "т", "u": "у", "v": "в", "w": "у", "x": "кс", "y": "ы", "z": "з",
        ]
        return String(t.flatMap { map[$0].map(Array.init) ?? [$0] })
    }

    // MARK: Formatting

    func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = city.tz
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    var hijriDate: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .islamicUmmAlQura)
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = city.tz
        f.dateFormat = "d MMMM y"
        return f.string(from: Date())
    }

    var gregorianDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = city.tz
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: Date()).capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// "2 ч 14 мин" / "14 мин" / "45 с"
func prayerCountdown(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s) с" }
    let h = s / 3600, m = (s % 3600) / 60
    return h > 0 ? "\(h) ч \(m) мин" : "\(m) мин"
}
