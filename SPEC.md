# Conch spec

A lean native macOS terminal manager, built for running many Claude Code sessions side by side. Think of the
VS Code terminal panel (sidebar list of terminals, splits, rename, quick switching) as its own app, plus the session
awareness of Claude Code on the web (which sessions are working, which are waiting for you).

Stack: Swift 5 language mode, AppKit shell, SwiftUI for the sidebar, palette and settings, SwiftTerm 1.99.3 for the
terminal (LocalProcessTerminalView), SwiftPM only (no Xcode project). macOS 14+. No other dependencies.

The compilable contract lives in `Sources/Conch`. Signatures in the stub files are fixed. Bodies marked
`fatalError("TODO <agent>")` are yours to implement if you own the file. This document is the behaviour spec.

## Ownership

| Agent | Owns (whole directories) |
|---|---|
| lead | `Package.swift`, `Sources/Conch/Contract/`, `SPEC.md`, `scripts/`, `README.md` |
| core | `Sources/Conch/Terminal/` |
| store | `Sources/Conch/Model/`, `Sources/Conch/Services/` |
| shell | `Sources/Conch/App/`, `Sources/Conch/main.swift` |
| sidebar | `Sources/Conch/UI/` |

You may add new files only inside your own directories. You may add private or internal helpers in your own files.
You may not change a public signature from the contract. If the contract is wrong or missing something, work around it
inside your files and list the change you want under "Contract requests" in your reply.

## Session model

- A session is one pty running the user's login shell. Kinds: `.shell`, `.claude` (local Claude Code CLI), `.cloud`
  (`claude --cloud`, a Claude Code web session started or attached from the terminal).
- Claude sessions run `<shell> -l -i -c '<claude argv>; exec <shell> -l'` so the user drops into a shell when Claude
  exits and the login profile has set PATH. See `LaunchCommand` docs for the argv rules.
- New Claude sessions get a fresh UUID passed as `--session-id`. On app relaunch they come back as
  `claude --resume <uuid>` when the transcript file exists. This is how sessions survive a restart.
- Remote Control (`--remote-control <name>`, default on in settings) makes a local Claude session show up in
  claude.ai/code and the Claude mobile app. The name is the session's display name.
- A group is one tab: one or more sessions side by side (split right). The sidebar lists sessions, grouped into
  sections by project root (nearest ancestor with `.git`, else the cwd).

## Activity and attention (core agent implements, store and sidebar consume)

Output is observed with `LocalProcessTerminalView.setProcessOutputHandler` (runs on the IO thread, keep it to a
timestamp write under a lock). User input is observed by overriding `send(source:data:)`.

- Output that arrives within 0.25 s after user input is echo and does not count.
- A streak starts when counted output arrives after at least 1.5 s of quiet.
- `activity == .busy` while the last counted output is under 1.5 s old and the streak is at least 0.5 s long.
  Otherwise `.idle` once the process has started. `.exited(code:)` when the child exits.
- Busy to idle after a streak of at least 4 s while not visible: attention becomes at least `.done`, fire
  `onAttention(.done)`.
- Bell while not visible: attention `.needsInput(message: nil)`, fire `onAttention`.
- OSC 9 (except `4;...` progress reports), OSC 777 (`notify;title;body`) and OSC 99 desktop notifications while not
  visible: attention `.needsInput(message: <text>)`, fire `onAttention`. Use `TerminalView.observeOscEvents`.
- Counted output while not visible: attention becomes at least `.unread`, no callback.
- Attention only ever escalates by rank until cleared. `isVisibleToUser = true` clears it.
- Visible means: app active, main window visible and not miniaturized, and the session's group is selected.
  The store computes it.
- Evaluate on a lightweight main-thread timer (about 4 Hz is plenty). Hundreds of sessions are not a target, a dozen is.

## Titles

Claude Code sets the terminal title (OSC 0/2) to the task name, prefixed with a status glyph such as "✳" or a
braille spinner. Sanitize: strip control and bidi formatting characters, then strip leading symbols (Unicode
categories So and Sm, the Braille block U+2800 to U+28FF, Dingbats U+2700 to U+27BF), then whitespace, then cap at
120 characters. Empty after that means "no title".

## Keyboard and menus (shell agent)

App menu: About Conch, Settings (Cmd+,), Hide, Hide Others, Show All, Quit (Cmd+Q).

