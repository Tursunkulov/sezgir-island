import SwiftUI

let prayerGreen = Color(red: 0.38, green: 0.84, blue: 0.64)

struct PrayerPanel: View {
    @Environment(IslandModel.self) private var model
    @State private var searching = UserDefaults.standard.string(forKey: "demo") == "citysearch"

    var body: some View {
        ZStack {
            if searching {
                CitySearch { searching = false }.transition(.islandBlur)
            } else {
                PrayerDay { withAnimation(IslandModel.tabSpring) { searching = true } }.transition(.islandBlur)
            }
        }
        .animation(IslandModel.tabSpring, value: searching)
    }
}

private struct PrayerDay: View {
    @Environment(IslandModel.self) private var model
    let onCity: () -> Void

    var body: some View {
        let p = model.prayer
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onCity) {
                    HStack(spacing: 5) {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(prayerGreen)
                        Text(p.city.shortTitle).foregroundStyle(.white)
                        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(.white.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .buttonStyle(IslandButtonStyle(circle: false))
                .help("Выбрать город")

                Spacer()
                Text("\(p.gregorianDate) · \(p.hijriDate)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            if p.today.isEmpty {
                VStack(spacing: 6) {
                    if p.loading { ProgressView().controlSize(.small) }
                    Text(p.error ?? "Загружаю время намаза…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 6) {
                    ForEach(p.today) { e in
                        PrayerTile(entry: e,
                                   isCurrent: p.current?.prayer == e.prayer && p.current?.date == e.date,
                                   isNext: p.next?.prayer == e.prayer && p.next?.date == e.date,
                                   isPast: e.date < Date() && p.current?.prayer != e.prayer)
                    }
                }

                HStack(spacing: 7) {
                    if let n = p.next {
                        Image(systemName: n.prayer.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(prayerGreen)
                        Text(n.prayer.isPrayer ? "До \(n.prayer.name)" : "До восхода")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        TimelineView(CountdownSchedule(target: n.date)) { ctx in
                            Text(prayerCountdown(n.date.timeIntervalSince(ctx.date)))
                                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(prayerGreen)
                                .contentTransition(.numericText(countsDown: true))
                                .animation(.smooth(duration: 0.3), value: Int(n.date.timeIntervalSince(ctx.date)) / 60)
                        }
                    }
                    Spacer()
                    Text("Муфтият РК")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                    Button {
                        p.soundEnabled.toggle()
                    } label: {
                        Image(systemName: p.soundEnabled ? "bell.fill" : "bell.slash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(p.soundEnabled ? prayerGreen : .white.opacity(0.4))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(IslandButtonStyle())
                    .help(p.soundEnabled ? "Звук во время намаза включён" : "Звук выключен")
                }
            }
        }
    }
}

private struct PrayerTile: View {
    let entry: PrayerTimes.Entry
    let isCurrent: Bool
    let isNext: Bool
    let isPast: Bool
    @Environment(IslandModel.self) private var model

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: entry.prayer.icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isCurrent || isNext ? prayerGreen : .white.opacity(0.5))
                .symbolRenderingMode(.hierarchical)
            Text(entry.prayer.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(model.prayer.timeString(entry.date))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Text(entry.prayer.kazakh)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isCurrent ? prayerGreen.opacity(0.17) : .white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isCurrent ? prayerGreen.opacity(0.7) : isNext ? prayerGreen.opacity(0.3) : .clear, lineWidth: 1))
        .opacity(isPast ? 0.45 : 1)
    }
}

private struct CitySearch: View {
    @Environment(IslandModel.self) private var model
    let onDone: () -> Void
    @State private var query = ""
    @State private var results: [PrayerTimes.City] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var locating = false
    @State private var locateError: String?
    @State private var finder = LocationFinder()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                IslandTextField(placeholder: "Город или посёлок — по-русски, по-казахски или латиницей",
                                text: $query, focused: $focused) {
                    if let first = results.first { pick(first) }
                }
                IconPill(icon: "xmark", help: "Закрыть", action: onDone)
            }

            ScrollView {
                VStack(spacing: 5) {
                    LocateRow(locating: locating, error: locateError, action: locate)
                    if searching && results.isEmpty {
                        HStack { ProgressView().controlSize(.small); Spacer() }.padding(.leading, 10).frame(height: 26)
                    } else if query.count >= 2 && results.isEmpty {
                        Text("Ничего не нашлось. Попробуйте начало названия, например «Каскел»")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 10).frame(height: 26)
                    }
                    ForEach(results.prefix(12)) { c in
                        CityRow(city: c, selected: c.id == model.prayer.city.id) { pick(c) }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .onAppear {
            model.panel?.makeKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
        }
        .onDisappear { model.isEditing = false }
        .onChange(of: focused) { _, f in model.isEditing = f || locating }
        .onChange(of: query) { _, q in
            searchTask?.cancel()
            guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { results = []; searching = false; return }
            searching = true
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                let r = await PrayerTimes.searchCities(q)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.2)) { results = r; searching = false }
            }
        }
    }

    private func locate() {
        locateError = nil
        locating = true
        model.isEditing = true // keep the island open while the permission prompt is up
        Task {
            defer { locating = false; model.isEditing = focused }
            do {
                let loc = try await finder.locate()
                if let c = await PrayerTimes.nearestCity(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude) {
                    pick(c)
                } else {
                    locateError = "Рядом нет пунктов из базы Муфтията"
                }
            } catch LocationFinder.Failure.denied {
                locateError = "denied"
            } catch {
                locateError = error.localizedDescription
            }
        }
    }

    private func pick(_ c: PrayerTimes.City) {
        model.prayer.select(c)
        model.isEditing = false
        onDone()
    }
}

