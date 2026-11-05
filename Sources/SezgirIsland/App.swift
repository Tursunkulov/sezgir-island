import AppKit
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        migrateOldDefaults()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    var panel: NotchPanel?
    var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = NotchPanel(model: model)
        self.panel = panel
        model.panel = panel
        model.start()
        panel.orderFrontRegardless()

        // ⌃⌥C — open the Claude tab from anywhere
        hotKey = HotKey(keyCode: 8 /* kVK_ANSI_C */, modifiers: [.control, .option]) { [weak self] in
            self?.model.toggleClaude()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.configureScreen() }
        }
    }
}

/// The app used to be "Dynamic Island" (com.muhammad.dynamicisland): bring its settings over once.
private func migrateOldDefaults() {
    let d = UserDefaults.standard
    guard !d.bool(forKey: "migratedFromDynamicIsland"),
          let old = UserDefaults(suiteName: "com.muhammad.dynamicisland") else { return }
    d.set(true, forKey: "migratedFromDynamicIsland")
    for key in ["prayerCity", "prayerSound"] {
        if d.object(forKey: key) == nil, let v = old.object(forKey: key) { d.set(v, forKey: key) }
    }
}