Session menu:
- New Claude Session (Cmd+N), in the active session's live cwd
- New Terminal (Cmd+T)
- New Web Session (Cmd+Shift+N), palette in newCloudSession mode
- Open Folder (Cmd+O)
- Quick Open (Cmd+P)
- Split Right with Terminal (Cmd+D), Split Right with Claude (Cmd+Shift+D)
- Rename (Cmd+Shift+R), Close (Cmd+W)
- Clear Scrollback (Cmd+K)
- New Claude in Worktree (Cmd+Option+N), after New Web Session, enabled inside a git repo
- Reveal in Finder, Open in VS Code, Copy Path (no shortcuts)
- Set Startup Command…, Save Layout for This Project (no shortcuts)
- Compact, Compact With Focus…, Clear Conversation…, Hand Off to New Session (no shortcuts), enabled for an idle Claude
  session with claude in the foreground

Edit menu: Copy, Paste, Select All, then Find (Cmd+F), Find Next (Cmd+G), Find Previous (Cmd+Shift+G), Use Selection
for Find (Cmd+E), all routed to SwiftTerm's `performFindPanelAction(_:)` with the standard NSFindPanelAction tags.
Check SwiftTerm's MacTerminalView.swift for the exact copy, paste and selectAll selectors it implements.

View menu: Toggle Sidebar (Cmd+B), Command Palette (Cmd+Shift+P), Bigger (Cmd+=), Smaller (Cmd+-), Actual Size
(Cmd+0), Enter Full Screen (Ctrl+Cmd+F).

Window menu: Minimize (Cmd+M), Zoom, Next Session (Cmd+Shift+]), Previous Session (Cmd+Shift+[), Next Pane
(Cmd+Option+Right), Previous Pane (Cmd+Option+Left), Jump to Next Waiting (Cmd+J: needsInput before done, oldest
first), Modules (Cmd+Shift+M), Session 1 to 9 (Cmd+1 to Cmd+9 select group by sidebar index).

Ctrl+Tab and Ctrl+Shift+Tab cycle sessions (local key event monitor, so the terminal does not get the tab).

Shift+Return in a terminal sends ESC CR (core agent, in ConchTerminalView).

## Window (shell agent)

- One main window, about 1200 by 760, min 640 by 400, frame autosaved. Unified toolbar style with a sidebar toggle
  and the sidebar tracking separator. Title is the active session's display name, subtitle its cwd with `~`.
- NSSplitViewController: sidebar item hosting `SidebarView` (min 200, max 420, default 250), content item hosting
  the terminal container.
- Container keeps every group's view alive, shows only the selected group and hides the rest (never tear down a
  terminal view to switch). A group with 2+ sessions is an NSSplitView with side-by-side panes, equal widths when a
  pane is added. Each terminal sits on `TerminalTheme.background(dark:)` with a few points of padding. When the
  selected group changes, focus its focused session. Track clicks into panes through `TerminalSession.onFocus`
  (the store already sets focusedSessionID there).
- Empty state (no groups): host `EmptyStateView` in the content area.
- Closing the window (red button) hides it and keeps sessions running. Clicking the dock icon shows it again.
- On light/dark change call `store.applyAppearanceToAll()`.
- Quit: if any session `hasRunningChild`, a confirmation alert naming the running processes, noting Claude
  sessions resume on next launch. Then `store.save()` and `store.terminateAll()`.
- Launch: build menus, `Notifier.requestAuthorizationIfNeeded()`, wire `Notifier.onActivateSession` to select the
  session and show the window, then `store.restore()`. Nothing restored shows the empty state.
- Settings window (SwiftUI Form): font size, Option as Meta, Remote Control for new Claude sessions (with one line
  explaining it makes sessions appear in claude.ai/code), restore sessions on launch, notify when done, notify on
  bell, project folders (add with NSOpenPanel, remove), default directory. Changes apply live.

## Smoke test (shell agent, `App/SmokeTest.swift`)

