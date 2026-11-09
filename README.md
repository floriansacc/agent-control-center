# Agent Control Center

See every running Claude Code session — in iTerm, a VS Code terminal, or the Claude panel in
VS Code — with its live status, the ports it opened, and one click to jump to it.

Two front-ends, one core:

- **Menu bar app** (macOS): icon shows what needs you; dropdown lists sessions; detach it as an
  always-on-top floating panel; native notifications with "Jump to session".
- **VS Code sidebar**: the same list inside VS Code (activity bar → Agents).

## Layout

```
hook/agent-status.sh     Claude Code hook → ~/.claude/agent-status/<session_id>.json
core/                    Swift package — the only place with scanning / focusing logic
  AgentCore              status files + ps + lsof → Snapshot; port attribution; iTerm/VS Code focus
  agentctl               CLI over AgentCore (bundled inside the VS Code extension)
  AgentControlApp        SwiftUI menu bar app + floating panel
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
session's folder (`code <folder>`) and writes `~/.claude/agent-status/.focus-request`. Every VS Code
window's extension watches that file; the one owning the terminal reveals it.

## Install

```sh
./install.sh                  # hook + VS Code extension (all profiles) + menu bar app
./install.sh vscode app       # rebuild/reinstall only some parts (hook | vscode | app)
./install.sh --uninstall
```

Requires Xcode (Swift 6), `jq` (ships with macOS) and `npx` for packaging the extension.
The app is installed to `~/Applications` and registers itself to launch at login (toggle in its ⚙ menu).
The first click on an iTerm session asks macOS for permission to control iTerm.

## CLI

```sh
vscode/bin/agentctl list                 # human-readable
vscode/bin/agentctl snapshot --pretty    # JSON
vscode/bin/agentctl focus <pid|session-id>
```

Tests: `swift test --package-path core`.
