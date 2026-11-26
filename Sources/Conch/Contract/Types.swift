import Foundation

// Shared value types. Owned by the lead. Agents read these, never edit them.

enum ConchInfo {
    static let appName = "Conch"
    static let bundleID = "com.alexgrant.conch"
    static let version = "0.3.0"
    /// A test run (CONCH_STATE_PATH set). It stays in the background, with no Dock icon and never activated, so a
    /// smoke test or a builder's throwaway instance never takes focus from the app in use.
    static let isIsolated = !(ProcessInfo.processInfo.environment["CONCH_STATE_PATH"] ?? "").isEmpty
}

/// What a session runs.
enum SessionKind: String, Codable, CaseIterable {
    /// The user's login shell.
    case shell
    /// Local Claude Code CLI. With `remoteControl` it also shows up in claude.ai/code and the mobile app.
    case claude
    /// `claude --cloud ...`: a Claude Code web session started or attached from this terminal.
    case cloud
    /// OpenAI's Codex CLI. Resumes with `codex resume <id>` once Codex has recorded the session.
    case codex
}

struct ClaudeOptions: Codable, Equatable {
    /// Passed as `--session-id` on first launch and `--resume` on restore. Unused for `.cloud`.
    var sessionID: UUID = UUID()
    /// Adds `--remote-control <name>` so the local session appears in claude.ai/code.
    var remoteControl: Bool = false
    /// `.cloud` only: a task description for a new web session, or a `session_...` id or
    /// `https://claude.ai/code/...` URL to attach to.
    var cloudTarget: String? = nil
    /// Extra CLI args appended verbatim, one argv entry each.
    var extraArgs: [String] = []
    /// `.claude` only: run in a git worktree of this name (`claude --worktree=<name>`). nil runs in `cwd`.
    var worktree: String? = nil
    /// `.claude` only: the first message, sent on the first launch only, never when resuming.
    var initialPrompt: String? = nil
    /// `.claude` only: passed as `--model=<model>` on every launch, new or resumed. An alias ("opus") or a full
    /// model id. Follows the model Claude Code reports, so a relaunch keeps the one in use. nil starts with
    /// Claude Code's own default.
    var model: String? = nil
}

struct CodexOptions: Codable, Equatable {
    /// Codex's own session id, read from its session files after it starts (CodexSessionTracker). With it a launch
    /// runs `codex resume <id>`. nil until Codex has recorded the session.
    var sessionID: String? = nil
    /// The first message, passed on the first launch only and cleared from the spec once the session has started.
    var initialPrompt: String? = nil
    /// Extra CLI args appended verbatim, one argv entry each.
    var extraArgs: [String] = []
}

struct LaunchSpec: Codable, Equatable {
    var kind: SessionKind
    /// Absolute directory the session starts in, tilde already expanded.
    var cwd: String
    /// Required for `.claude` and `.cloud`, nil for `.shell`.
    var claude: ClaudeOptions?
    /// `.shell` only: a command run in the login shell when the pane starts and again on every restore (for
    /// example `npm run dev`). The pane drops into a plain shell when it exits. nil runs a bare shell.
    var command: String? = nil
    /// Required for `.codex`, nil for the other kinds.
    var codex: CodexOptions? = nil

    static func shell(_ cwd: String) -> LaunchSpec {
        LaunchSpec(kind: .shell, cwd: cwd, claude: nil)
    }

    static func claude(_ cwd: String, remoteControl: Bool) -> LaunchSpec {
        LaunchSpec(kind: .claude, cwd: cwd, claude: ClaudeOptions(remoteControl: remoteControl))
    }

    static func cloud(_ cwd: String, target: String) -> LaunchSpec {
        LaunchSpec(kind: .cloud, cwd: cwd, claude: ClaudeOptions(cloudTarget: target))
    }

    static func codex(_ cwd: String, prompt: String? = nil) -> LaunchSpec {
        LaunchSpec(kind: .codex, cwd: cwd, claude: nil, codex: CodexOptions(initialPrompt: prompt))
    }
}

enum ActivityState: Equatable {
    case starting
    /// Sustained output recently (see TerminalSession for the exact rule).
    case busy
    case idle
    case exited(code: Int32?)

    var isExited: Bool {
        if case .exited = self { return true }
        return false
    }
}

/// Why a session wants the user's eye. Cleared when the user looks at it.
enum Attention: Equatable {
    case none
    /// Printed output while not visible.
    case unread
    /// Was busy for a while, then went quiet while not visible (Claude finished a turn).
    case done
    /// Bell, or an OSC 9 / 99 / 777 desktop notification (Claude waiting for input or permission).
    case needsInput(message: String?)

    var rank: Int {
        switch self {
        case .none: return 0
        case .unread: return 1
        case .done: return 2
        case .needsInput: return 3
        }
    }
}

/// A sign that a session is in use, for its last active time (SPEC "Older").
enum SessionUse: Equatable {
    /// The user typed or pasted into it, or Conch sent text as if typed.
    case input
    /// Counted output: not echo of typing, not a redraw after a resize.
    case output
    /// It started or stopped being visible to the user.
    case visibility
}

struct PersistedSession: Codable, Equatable {
    var id: UUID
    var customName: String?
    var lastTitle: String?
    /// Live working directory when saved. A restored `.shell` starts here. Claude sessions always restart in `spec.cwd`.
    var lastDirectory: String?
    var spec: LaunchSpec
    /// Last time it was typed into, printed output or was visible. nil in state files from before the Older section,
    /// which restore as active at launch.
    var lastActive: Date? = nil
}

struct PersistedGroup: Codable, Equatable {
    var id: UUID
    var sessions: [PersistedSession]
    var focusedSessionID: UUID?
}

struct PersistedState: Codable, Equatable {
    var version: Int = 1
    var groups: [PersistedGroup] = []
    var selectedGroupID: UUID?
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }

    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }

    var lastPathComponentOrSelf: String {
        let name = (self as NSString).lastPathComponent
        return name.isEmpty ? self : name
    }
}

// MARK: - v0.2 contract: recent conversations, layouts, context

/// A Claude Code conversation found on disk, for Quick Open's recent list.
struct ConversationSummary: Equatable, Identifiable {
    var sessionID: UUID
    /// Directory it ran in: the first `cwd` recorded in the transcript.
    var directory: String
    /// The latest /rename title, else Claude Code's latest AI title, else the first real user prompt. One line,
    /// about 60 characters at most.
    var title: String
    /// Transcript modification time.
    var modified: Date
    var id: UUID { sessionID }
}

/// One pane of a saved project layout.
struct LayoutPane: Codable, Equatable {
    var customName: String?
    var spec: LaunchSpec
}

/// Panes saved for a project and opened together as one group.
struct ProjectLayout: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// Project root the layout belongs to.
    var root: String
    var panes: [LayoutPane]
}

/// A Claude session's context window use, as Claude Code reports it to its statusline.
struct ContextUsage: Equatable {
    /// 0 to 100.
    var usedPercent: Double
    var windowTokens: Int?
    /// The conversation Claude Code is on now. Differs from the launch id after /clear or /resume.
    var claudeSessionID: UUID?
    var updated: Date
}
