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
    # Talks over a private Unix socket in ~/Library/Application Support (only you can reach it).
    # If the island is not running this is a silent no-op, and Claude Code behaves as usual.
    DIR="$HOME/Library/Application Support/DynamicIsland"
    [ -S "$DIR/hook.sock" ] && [ -r "$DIR/header" ] || exit 0
    curl -s -m "${1:-10}" --unix-socket "$DIR/hook.sock" -H "Expect:" -H "Content-Type: application/json" \\
      -H @"$DIR/header" --data-binary @- "http://localhost/hook" 2>/dev/null <&0 &
    PID=$!
    # If Claude Code stops waiting, stop curl too, so the island drops the card right away.
    trap 'kill $PID 2>/dev/null; exit 0' TERM INT HUP
    wait $PID
    exit 0

    """

    /// Bring an installed hook script up to date (older versions used a TCP port).
    static func refreshScriptIfInstalled() {
        guard isInstalled,
              (try? String(contentsOf: scriptURL, encoding: .utf8)) != script else { return }
        try? writeScript()
    }

    private static func writeScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: scriptURL)
        guard fm.createFile(atPath: scriptURL.path, contents: Data(script.utf8),
                            attributes: [.posixPermissions: 0o755]) else {
            throw NSError(domain: "HookInstaller", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot write \(scriptURL.path)"])
        }
    }

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL), let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains(marker) && FileManager.default.fileExists(atPath: scriptURL.path)
    }

    static func install() throws {
        var root = try readSettings()
        let existing = try hooksDict(root)
        try writeScript()
        backupOnce()
        var hooks = stripOurs(existing)
        for (event, maxTime, timeout) in events {
            guard hooks[event] == nil || hooks[event] is [[String: Any]] else {
                throw NSError(domain: "HookInstaller", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "settings.json: hooks.\(event) has an unexpected format; not touching it"])
            }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [[
                "type": "command",
                "command": "'\(scriptURL.path.replacingOccurrences(of: "'", with: "'\\''"))' \(maxTime)",
                "timeout": timeout,
            ]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeSettings(root)
    }

    static func uninstall() throws {
        var root = try readSettings()
        let hooks = stripOurs(try hooksDict(root))
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeSettings(root)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private static func stripOurs(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            let kept: [[String: Any]] = groups.compactMap { g in
                // Leave groups that never contained our hook exactly as they are.
                guard let hs = g["hooks"] as? [[String: Any]],
                      hs.contains(where: { (($0["command"] as? String) ?? "").contains(marker) }) else { return g }
                var g = g
                let rest = hs.filter { !(($0["command"] as? String) ?? "").contains(marker) }
                if rest.isEmpty { return nil }
                g["hooks"] = rest
                return g
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    private static func hooksDict(_ root: [String: Any]) throws -> [String: Any] {
        guard let h = root["hooks"] else { return [:] }
        guard let d = h as? [String: Any] else {
            throw NSError(domain: "HookInstaller", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "settings.json: \"hooks\" has an unexpected format; not touching it"])
        }
        return d
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
        // Write through a symlinked settings.json (dotfiles setups) and keep its permissions.
        let target = settingsURL.resolvingSymlinksInPath()
        let perms = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let perms { try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: target.path) }
    }

    private static func backupOnce() {
        let backup = claudeDir.appendingPathComponent("settings.json.before-dynamic-island")
        guard !FileManager.default.fileExists(atPath: backup.path),
              FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }
}
