import AppKit

// Owner: codex builder (feature/codex). Claude and Codex review each other's work.

@MainActor
enum ReviewActions {
    private static var store: SessionStore { SessionStore.shared }
    static let reviewsFolder = ".conch/reviews"

    /// Claude's work goes to Codex and Codex's to Claude. nil for terminals and web sessions.
    static func reviewerKind(for author: TerminalSession) -> SessionKind? {
        switch author.spec.kind {
        case .claude: return .codex
        case .codex: return .claude
        case .shell, .cloud: return nil
        }
    }

    static func agentName(_ kind: SessionKind) -> String {
        kind == .codex ? "Codex" : "Claude"
    }

    /// An agent session with its agent still running, not mid-turn, and no review of it under way.
    static func canRequest(_ author: TerminalSession) -> Bool {
        reviewerKind(for: author) != nil && author.foregroundProcess != nil && author.activity == .idle
            && !ReviewLoop.isPending(for: author)
    }

    /// The folder the author works in: for Claude, the project folder it last reported (a worktree when it runs
    /// in one), else the session's live folder.
    static func workDirectory(of author: TerminalSession) -> String {
        if author.spec.kind == .claude, let reported = ContextMonitor.shared.directory(for: author) { return reported }
        return author.currentDirectory
    }

    /// `<folder>/.conch/reviews/review-<yyyyMMdd-HHmmss>-<reviewer>.md`.
    static func noteURL(in directory: String, reviewer: SessionKind, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(reviewsFolder, isDirectory: true)
            .appendingPathComponent("review-\(formatter.string(from: now))-\(agentName(reviewer).lowercased()).md")
    }

    /// One line, so it can be typed or passed as an argument as is.
    static func requestPrompt(author: SessionKind, note: URL) -> String {
        "\(agentName(author)) has been working in this folder. Review its work: the uncommitted changes (run git status "
            + "and git diff, and read any new files), or the latest commit (git show HEAD) when nothing is uncommitted, "
            + "or the most recently changed files when this is not a git repository. Look for bugs, missing cases, "
            + "security problems and anything left unfinished. Do not change any project files. Write your findings to "
            + "\(note.path), most important first, each with the file and line and why it matters, or say plainly that "
            + "you found nothing to fix. Then reply with one line saying it is written."
    }

    static func deliveryPrompt(reviewer: SessionKind, note: URL) -> String {
        "\(agentName(reviewer)) reviewed your work and wrote its findings to \(note.path). Read it, fix the points you "
            + "agree with, and tell me which ones you disagree with and why."
    }

    /// Opens the other agent beside the author with the review request, then hands the review back when it is written.
    static func requestReview(of author: TerminalSession) {
        guard let reviewer = reviewerKind(for: author) else { return }
        guard !ReviewLoop.isPending(for: author) else {
            Toast.show("A review of “\(author.displayName)” is already under way")
            return
        }
        guard author.foregroundProcess != nil, author.activity == .idle else {
            NSSound.beep()
            Toast.show("\(agentName(author.spec.kind)) is still working. Ask for a review when it finishes")
            return
        }
        let directory = workDirectory(of: author)
        let note = noteURL(in: directory, reviewer: reviewer)
        do {
            try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            AppActions.showError("Could not start the review", detail: "Conch could not create \(note.deletingLastPathComponent().path): \(error.localizedDescription)")
            return
        }
        // Keeps the whole .conch folder out of git, so reviews are never committed.
        ContextGitExclude.add(URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(".conch", isDirectory: true))

        let prompt = requestPrompt(author: author.spec.kind, note: note)
        let groupID = store.group(containing: author)?.id
        let session = reviewer == .codex
            ? store.newCodex(in: directory, prompt: prompt, splitInto: groupID, select: false)
            : store.newClaude(in: directory, prompt: prompt, splitInto: groupID, select: false)
        session.customName = "\(agentName(reviewer)) review"
        ReviewLoop.start(author: author, reviewer: session, reviewerKind: reviewer, note: note)
        Toast.show("\(agentName(reviewer)) is reviewing “\(author.displayName)”")
    }
}

