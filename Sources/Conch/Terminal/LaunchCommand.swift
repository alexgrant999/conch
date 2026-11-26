import Foundation

// Owner: core agent. Pure functions, no UI.

struct LaunchPlan: Equatable {
    var executable: String
    var args: [String]
    var environment: [String]
    var currentDirectory: String
    /// Optional text fed into the terminal display (not the pty) before the process starts, for example a note
    /// that a restored web session cannot be re-created.
    var banner: String?
}

enum LaunchCommand {
    /// The user's login shell from the password database, falling back to $SHELL, then /bin/zsh.
    static func userShell() -> String {
        let fileManager = FileManager.default
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty, fileManager.isExecutableFile(atPath: shell) { return shell }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty,
           fileManager.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    /// The agent CLI argv for a session (claude, or codex, see `codexArgv`), or nil for `.shell`.
    /// Rules:
    /// - `.claude`, no transcript yet: `claude --session-id <uuid>` then `--remote-control=<name>` when enabled,
    ///   then `--model=<model>` when set, then extraArgs.
    /// - `.claude`, the transcript exists (a restore, or resuming a conversation started elsewhere):
    ///   `claude --resume <uuid>` (plus remote control and extraArgs).
    /// - `.cloud` with an attach target (`isCloudAttachTarget`): `claude --cloud=<target>`, new or restoring.
    /// - `.cloud` with a description, new: `claude --cloud=<description>`.
    /// Optional values are attached with "=": as a separate argv entry, a name or task starting with "-" would be
    /// parsed as an unknown option and claude would refuse to start.
    /// - `.cloud` with a description, restoring: nil (do not create a duplicate web session), see `plan`.
    static func claudeArgv(for spec: LaunchSpec, displayName: String, restoring: Bool) -> [String]? {
        let options = spec.claude ?? ClaudeOptions()
        switch spec.kind {
        case .shell:
            return nil
        case .claude:
            // Claude Code names transcripts with the lowercase form, so always pass that.
            let id = options.sessionID.uuidString.lowercased()
            var argv = ["claude"]
            let resuming = transcriptExists(sessionID: options.sessionID, cwd: spec.cwd)
            if resuming {
                argv += ["--resume", id]
            } else {
                argv += ["--session-id", id]
            }
            argv += worktreeArguments(for: spec, resuming: resuming)
            if options.remoteControl {
                argv.append("--remote-control=\(displayName)")
            }
            argv += contextArguments(for: spec)
            argv += modelArguments(for: options)
            argv += options.extraArgs
            if !resuming {
                argv += initialPromptArguments(for: options)
            }
            return argv
        case .cloud:
            let target = (options.cloudTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if restoring, !isCloudAttachTarget(target) { return nil }
            return ["claude", target.isEmpty ? "--cloud" : "--cloud=\(target)"] + options.extraArgs
        case .codex:
            return codexArgv(for: spec)
        }
    }

    /// Full plan for spawning a session.
    /// - `.shell`: `<shell> -l` in `startDirectory`. With a startup command: `<shell> -l -i -c '<command>
    ///   exec <shell> -l'` (a newline between them) in `spec.cwd`.
    /// - Claude kinds: `<shell> -l -i -c '<quoted claude argv>; exec <shell> -l'` in `spec.cwd`, so the user lands
    ///   in a shell when Claude exits.
    /// - `.cloud` description on restore: plain shell plus a banner saying the web session is at claude.ai/code.
    /// Environment: the app's environment minus CLAUDECODE and CLAUDE_CODE_* variables, plus TERM=xterm-256color,
    /// COLORTERM=truecolor, TERM_PROGRAM=Conch, TERM_PROGRAM_VERSION, LANG (en_US.UTF-8 when unset), CONCH_SESSION_ID.
    static func plan(for spec: LaunchSpec, sessionID: UUID, displayName: String, startDirectory: String, restoring: Bool) -> LaunchPlan {
        let shell = userShell()
        let argv = claudeArgv(for: spec, displayName: displayName, restoring: restoring)

        var banner: String?
        if spec.kind == .cloud, argv == nil {
            let task = (spec.claude?.cloudTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            banner = cloudRestoreBanner(task: task)
        }

        let startup = spec.kind == .shell ? spec.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        // A startup command runs in spec.cwd, not where the shell was last left: the command may cd itself
        // (`cd web && npm run dev`), and starting in web would break that cd on the next launch.
        let directory = existingDirectory(worktreeDirectory(for: spec)
            ?? (argv == nil && startup.isEmpty ? startDirectory : spec.cwd))
        let args: [String]
        if let argv {
            let command = argv.map(shellQuote).joined(separator: " ")
            args = ["-l", "-i", "-c", "\(command); exec \(shellQuote(shell)) -l"]
        } else if !startup.isEmpty {
            // Like a Claude session: the command runs in the login shell, then the pane drops into a plain shell.
            // A newline, not "; ", so a trailing comment cannot swallow the exec and a trailing "&" stays valid.
            args = ["-l", "-i", "-c", "\(startup)\nexec \(shellQuote(shell)) -l"]
        } else {
            args = ["-l"]
        }

        return LaunchPlan(executable: shell,
                          args: args,
                          environment: environment(sessionID: sessionID, directory: directory),
                          currentDirectory: directory,
                          banner: banner)
    }

    /// True for `session_...` ids and `https://claude.ai/code...` URLs.
    static func isCloudAttachTarget(_ target: String) -> Bool {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }

        let sessionPrefix = "session_"
        if value.hasPrefix(sessionPrefix) {
            let rest = value.dropFirst(sessionPrefix.count)
            return !rest.isEmpty && rest.unicodeScalars.allSatisfy(isIdentifierScalar)
        }

        guard let url = URLComponents(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "claude.ai" || host == "www.claude.ai" else { return false }
        return url.path == "/code" || url.path.hasPrefix("/code/")
    }

    /// True when Claude Code has a transcript for this session id under ~/.claude/projects/<encoded cwd>/<uuid>.jsonl.
    /// The encoded cwd replaces every character that is not [A-Za-z0-9] with "-".
    static func transcriptExists(sessionID: UUID, cwd: String) -> Bool {
        transcriptURL(sessionID: sessionID, cwd: cwd) != nil
    }

    /// An existing Claude Code conversation named in `text`, either a bare session id or a pasted
    /// `claude --resume <id>`: its id and the directory it ran in (from the transcript, nil when unreadable).
    /// nil when there is no id in the text or no transcript for it.
    static func resumeTarget(in text: String) -> (sessionID: UUID, directory: String?)? {
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        guard let range = text.range(of: pattern, options: .regularExpression),
              let sessionID = UUID(uuidString: String(text[range])),
              let transcript = transcriptURL(sessionID: sessionID, cwd: nil) else { return nil }
        return (sessionID, transcriptDirectory(transcript))
    }

    private static func transcriptURL(sessionID: UUID, cwd: String?) -> URL? {
        let fileManager = FileManager.default
        let projects = claudeConfigDirectory().appendingPathComponent("projects", isDirectory: true)
        let fileName = sessionID.uuidString.lowercased() + ".jsonl"

        // Claude Code keys transcripts by its physical cwd (/tmp is /private/tmp).
        var candidates: [String] = []
        if let cwd {
            candidates.append(cwd)
            if let physical = ProcessInspector.physicalPath(cwd), physical != cwd {
                candidates.append(physical)
            }
        }
        for directory in candidates {
            let url = projects.appendingPathComponent(encodeProjectPath(directory), isDirectory: true)
                .appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: url.path) { return url }
        }

        // Claude Code shortens very long encoded names, so fall back to looking in every project folder.
        guard let folders = try? fileManager.contentsOfDirectory(atPath: projects.path) else { return nil }
        for folder in folders {
            let url = projects.appendingPathComponent(folder).appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The first `cwd` recorded in a transcript. Only the head is read, transcripts run to many megabytes.
    private static func transcriptDirectory(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1 << 20) else { return nil }
        for line in head.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = object["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// POSIX single-quote shell quoting.
    /// Words made only of safe characters stay bare: a quoted command word skips alias expansion, and some Claude
    /// installs only exist as a `claude` alias in .zshrc. A leading "=" is quoted because zsh expands `=word`.
    static func shellQuote(_ arg: String) -> String {
        if !arg.isEmpty, !arg.hasPrefix("="), arg.unicodeScalars.allSatisfy(isShellSafeScalar) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Internal helpers

    /// "/Users/me/my app" becomes "-Users-me-my-app".
    static func encodeProjectPath(_ path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            isASCIIAlphanumeric(scalar) ? Character(scalar) : "-"
        })
    }

    static func environment(sessionID: UUID, directory: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        // Started from inside Claude Code or a VS Code terminal (a dev build run from a shell), the app inherits
        // variables that break git in every session: GIT_EDITOR=true aborts `git commit` without -m, and the
        // VSCODE_GIT_* askpass hooks point at a socket that dies with that VS Code window.
        let fromClaudeCode = env["CLAUDECODE"] != nil
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("VSCODE_GIT_")
            || (fromClaudeCode && ["GIT_EDITOR", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT"].contains(key)) {
            env.removeValue(forKey: key)
        }
        // Inherited from whatever launched the app. The new shell computes its own.
        for key in ["OLDPWD", "SHLVL", "_"] {
            env.removeValue(forKey: key)
        }
        env["PWD"] = directory
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = ConchInfo.appName
        env["TERM_PROGRAM_VERSION"] = ConchInfo.version
        if (env["LANG"] ?? "").isEmpty {
            env["LANG"] = "en_US.UTF-8"
        }
        env["CONCH_SESSION_ID"] = sessionID.uuidString.lowercased()
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    static func claudeConfigDirectory() -> URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom.expandingTilde, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
    }

    private static func existingDirectory(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        return NSHomeDirectory()
    }

    private static func cloudRestoreBanner(task: String) -> String {
        let dim = "\u{1B}[2m", reset = "\u{1B}[0m"
        var lines = ["This web session keeps running in the cloud. Open it at https://claude.ai/code."]
        if !task.isEmpty {
            lines.insert("Web session: \(task)", at: 0)
        }
        return lines.map { dim + $0 + reset }.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphanumeric(scalar) || scalar == "_" || scalar == "-"
    }

    private static func isShellSafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphanumeric(scalar) || "@%+=:,./_-".unicodeScalars.contains(scalar)
    }
}
