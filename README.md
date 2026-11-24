# Agent Control Center

See every running Claude Code session — in iTerm, a VS Code terminal, the Claude panel in VS Code, or
the Claude desktop app's Code tab — with its live status, what it is doing right now, its last reply,
the ports it opened, and one click to jump to it.

Two front-ends, one core:

- **Menu bar app** (macOS): the icon counts running and other sessions, with an orange bell while one
  needs you; the dropdown lists sessions (long-idle ones folded away); right-click for settings; native
  notifications with "Jump to session".
  - **Control Center window**: opens when you launch the app (not when it starts at login), and from the
    dropdown's window button, right-click → Open Control Center, or the Dock icon: sessions grouped by what they need from you, the selected one's conversation (prompts,
    replies, tool calls folded into one line each, live), and its details and actions. Read-only on
    purpose: it tracks sessions wherever they run and sends you there to reply.
  - **Permissions**: when a session asks permission for a tool, the window shows the full command or edit
    with Allow / Always allow / Deny (with a reason for Claude), and the dropdown has quick Allow / Deny.
    Claude Code's own prompt still shows: whichever is answered first wins, so a session never waits on the
    app. Needs the hook registered with a longer timeout for PermissionRequest (`./install.sh hook`, or
    Settings › General › Update Hook). `agentctl approve|deny <session-id>` does the same from a terminal.
  - **Settings** (⌘,): notifications, idle folding, Dock icon (never / while a window is open / always),
    and themes: System (native), shadcn-style presets (Neutral, Zinc, Stone, Slate × 7 accents), and
    custom themes with a light and a dark value per color. Import a theme by pasting CSS (shadcn v3 / v4,
    tweakcn, Tailwind `@theme`, any CSS color variables) or from a file; export as JSON.
- **VS Code sidebar**: the same list inside VS Code (activity bar → Agents).

Per session: status, current step, last prompt / reply, model, effort, context use (tokens and % of the
window), git state (ahead / behind, staged, changed incl. new files, like VS Code's Source Control) and
ports. Globally: the plan's 5-hour and weekly usage.

Where the data comes from: the hook (`hook/agent-status.sh`) reports status, activity and, from the
transcript, model and context tokens for every session. The status line (`hook/agent-statusline.sh`,
registered by `install.sh hook` unless you already have one) adds the exact window size, effort and plan
usage; Claude Code runs it in terminal sessions only. A window size seen for a model is reused for the
other sessions on that model.

## Layout

```
hook/agent-status.sh     Claude Code hook → ~/.claude/agent-status/<session_id>.json
core/                    Swift package — the only place with scanning / focusing logic
  AgentCore              status files + ps + lsof → Snapshot; port attribution; iTerm/VS Code focus
  agentctl               CLI over AgentCore (bundled inside the VS Code extension)
  AgentControlApp        SwiftUI menu bar app + Control Center and Settings windows
vscode/                  extension: UI only, calls bin/agentctl
install.sh
```

```
claude ──hook──▶ ~/.claude/agent-status/*.json ──┐
                                                  ├──▶ AgentCore ──▶ menu bar app
ps + lsof ────────────────────────────────────────┘        └──▶ agentctl ──▶ VS Code extension
```

The JSON emitted by `agentctl snapshot` is the contract with the extension
(`core/Sources/AgentCore/Models.swift` ↔ typedefs in `vscode/core.js`).

### Focusing a VS Code session from outside VS Code

VS Code tabs can't be selected from another process, so `agentctl focus` raises the window for the
session's folder (`open -b com.microsoft.VSCode <folder>`) and writes `~/.claude/agent-status/.focus-request`. Every VS Code
window's extension watches that file; the one owning the terminal reveals it.

### Claude desktop app (Code tab)

Its sessions run Claude Code too, so the hook reports them (`entrypoint: claude-desktop`). Focusing one
maps the Claude Code session id to the app's own `local_…` id (from
`~/Library/Application Support/Claude/claude-code-sessions`), opens
`claude://code/continue?session=<local id>` and activates the app. Regular chats in the app run no
local process and are not tracked.

## Install

```sh
./install.sh                  # hook + VS Code extension (all profiles) + menu bar app + agentctl
./install.sh vscode app       # rebuild/reinstall only some parts (hook | vscode | app | cli)
./install.sh --uninstall
```

Requires Xcode (Swift 6), `jq` (ships with macOS) and `npx` for packaging the extension.
The app is installed to `~/Applications` and registers itself to launch at login (toggle in its ⚙ menu).
The first click on an iTerm session asks macOS for permission to control iTerm.

### DMG (menu bar app only)

```sh
./install.sh dmg              # → dist/AgentControlCenter-<version>.dmg
```

The app bundles the hook script; on a Mac without the repository it shows a "Set Up" banner that copies
it to `~/Library/Application Support/Agent Control Center/` and registers it in `~/.claude/settings.json`
(other hooks kept, backup saved). The app is ad-hoc signed, not notarized: on another Mac, open it the
first time with right-click → Open (or System Settings → Privacy & Security → Open Anyway).

## CLI

`./install.sh cli` copies `agentctl` to `~/.local/bin`.

```sh
agentctl list                 # human-readable
agentctl snapshot --pretty    # JSON
agentctl focus <pid|session-id>
agentctl transcript <session-id> [-n 30]   # the session's last turns
agentctl approve <session-id> [--always]   # answer a waiting permission request (app running)
agentctl deny <session-id> [message]
```

Tests: `swift test --package-path core`.