private struct LocateRow: View {
    let locating: Bool
    let error: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 7) {
                    if locating {
                        ProgressView().controlSize(.small).frame(width: 16)
                    } else {
                        Image(systemName: "location.fill").foregroundStyle(prayerGreen).frame(width: 16)
                    }
                    Text(locating ? "Определяю…" : "Определить автоматически")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(prayerGreen.opacity(0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle(circle: false))
            .disabled(locating)
        }
        if let error {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                if error == "denied" {
                    Text("Нет доступа к геолокации.")
                    Button("Открыть настройки") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(prayerGreen)
                } else {
                    Text(error)
                }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.leading, 10)
        }
    }
}

private struct CityRow: View {
    let city: PrayerTimes.City
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "mappin")
                    .foregroundStyle(prayerGreen)
                    .frame(width: 16)
                Text(city.shortTitle).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Text([city.district, city.region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                Spacer()
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hover ? 0.11 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(circle: false))
        .onHover { hover = $0 }
    }
}

// MARK: - Compact

struct PrayerSoonCompact: View {
    @Environment(IslandModel.self) private var model
    let side: CGFloat
    var now = false

    var body: some View {
        let entry = now ? model.prayerAlert : model.prayer.next
        CompactRow(side: side) {
            HStack(spacing: 7) {
                Image(systemName: entry?.prayer.icon ?? "moon.stars.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(prayerGreen)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.pulse, options: .repeating, isActive: now)
                Text(entry?.prayer.name ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, 10)
        } right: {
            Group {
                if now, let e = entry {
                    Text("сейчас · " + model.prayer.timeString(e.date))
                        .foregroundStyle(prayerGreen)
                } else if let e = entry {
                    TimelineView(CountdownSchedule(target: e.date)) { ctx in
                        let left = e.date.timeIntervalSince(ctx.date)
                        Text(left < 3600 ? "через " + prayerCountdown(left) : "в " + model.prayer.timeString(e.date))
                            .foregroundStyle(left < 600 ? prayerGreen : prayerGreen.opacity(0.75))
                            .contentTransition(.numericText(countsDown: true))
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .padding(.trailing, 11)
        }
    }
}

/// Redraw a countdown once a minute (on the minute — prayer times are whole minutes),
/// and every second only during the last minute. Saves CPU in the always-visible pill.
struct CountdownSchedule: TimelineSchedule {
    let target: Date

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var t = start
        return AnyIterator {
            let cur = t
            if target.timeIntervalSince(cur) > 61 {
                let next = Calendar.current.nextDate(after: cur, matching: DateComponents(second: 0),
                                                     matchingPolicy: .nextTime) ?? cur.addingTimeInterval(60)
                t = min(next, target.addingTimeInterval(-61))
                if t <= cur { t = cur.addingTimeInterval(1) }
            } else {
                t = cur.addingTimeInterval(1)
            }
            return cur
        }
    }
}
