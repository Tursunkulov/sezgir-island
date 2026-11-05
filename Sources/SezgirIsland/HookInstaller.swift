import Foundation

/// Adds/removes Sezgir Island hooks in ~/.claude/settings.json.
/// Our entries are recognised by the script name, so the rest of the file is left untouched.
enum HookInstaller {
    // File names kept from the first version so existing installs keep working.
    static let marker = "dynamic-island-hook.sh"

    static var claudeDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude") }
    static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }
    static var scriptURL: URL { claudeDir.appendingPathComponent("hooks/\(marker)") }

    /// (event, curl max seconds, hook timeout seconds)
    private static let events: [(String, Int, Int)] = [
        ("SessionStart", 5, 10),
        ("UserPromptSubmit", 5, 10),
        ("PreToolUse", 600, 600),      // held only for AskUserQuestion
        ("PostToolUse", 5, 10),
        ("PermissionRequest", 600, 600),
        ("Notification", 5, 10),
        ("Stop", 600, 600),            // held a few seconds so you can reply
        ("SessionEnd", 2, 3),
    ]

    private static let script = """
    #!/bin/sh
    # Sezgir Island <-> Claude Code. Forwards the hook JSON to the island and prints its answer.
    # If the island is not running this is a silent no-op, and Claude Code behaves as usual.
    DIR="$HOME/Library/Application Support/DynamicIsland"
    [ -r "$DIR/token" ] || exit 0
    PORT=$(cat "$DIR/port" 2>/dev/null || echo 47823)
    curl -s -m "${1:-10}" -H "Expect:" -H "Content-Type: application/json" \\
      -H "X-Island-Token: $(cat "$DIR/token")" --data-binary @- "http://127.0.0.1:$PORT/hook" 2>/dev/null
    exit 0

    """

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL), let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains(marker) && FileManager.default.fileExists(atPath: scriptURL.path)
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var root = try readSettings()
        backupOnce()
        var hooks = stripOurs(root["hooks"] as? [String: Any] ?? [:])
        for (event, maxTime, timeout) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [[
                "type": "command",
                "command": "\(scriptURL.path) \(maxTime)",
                "timeout": timeout,
            ]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeSettings(root)
    }

    static func uninstall() throws {
        var root = try readSettings()
        let hooks = stripOurs(root["hooks"] as? [String: Any] ?? [:])
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeSettings(root)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private static func stripOurs(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            let kept: [[String: Any]] = groups.compactMap { g in
                var g = g
                let hs = (g["hooks"] as? [[String: Any]] ?? []).filter {
                    !(($0["command"] as? String) ?? "").contains(marker)
                }
                if hs.isEmpty { return nil }
                g["hooks"] = hs
                return g
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HookInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json is not an object"])
        }
        return obj
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func backupOnce() {
        let backup = claudeDir.appendingPathComponent("settings.json.before-dynamic-island")
        guard !FileManager.default.fileExists(atPath: backup.path),
              FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }
}
