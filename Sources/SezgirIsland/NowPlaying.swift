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

    private var baseElapsed: Double = 0
    private var rate: Double = 0
    private var timestamp = Date()

    @ObservationIgnored var onTrackChange: (() -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var receivedFirst = false
    @ObservationIgnored private var pendingToggleUntil: Date?

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { self?.launchBridge() }
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            NSLog("SezgirIsland: bridge failed: \(error)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
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

        title = newTitle
        artist = newArtist
        album = o["album"] as? String ?? ""
        duration = o["duration"] as? Double ?? 0
        baseElapsed = o["elapsed"] as? Double ?? 0
        rate = o["rate"] as? Double ?? 0
        if let ts = o["timestamp"] as? Double {
            timestamp = Date(timeIntervalSince1970: ts)
        } else {
            timestamp = Date()
        }

        // Ignore a stale "playing" value right after our own toggle.
        if let until = pendingToggleUntil, Date() < until, newPlaying != isPlaying {
            freezeElapsed()
        } else {
            pendingToggleUntil = nil
            isPlaying = newPlaying
        }

        let newBundle = o["bundle"] as? String
        if newBundle != bundleID {
            bundleID = newBundle
            appIcon = newBundle
                .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }

        if let b64 = o["artwork"] as? String, let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
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

extension NSImage {
    /// Average colour of the artwork, pushed bright and saturated enough to glow on black.
    var islandAccent: NSColor {
        guard let tiff = tiffRepresentation, let ci = CIImage(data: tiff),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent),
              ]),
              let output = filter.outputImage else { return .white }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
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