/// Waits for the reviewer to write its note and go quiet, then types the delivery prompt into the author once it
/// can take it: Claude at an empty prompt, or Codex idle with nothing typed into it since the review started.
@MainActor
final class ReviewLoop {
    private static var active: [UUID: ReviewLoop] = [:]
    private static let timeout: TimeInterval = 45 * 60

    private let authorID: UUID
    private let reviewerID: UUID
    private let reviewerKind: SessionKind
    private let note: URL
    private let requested = Date()
    private var sawBusy = false
    private var written = false
    private var toldWaiting = false
    private var timer: Timer?

    static func isPending(for author: TerminalSession) -> Bool {
        active[author.id] != nil
    }

    static func start(author: TerminalSession, reviewer: TerminalSession, reviewerKind: SessionKind, note: URL) {
        active[author.id]?.stop()
        let loop = ReviewLoop(authorID: author.id, reviewerID: reviewer.id, reviewerKind: reviewerKind, note: note)
        active[author.id] = loop
        let timer = Timer(timeInterval: 1, repeats: true) { [weak loop] _ in
            MainActor.assumeIsolated { loop?.tick() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        loop.timer = timer
    }

    private init(authorID: UUID, reviewerID: UUID, reviewerKind: SessionKind, note: URL) {
        self.authorID = authorID
        self.reviewerID = reviewerID
        self.reviewerKind = reviewerKind
        self.note = note
    }

    private var reviewerName: String { ReviewActions.agentName(reviewerKind) }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if Self.active[authorID] === self { Self.active[authorID] = nil }
    }

    private func tick() {
        let store = SessionStore.shared
        if Date().timeIntervalSince(requested) > Self.timeout {
            give(up: "The review did not finish", written
                 ? "\(reviewerName)'s review is at \(note.path). Conch could not hand it over within 45 minutes."
                 : "\(reviewerName) did not write \(note.path) within 45 minutes.")
            return
        }
        if !written {
            guard let reviewer = store.session(withID: reviewerID), !reviewer.activity.isExited else {
                if noteWritten() { written = true } else {
                    give(up: "The review stopped", "\(reviewerName) was closed before it wrote \(note.path).")
                    return
                }
                return
            }
            if reviewer.activity == .busy {
                sawBusy = true
                return
            }
            guard reviewer.activity == .idle, noteWritten() else { return }
            written = true
        }
        guard let author = store.session(withID: authorID), !author.activity.isExited else {
            stop()
            Toast.show("\(reviewerName)'s review is at \(note.path)")
            return
        }
        guard canTake(author) else {
            if !toldWaiting {
                toldWaiting = true
                Toast.show("\(reviewerName)'s review is ready. It goes to “\(author.displayName)” once that is free")
            }
            return
        }
        stop()
        ContextActions.type(ReviewActions.deliveryPrompt(reviewer: reviewerKind, note: note), into: author)
        Toast.show("Sent \(reviewerName)'s review to “\(author.displayName)”")
    }

    /// Written since the request, and either the reviewer was seen working or the file is a few seconds old (a
    /// turn too quick to catch as busy).
    private func noteWritten() -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: note.path))?[.modificationDate] as? Date
        else { return false }
        return modified >= requested.addingTimeInterval(-1) && (sawBusy || modified.timeIntervalSinceNow < -3)
    }

    private func canTake(_ author: TerminalSession) -> Bool {
        switch author.spec.kind {
        case .claude:
            return ContextActions.canAct(on: author) && ContextActions.promptState(author) == .empty
        case .codex:
            // Codex's prompt is not read from the screen, so typing waits until nothing was typed since the request.
            return author.activity == .idle && author.foregroundProcess != nil && (author.lastInputAt ?? .distantPast) < requested
        case .shell, .cloud:
            return false
        }
    }

    private func give(up message: String, _ detail: String) {
        stop()
        AppActions.showError(message, detail: detail)
    }
}