`Conch --smoke-test <result.json>`: skip restore and notification authorization, run checks, write
`{"passed": Bool, "checks": [{"name", "ok", "detail"}]}` and exit 0 when all pass, 1 otherwise, 2 on a 30 s timeout.
The runner sets `CONCH_STATE_PATH` so real state is untouched. Checks:
1. `newShell(in: <temp dir>)`, send `echo CONCH_SMOKE_$((40+2))\r`, poll `bufferText()` up to 8 s for `CONCH_SMOKE_42`.
2. `refreshProcessInfo()` gives a currentDirectory equal to the temp dir after resolving symlinks.
3. Send `sleep 3\r`, after 0.7 s `hasRunningChild` is true and `foregroundProcess == "sleep"`.
4. `newShell(split: true)` gives a selected group with 2 sessions.
5. LaunchCommand: new Claude argv contains `--session-id` and `--remote-control` when enabled; restoring without a
   transcript still uses `--session-id`; `.cloud` with a description while restoring returns nil; attach target
   detection for `session_01ABC`, `https://claude.ai/code/session_01ABC`, and not for `fix the login bug`.
6. `save()` then `Persistence.load()` returns one group with two sessions.
7. Close the split session, the group has one session.

## Sidebar and palette (sidebar agent)

Sidebar:
- Top bar: a primary "New Claude" button (sparkle icon), a "New Terminal" button, and a Quick Open (magnifier) button,
  each with a tooltip showing its shortcut.
- List with one section per `store.sections` entry (header: project name, plus a hover "+" menu for Claude or a
  terminal at the project root), then the Older section (see v0.2 features). Rows are sessions; second and later
  panes of a split group are indented with a small split glyph so groups read clearly.
