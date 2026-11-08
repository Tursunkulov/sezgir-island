import AppKit
import SwiftUI
import Observation

/// Reads system-wide Now Playing (YouTube in a browser, Spotify, Music…)
/// through a tiny bridge loaded into /usr/bin/perl, and sends play/pause/next/seek back.
@Observable
@MainActor
final class NowPlaying {
    var title = ""
    var artist = ""
    var album = ""
    var bundleID: String?
    var isPlaying = false
    var duration: Double = 0
    var artwork: NSImage?
    var accent: Color = .white
    var appIcon: NSImage?

    fileprivate var baseElapsed: Double = 0
    fileprivate var rate: Double = 0
    fileprivate var timestamp = Date()

    @ObservationIgnored var onTrackChange: (() -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var receivedFirst = false
    @ObservationIgnored private var pendingToggleUntil: Date?
    @ObservationIgnored private var launchedAt = Date.distantPast
    @ObservationIgnored private var relaunchDelay: Double = 2

    var hasMedia: Bool { !title.isEmpty }

    func elapsed(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        var e = baseElapsed
        if isPlaying { e += date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1) }
        return min(max(0, e), duration)
    }

    // MARK: Commands

    func togglePlay() {
        freezeElapsed()
        withAnimation(.smooth(duration: 0.3)) { isPlaying.toggle() }
        pendingToggleUntil = Date().addingTimeInterval(0.8)
        send("toggle")
    }

    /// Pause (never start) whatever is playing — used before the Quran player starts.
    func pause() {
        guard isPlaying else { return }
        freezeElapsed()
        withAnimation(.smooth(duration: 0.3)) { isPlaying = false }
        pendingToggleUntil = Date().addingTimeInterval(0.8)
        send("pause")
    }

    func next() { send("next") }
    func previous() { send("prev") }

    func seek(to seconds: Double) {
        baseElapsed = seconds
        timestamp = Date()
        send("seek \(seconds)")
    }

    func openPlayerApp() {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func freezeElapsed() {
        baseElapsed = elapsed(at: Date())
        timestamp = Date()
    }

    private func send(_ command: String) {
        guard let data = (command + "\n").data(using: .utf8) else { return }
        try? input?.write(contentsOf: data)
    }

    // MARK: Bridge process

    func start() { launchBridge() }

    private func launchBridge() {
        guard let res = Bundle.main.resourceURL else { return }
        let script = res.appendingPathComponent("run.pl")
        let lib = res.appendingPathComponent("libbridge.dylib")
        guard FileManager.default.fileExists(atPath: lib.path) else {
            NSLog("SezgirIsland: libbridge.dylib missing — music disabled")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, lib.path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Back off if the bridge keeps dying right after start (2 s … 2 min).
                    let ranLong = Date().timeIntervalSince(self.launchedAt) > 30
                    self.relaunchDelay = ranLong ? 2 : min(self.relaunchDelay * 2, 120)
                    self.input = nil
                    self.buffer.removeAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.relaunchDelay) {
                        MainActor.assumeIsolated { self.launchBridge() }
                    }
                }
            }
        }
        do {
            launchedAt = Date()
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            NSLog("SezgirIsland: bridge failed: \(error)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        // A line with full-size artwork is at most a few MB; anything bigger is garbage.
        if buffer.count > 16 << 20 { buffer.removeAll(); return }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                apply(obj)
            }
        }
    }

    private func apply(_ o: [String: Any]) {
        // Our own Quran player publishes to Now Playing too; it has its own UI, so don't mirror it.
        var o = o
        if let b = o["bundle"] as? String, b == Bundle.main.bundleIdentifier { o = [:] }
        let newTitle = o["title"] as? String ?? ""
        let newArtist = o["artist"] as? String ?? ""
        let changed = newTitle != title || newArtist != artist
        let playingChanged = ((o["playing"] as? Bool) ?? false) != isPlaying
        if (changed || playingChanged || o["artwork"] != nil) && receivedFirst {
            withAnimation(.smooth(duration: 0.45)) { applyValues(o) }
        } else {
            applyValues(o)
        }
    }

    private func applyValues(_ o: [String: Any]) {
        let newTitle = o["title"] as? String ?? ""
        let newArtist = o["artist"] as? String ?? ""
        let changed = newTitle != title || newArtist != artist
        let newPlaying = (o["playing"] as? Bool) ?? false

        // Only assign what changed: every @Observable write redraws the views that read it,
        // and the bridge sends a heartbeat every 5 s.
        assign(\.title, newTitle)
        assign(\.artist, newArtist)
        assign(\.album, o["album"] as? String ?? "")
        assign(\.duration, finite(o["duration"]))
        assign(\.baseElapsed, finite(o["elapsed"]))
        assign(\.rate, finite(o["rate"]))
        let ts = finite(o["timestamp"])
        assign(\.timestamp, ts > 0 ? Date(timeIntervalSince1970: ts) : Date())

        // Ignore a stale "playing" value right after our own toggle.
        if let until = pendingToggleUntil, Date() < until, newPlaying != isPlaying {
            freezeElapsed()
        } else {
            pendingToggleUntil = nil
            assign(\.isPlaying, newPlaying)
        }

        let newBundle = o["bundle"] as? String
        if newBundle != bundleID {
            bundleID = newBundle
            appIcon = newBundle
                .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }

        if let b64 = o["artwork"] as? String, let data = Data(base64Encoded: b64), let img = NSImage.thumbnail(from: data) {
            artwork = img
            accent = Color(nsColor: img.islandAccent)
        } else if changed {
            artwork = nil
            accent = .white
        }

        if changed, receivedFirst, isPlaying, hasMedia { onTrackChange?() }
        receivedFirst = true
    }
}

extension NowPlaying {
    fileprivate func assign<T: Equatable>(_ kp: ReferenceWritableKeyPath<NowPlaying, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    fileprivate func finite(_ v: Any?) -> Double {
        guard let d = v as? Double, d.isFinite else { return 0 }
        return d
    }
}

private let accentContext = CIContext(options: [.workingColorSpace: NSNull()])

extension NSImage {
    /// Decode artwork downsampled to 256 px: Now Playing can hand us multi-megapixel images.
    static func thumbnail(from data: Data) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Average colour of the artwork, pushed bright and saturated enough to glow on black.
    var islandAccent: NSColor {
        guard let tiff = tiffRepresentation, let ci = CIImage(data: tiff),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent),
              ]),
              let output = filter.outputImage else { return .white }
        var px = [UInt8](repeating: 0, count: 4)
        accentContext.render(
            output, toBitmap: &px, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let base = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                           blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return NSColor(white: 0.92, alpha: 1) }
        return NSColor(hue: h, saturation: min(1, s * 1.35 + 0.1), brightness: max(0.82, b), alpha: 1)
    }
}
