import Foundation

/// How Conch reads context use: Claude sessions start with `--settings=<settingsURL>`, whose statusLine runs a
/// wrapper script. Claude Code pipes its statusline JSON to the wrapper, which saves it as
/// `context/<CONCH_SESSION_ID>.json` for ContextMonitor, then runs the user's own statusLine command with the same
/// input so their statusline keeps working.
enum ContextStatusLine {
    /// Next to the state file, so a smoke test (CONCH_STATE_PATH) never touches the real app's files.
    static var supportDirectory: URL { Persistence.stateURL.deletingLastPathComponent() }
    static var contextDirectory: URL { supportDirectory.appendingPathComponent("context", isDirectory: true) }
    static var wrapperURL: URL { supportDirectory.appendingPathComponent("context-statusline.sh") }
    static var settingsURL: URL { supportDirectory.appendingPathComponent("context-settings.json") }

    private static let lock = NSLock()

    /// Writes the wrapper and the settings file when missing or out of date. False when they could not be
    /// written: claude refuses to start when the `--settings` file does not exist, so the caller leaves it out.
    static func install() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: contextDirectory, withIntermediateDirectories: true)
            try write(Data(wrapperScript().utf8), to: wrapperURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
            try write(settingsData(), to: settingsURL)
            return true
        } catch {
            NSLog("Conch: could not write the context statusline files: %@", error.localizedDescription)
            return false
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }

    /// The user's own statusLine options (padding, refreshInterval, hideVimModeIndicator) carry over, so only the
    /// command changes. Read again at every Claude launch, so an edit applies to the next session.
    private static func settingsData() throws -> Data {
        var statusLine = userStatusLine()
        statusLine["type"] = "command"
        statusLine["command"] = LaunchCommand.shellQuote(wrapperURL.path)
        return try JSONSerialization.data(withJSONObject: ["statusLine": statusLine],
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func userStatusLine() -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? ""
        let config = environment.isEmpty ? NSHomeDirectory() + "/.claude" : environment.expandingTilde
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: config).appendingPathComponent("settings.json")),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = settings["statusLine"] as? [String: Any] else { return [:] }
        return statusLine
    }

    /// The session id is checked before it becomes part of a path. The user's command is looked up where Claude
    /// Code would have found it (project local, project, then user settings), because `--settings` outranks all
    /// three, and the first file with the key wins. Project settings are read only under CLAUDE_PROJECT_DIR, which
    /// Claude Code 2.1 sets to the session's project root for statusline commands: the wrapper's own cwd follows
    /// `cd` in Bash tool calls, and a cloned repository's statusLine must never run. It runs several times a
    /// second while Claude streams, so it stays lean (Conch creates the folder). plutil ships with macOS, unlike jq.
    static func wrapperScript() -> String {
        let directory = LaunchCommand.shellQuote(contextDirectory.path)
        return """
        #!/bin/sh
        # Written by Conch. Claude Code runs this as the statusLine of sessions Conch starts: it saves the
        # statusline JSON for Conch's context meter, then runs your own statusLine command.
        input=$(cat)
        case "$CONCH_SESSION_ID" in
          ''|*[!0-9a-f-]*) ;;
          *)
            dir=\(directory)
            tmp="$dir/.$CONCH_SESSION_ID.$$"
            if printf '%s' "$input" 2>/dev/null > "$tmp"; then
              mv -f "$tmp" "$dir/$CONCH_SESSION_ID.json"
            else
              rm -f "$tmp"
            fi
            ;;
        esac
        set -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
        if [ -n "$CLAUDE_PROJECT_DIR" ]; then
          set -- "$CLAUDE_PROJECT_DIR/.claude/settings.local.json" "$CLAUDE_PROJECT_DIR/.claude/settings.json" "$@"
        fi
        for file in "$@"; do
          [ -f "$file" ] || continue
          command=$(/usr/bin/plutil -extract statusLine.command raw -o - "$file" 2>/dev/null) || continue
          case "$command" in ''|*context-statusline.sh*) exit 0 ;; esac
          printf '%s' "$input" | /bin/sh -c "$command"
          exit
        done
        exit 0

        """
    }
}