- Selection: the active session's row. Selecting a row calls `store.select`.
- Row: project icon when the project has one (see Project icons), status icon, display name (semibold when attention is done or needsInput), secondary line (foreground process
  when one is running, else the cwd's last two path components with `~`), hover close button calling
  `AppActions.requestClose`. Remote-controlled Claude sessions show a small broadcast glyph.
- Status icon: exited is a grey circle with the name dimmed and "exited" or "exited (code)" as the secondary line;
  busy is a small spinner; needsInput is an orange dot; done is a green checkmark; unread is a small accent dot;
  otherwise the kind icon (terminal for shell, sparkle in Claude orange #D97757 for claude, cloud for cloud).
- Double-click a row or `store.renamingSessionID == id` shows an inline TextField. Return commits via
  `store.rename`, Escape cancels. Either sets `renamingSessionID` to nil.
- Context menu: Rename, Split Right with Terminal, Split Right with Claude, New Claude Session Here, New Terminal Here,
  Reveal in Finder, Open in VS Code, Copy Path, Close.
- Dropping a folder from Finder onto the sidebar starts a Claude session there.
- Native look: `.listStyle(.sidebar)`, SF Symbols, no custom chrome beyond what is described.

EmptyStateView: a calm centred block with the app name, one line ("Run Claude Code and terminals side by side"), and
three buttons: New Claude Session (Cmd+N), New Terminal (Cmd+T), Quick Open (Cmd+P), plus up to five recent
directories as quick links that start Claude there.

Command palette:
- A borderless key-capable child panel, about 620 wide, near the top centre of the main window, rounded with a
  popover material background. Escape, clicking outside, or running an item closes it.
- Up and Down move the highlight, Return runs the primary action, Cmd+Return the secondary. Use a local key monitor
  while the panel is key so modifiers are visible.
- quickOpen: matching open sessions (Return switches), then recent directories and scanned projects
  (`ProjectScanner.scan(roots: settings.projectRoots)` off the main thread, cached for 60 s). Projects: Return starts
  Claude, Cmd+Return a terminal. Right-aligned hint text shows the keys. If the query is a web session id or
  claude.ai/code URL (`LaunchCommand.isCloudAttachTarget`), the first item is "Attach to web session", which calls
  `store.newCloud(target:in:)` in `store.defaultDirectory()`.
  If the query contains a local Claude Code session id (a bare UUID or a pasted `claude --resume <id>`) with a
  transcript (`LaunchCommand.resumeTarget(in:)`), an item "Resume Claude session" calls
  `store.resumeClaude(sessionID:in:)` in the directory the transcript recorded, which runs `claude --resume <id>`,
  or switches to the Conch session already running it.
- commands: New Claude Session, New Terminal, New Web Session, Open Folder, Split Right with Terminal, Split Right
  with Claude, Rename Session, Close Session, Clear Scrollback, Toggle Sidebar, Bigger Text, Smaller Text,
  Reveal in Finder, Open in VS Code, Settings, and "Remote Control for New Sessions: On/Off" which toggles the
  setting. Show each command's shortcut.
- newCloudSession: one field, placeholder "Describe a task for a new Claude Code web session", footer showing the
  directory it runs in and "Paste a claude.ai/code link to attach instead". Return calls `store.newCloud`.
- Fuzzy matching: case-insensitive subsequence with bonuses for prefix, word starts and consecutive runs.

## Store details (store agent)

- `newSession` wires the session: `onAttention` posts a notification when the matching setting is on
  (title = display name, body = the needsInput message, or "Waiting for your input", or "Finished" for done, plus the
  project folder name), `onExit` updates nothing structural (the row shows exited, the user closes it), `onFocus`
  sets the group's focusedSessionID and selects the group. Applies appearance from settings, starts it.
- Observe every session's `attention` and update the dock badge with `attentionCount`.
- Visibility: observe NSApplication didBecomeActive and didResignActive, main window miniaturize and deminiaturize
  and occlusion changes, and selection changes, then `recomputeVisibility()`.
- A ~2 s main-thread timer calls `refreshProcessInfo()` on sessions in the selected group plus any session with a
  running child. Keep it cheap.
- Save, debounced by about 1 s, after structural changes (add, close, move, rename, split, selection), when a group
  moves into or out of Older, and on quit.
- `restore()`: recreate groups and sessions with `restoring: true`, `startDirectory: lastDirectory`, same ids,
  select the saved group. Skip sessions whose `spec.cwd` no longer exists (use the home directory for shells instead).

## v0.2 features

Each feature lives in its own files, named after it, and hooks into the palette, menus, sidebar row, launch command
and smoke test through one call each (see the v0.2 contract in Contract/Types.swift).

- Recent conversations (Services/ConversationIndex, UI/Palette+RecentConversations): transcripts under
  `<config>/projects/*/<uuid>.jsonl`, newest first, title from the latest custom-title, else ai-title, else the first
  real prompt (60 characters). Skips `claude -p` runs (sdk entrypoints), conversations open in Conch and ones whose
  folder is gone. Off the main thread, per-file cache. Smoke check 11.
- Attention jump and menu bar (App/Menu+Attention, App/AttentionStatusItem, SessionStore.waitingSessions): counts
  what the dock badge counts. Setting `conch.showInMenuBar`, default on. Smoke check 12.
- Layouts and startup commands (Model/LayoutStore, Model/SessionStore+Layouts, App/LayoutActions): one layout per
  project root in layouts.json next to the state file. `LaunchSpec.command` runs as
  `<shell> -l -i -c '<command>; exec <shell> -l'`. Smoke check 13.
- Worktrees (Terminal/LaunchCommand+Worktree, Model/SessionStore+Worktree): `claude --worktree=<name>` from the repo
  root, worktree at `<repo>/.claude/worktrees/<name>` on branch `worktree-<name>`. Never passes `--worktree` when the
  folder is gone but the branch remains (claude would reset the branch). Smoke check 14.
- Context (Services/ContextStatusLine, Services/ContextMonitor, App/ContextActions): `--settings=<file>` whose
  statusLine wrapper saves Claude Code's statusline JSON to `context/<CONCH_SESSION_ID>.json` and chains to the
  user's statusLine. The monitor updates `TerminalSession.context` and follows `session_id` changes (after /clear)
  into `spec.claude.sessionID`. Initial prompts go after `--`, and a one-word prompt gets a trailing space so claude
  never dispatches it as a subcommand. Smoke check 15.
- Modules (Services/ModuleIndex, UI/ModulesSidebarSection, UI/ModulesView, App/ModulesWindowController,
  App/ModuleActions, UI/Palette+Modules): the child folders of `conch.modulesFolder` (default `~/development/modules`)
  whose module.json has a name, sorted by name. Every other field is optional and unknown fields are ignored. Features
  come from `features`, else the first run of top-level "- " bullets in README.md (first sentence, backticks stripped).
  Installs come from `modules.json` at the root of each project `ProjectScanner` finds, keyed by the module's folder
  name. An install is behind when its version is lower, comparing dotted numbers numerically. The sidebar section sits
  under the session List, not inside it, so it never takes selection, keyboard navigation or the folder drop, and it
  is hidden when there are no modules. Install, Update and Show Changes run
  `node <folder>/bin/install.mjs <module> <project> [--diff]` (each word through `LaunchCommand.shellQuote`) as the
  startup command of a new terminal in the project, cleared from the spec once started so a relaunch never runs it
  again. Install in Project offers the scanned projects with a package.json that do not have the module, the active
  session's project first. Update's confirmation follows the recorded commit: with one, changed files are merged and
  Show Changes is the default button; with "uncommitted" install.mjs overwrites every changed non-seam file; with none
  it writes `<file>.module` beside each changed file. Those two offer no Show Changes (`--diff` needs a commit) and
  Cancel is the default. Quick Open matches modules by name only and lists them after folders and projects. Folders
  starting with "-" are skipped, and so are Desktop, Documents and the like when the modules folder is the home
  folder. The section's collapsed state is `conch.modulesCollapsed`. The list reloads when the app becomes active, the
  Modules window becomes key, or the modules folder or project folders setting changes, never on a timer. Smoke
  check 16.
- Usage (Services/UsageMonitor, UI/UsageStrip, UI/UsagePopover): ContextMonitor hands every reading it applies to
  UsageMonitor. Plan limits come from `rate_limits.five_hour` and `seven_day`: a later window replaces the stored one,
  a lower figure in the same window is a stale report and is ignored unless the session's `total_cost_usd` went up
  since its previous report (an API call finished, so its rate limits are current) and the report is not older than
  the newest such report already applied, and a passed `resets_at` reads as unknown. Only a changed figure is published and saved. They
  persist to usage.json next to the state file. Last prompt, per Conch session: `cost.total_cost_usd` minus the total
  at the last report of the previous `prompt_id`. No figure until there is a baseline (a report before the first
  prompt, or a zero total), and a drop in the total or a new `session_id` resets it. Cost by main model: positive
  deltas between consecutive reports of one session, to the newer report's `model.id`, summed per local day, 35 days
  kept. `total_cost_usd` covers every model the session called (subagents, background calls) while `model.id` is only
  the main model, so that spend counts under the main model.
  This week is the current `seven_day` window (whole days from the day it started), else the last 7 days. One toolbar
  item after the flexible space, setting `conch.showUsageInToolbar`, default on. The last prompt drops when the
  terminal area is under 600 pt wide, the labels under 480. Smoke check 17.
- Older (Model/SessionStore, UI/Sidebar+Older, App/SettingsView): each session has a last active time, the latest
  of typing (keys, pastes, text sent as if typed), counted output and a visibility change, on the store's injectable
  clock. Output from a restored session inside its restore quiet period does not count, and each restore ends only
  its own quiet period. A visible session counts as active now. The selected group counts as in view for as long as
  it is selected, so it never goes Older, and selecting or leaving it stamps the time. Saved as
  `PersistedSession.lastActive` (optional; a file without it restores as active at launch). A group is Older when
  every session in it has been idle longer than `conch.olderAfterHours` (Off, 1, 3, 6, 12 or 24, default 6; Off
  means no Older section). `projectOrder` holds every group in section order and is what gets saved; `groups` is
  its project sections followed by its Older groups, so `groups`, `allSessions` and the sidebar stay one order and a
  group coming back lands where it was. Never re-sorted by activity: membership changes only at a crossing, or when
  an Older group is typed into, prints or is selected. A one-shot wall-clock timer runs at the next crossing and is
  rescheduled on every recompute (structural changes, selection, setting changes, activity in an Older group). Closing
  the selected group selects a neighbour from the project sections while any remain. The section is the List's last
  Section, collapsible (`conch.olderCollapsed`), with the session count beside the title while collapsed, hidden
  when empty. Older rows lead their second line with the project name: "name · status", "name" at the root,
  "name/sub" below it, else "name · short path". Smoke check 18.
- Project icons (Services/ProjectIcons, UI/ProjectIconView, App/ProjectIconActions): a 16 pt icon at the leading edge
  of every row, before the status icon, for the row's section root (in Older, the row's own project). A custom icon
  wins: an image copied as a PNG at most 64 px on its longer side into `project-icons/`, or one emoji (a character
  shown as emoji by default, or one with several scalars), mapped in `project-icons.json`, both next to the state
  file and keyed by the symlink-resolved project root. Else the project's own icon, looked up once per root off the
  main thread and cached for the run: `app/icon.png`, `src/app/icon.png`, `app/apple-icon.png`,
  `public/apple-touch-icon.png`, `public/icon.png`, `public/logo.png`, `public/favicon.png`, `app/favicon.ico`,
  `src/app/favicon.ico`, `public/favicon.ico` in the root, then the same list in `site/`, `web/` and `app/`. Roots in
  the home folder's Desktop, Documents, Downloads, Pictures, Music, Movies or Library, or under /Volumes, are never
  read. Else nothing, and the row keeps its old layout. Images are decoded with ImageIO from the largest
  representation (an .ico or .icns holds several), never enlarged, and clipped to a 4 pt continuous rounded rectangle.
  Set Project Icon (Choose Image…, Use Emoji…, Remove Icon) is a submenu in the row and section header context menus.
  Smoke check 19.
- Model (Model/ClaudeModels, Terminal/LaunchCommand+Model, Model/SessionStore+Model, App/ModelActions,
  App/Menu+Model, UI/Palette+Model, UI/ModelPicker): `ClaudeOptions.model` is passed as `--model=<model>` on every
  launch of a `.claude` session, new or resumed (a state file without it loads as nil, which passes nothing). The
  context monitor records each report's `model.id` there and its `model.display_name` on `TerminalSession.modelName`
  (cleared with the context reading when claude exits to the shell), so a relaunch keeps the model in use however it
  was chosen, except that a family alias chosen in Conch stays while the reports are from that family, so the
  session keeps following the latest model. The menus come from `ClaudeModels.families`: Fable, Opus, Sonnet and Haiku,
  each a Latest entry (the alias) then its specific ids from the Claude API models overview, newest first, without
  retired or limited-access models. A dated id (`-YYYYMMDD`) or a `[1m]` id checks its model's entry. Other Model…
  takes any one-word id of letters, digits and `-._:[]` not starting with "-". Choosing, from the toolbar menu (before
  the usage strip, active Claude session only, a submenu per family with checkmarks), the Session menu's Model submenu
  (same shape) or the palette ("Switch Model to …": the Latest entries always, specific ones and Other only while a
  query is typed), types `/model <model>` under the same rule as Compact (Claude at its empty prompt), records the
  model at once and clears `modelName` until the next report. Setting `conch.defaultModel` ("" for Claude Code's
  default, else a menu entry's model) seeds new Claude, worktree and layout sessions, and a hand off inherits its
  source's model. Smoke check 20.
- Codex and reviews (Terminal/LaunchCommand+Codex, Services/CodexSessions, Model/SessionStore+Codex, App/ReviewActions,
  App/Menu+Codex, UI/Palette+Codex): `SessionKind.codex` runs `codex` through the login shell like Claude, with
  `LaunchSpec.codex` options. A launch is `codex resume <id>` when `<CODEX_HOME or ~/.codex>/sessions` still holds a
  `rollout-*-<id>.jsonl`, else `codex [extra] [-- <first message>]`; the first message is cleared from the spec once
  started. Codex picks its own ids, so CodexSessionTracker (every 3 s, only while a Codex session has none) reads the
  `session_meta` first line of rollouts in the day folders since 30 s before it first saw the session, and gives
  each session the oldest unclaimed one for its folder (symlinks resolved) started no earlier than that. Layouts
  save Codex panes as a fresh spec in the same folder. Copy cleanup stays Claude-only. Ask Codex to Review (a Claude
  session) and Ask Claude to Review (a Codex session), in the Session menu and the palette, need the agent running and
  idle and no review of it under way. They create `<folder>/.conch/reviews/` (folder: Claude's reported project
  folder, else the live folder), add `.conch` to the repository's info/exclude, and open the other agent split into
  the author's group, unselected, named "Codex review" or "Claude review", with a one-line request naming the note
  file `review-<yyyyMMdd-HHmmss>-<reviewer>.md`. ReviewLoop (1 s ticks, 45 minutes) waits for the note to be written
  since the request with the reviewer idle (and seen busy, or the file 3 s old), then types a one-line hand-back into
  the author once it can take it: Claude at an empty prompt (ContextActions), Codex idle with no user input since the
  request (`TerminalSession.lastInputAt`). It says once that the review is waiting, and gives up with the note's path
  if the reviewer closes before writing it or time runs out. Smoke check 21.
