// @ts-check
'use strict';

const vscode = require('vscode');
const fs = require('fs');
const { snapshot, STATUS_DIR, AGENTCTL } = require('./core');
const { focusSession, handleFocusRequest, openFolderWindow } = require('./focus');
const { registerWindow } = require('./windows');

/**
 * @typedef {import('./core').Session} Session
 * @typedef {import('./core').Listener} Listener
 * @typedef {import('./core').Snapshot} Snapshot
 * @typedef {import('./core').Status} Status
 * @typedef {{ kind: 'session', session: Session }
 *   | { kind: 'port', port: Listener, parentKey: string }
 *   | { kind: 'summary', session: Session }
 *   | { kind: 'activity', session: Session }
 *   | { kind: 'context', session: Session }
 *   | { kind: 'git', session: Session }
 *   | { kind: 'idle', sessions: Session[] }} Node
 */

/** @type {Record<Status, { icon: string, color?: string, label: string }>} */
const STATUS_META = {
  waiting: { icon: 'bell-dot', color: 'charts.yellow', label: 'needs input' },
  error: { icon: 'error', color: 'charts.red', label: 'error' },
  working: { icon: 'sync~spin', color: 'charts.blue', label: 'working' },
  done: { icon: 'pass-filled', color: 'charts.green', label: 'done' },
  idle: { icon: 'circle-outline', label: 'idle' },
  untracked: { icon: 'question', label: 'no status yet' },
};

const HOST_LABEL = {
  iterm: 'iTerm',
  'vscode-terminal': 'VS Code terminal',
  'vscode-panel': 'VS Code panel',
  'claude-desktop': 'Claude app',
  other: 'terminal',
};

/** @param {number | undefined} sec unix seconds */
function ago(sec) {
  if (!sec) return '';
  const d = Math.max(0, Math.floor(Date.now() / 1000) - sec);
  if (d < 60) return `${d}s`;
  if (d < 3600) return `${Math.floor(d / 60)}m`;
  if (d < 86400) return `${Math.floor(d / 3600)}h`;
  return `${Math.floor(d / 86400)}d`;
}

/** @param {Status} s */
const meta = (s) => STATUS_META[s] ?? STATUS_META.idle;

/** @param {string} text @param {number} max */
const truncate = (text, max) => (text.length > max ? text.slice(0, max - 1) + '…' : text);

/**
 * The line describing a session: what Claude works on during a turn, what it answered after.
 * Mirrors `Session.summary` in core/Sources/AgentCore/Models.swift.
 * @param {Session} s
 */
const summary = (s) =>
  s.status === 'working' || s.status === 'waiting' ? s.lastPrompt : (s.lastResponse ?? s.lastPrompt);

/**
 * MCP tools are named `mcp__<server>__<tool>`. Mirrors `Session.toolLabel` in Models.swift.
 * @param {string} tool
 */
const toolLabel = (tool) => {
  const parts = tool.split('__');
  return parts.length >= 3 && parts[0] === 'mcp' ? `${parts[1]} ${parts.slice(2).join('__')}` : tool;
};

/**
 * The step Claude is on while a turn runs. Mirrors `Session.activity` in Models.swift.
 * @param {Session} s
 */
const activity = (s) => {
  if ((s.status !== 'working' && s.status !== 'waiting') || !s.lastTool) return undefined;
  const label = toolLabel(s.lastTool);
  return s.toolDetail ? `${label} · ${s.toolDetail}` : label;
};

/** @param {string} tool */
function toolIcon(tool) {
  switch (tool) {
    case 'Bash':
      return 'terminal';
    case 'Read':
      return 'file';
    case 'Edit':
    case 'MultiEdit':
    case 'Write':
    case 'NotebookEdit':
      return 'edit';
    case 'Grep':
    case 'Glob':
      return 'search';
    case 'WebFetch':
    case 'WebSearch':
      return 'globe';
    case 'Task':
    case 'Agent':
      return 'organization';
    case 'TodoWrite':
      return 'checklist';
    default:
      return tool.startsWith('mcp__') ? 'extensions' : 'tools';
  }
}

/**
 * Idle or finished for longer than the threshold. Mirrors `Session.isIdle(longerThan:)` in Models.swift.
 * @param {Session} s @param {number} seconds
 */
const isIdleFor = (s, seconds) => {
  if (s.status !== 'idle' && s.status !== 'done') return false;
  const since = s.statusSince ?? s.updatedAt;
  return since != null && Date.now() / 1000 - since > seconds;
};

/** @param {number} n */
const formatTokens = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1000 ? `${Math.floor(n / 1000)}k` : `${n}`);

/**
 * Mirrors `Session.contextPercent` in Models.swift.
 * @param {Session} s
 */
const contextPercent = (s) =>
  s.contextTokens != null && s.contextSize ? Math.min(100, (s.contextTokens * 100) / s.contextSize) : undefined;

/** @param {Session} s */
function contextText(s) {
  const parts = [s.model, s.effort].filter(Boolean);
  const pct = contextPercent(s);
  if (s.contextTokens != null) {
    parts.push(
      pct != null && s.contextSize
        ? `${Math.round(pct)}% (${formatTokens(s.contextTokens)} / ${formatTokens(s.contextSize)})`
        : `${formatTokens(s.contextTokens)} tokens`,
    );
  }
  return parts.join(' · ');
}

/** @param {import('./core').GitStatus} g */
function gitText(g) {
  const parts = [];
  if (g.ahead) parts.push(`↑${g.ahead}`);
  if (g.behind) parts.push(`↓${g.behind}`);
  if (g.stagedCount) parts.push(`${g.stagedCount} staged`);
  if (g.changedCount) parts.push(`${g.changedCount} changed`);
  return parts.length ? parts.join(' · ') : 'No changes';
}

/** @param {string} title @param {string[]} paths @param {number} total */
const fileList = (title, paths, total) =>
  paths.length ? `**${title}**\n\n${paths.map((p) => `- \`${p}\``).join('\n')}${total > paths.length ? `\n- … and ${total - paths.length} more` : ''}\n\n` : '';

/** @param {import('./core').RateLimits | undefined} limits */
function planUsageText(limits) {
  if (!limits) return '';
  const parts = [];
  if (limits.fiveHour) parts.push(`5h ${Math.round(limits.fiveHour.usedPercent)}%`);
  if (limits.sevenDay) parts.push(`week ${Math.round(limits.sevenDay.usedPercent)}%`);
  return parts.length ? `Plan usage: ${parts.join(' · ')}` : '';
}

const HOME = require('os').homedir();

/**
 * Mirrors `Session.displayName` in Models.swift: /rename title, else the folder; for a session started in
 * home or /, the generated title.
 * @param {Session} s
 */
const displayName = (s) => {
  if (s.customTitle) return s.customTitle;
  // Where the session started: cwd follows the agent's `cd`.
  const root = s.rootDir ?? s.cwd;
  const broad = root === '/' || root === '/Users' || root === HOME;
  return broad && s.aiTitle ? s.aiTitle : s.project;
};

/** @param {Session} s */
const folderLabel = (s) => (s.cwd === HOME ? '~' : s.project);

const config = () => vscode.workspace.getConfiguration('agentControl');

/** @implements {vscode.TreeDataProvider<Node>} */
class AgentTree {
  /** @param {'sessions' | 'ports'} mode */
  constructor(mode) {
    this.mode = mode;
    /** @type {Snapshot | undefined} */
    this.snap = undefined;
    this._emitter = new vscode.EventEmitter();
    this.onDidChangeTreeData = this._emitter.event;
  }

  /** @param {Snapshot} snap */
  update(snap) {
    this.snap = snap;
    this._emitter.fire(undefined);
  }

  /** @param {Node} [node] @returns {Node[]} */
  getChildren(node) {
    if (!this.snap) return [];
    if (this.mode === 'ports') {
      if (node) return [];
      // Noise filtering happens in agentctl (ignoredProcesses / hideEphemeralPorts are passed through).
      return this.snap.otherPorts.map((port) => ({ kind: 'port', port, parentKey: 'other' }));
    }
    if (!node) {
      // Already sorted by agentctl: needs-attention first. Long-idle sessions are folded at the end.
      const minutes = Number(config().get('foldIdleAfterMinutes', 60));
      const idle = minutes > 0 ? this.snap.sessions.filter((s) => isIdleFor(s, minutes * 60)) : [];
      /** @type {Node[]} */
      const roots = this.snap.sessions.filter((s) => !idle.includes(s)).map((session) => ({ kind: 'session', session }));
      if (idle.length > 0) roots.push({ kind: 'idle', sessions: idle });
      return roots;
    }
    if (node.kind === 'idle') return node.sessions.map((session) => ({ kind: 'session', session }));
    if (node.kind !== 'session') return [];
    /** @type {Node[]} */
    const children = [];
    if (activity(node.session)) children.push({ kind: 'activity', session: node.session });
    if (summary(node.session)) children.push({ kind: 'summary', session: node.session });
    if (node.session.model || node.session.contextTokens != null) children.push({ kind: 'context', session: node.session });
    if (node.session.git) children.push({ kind: 'git', session: node.session });
    for (const port of node.session.ports) children.push({ kind: 'port', port, parentKey: node.session.key });
    return children;
  }

  /** @param {Node} node */
  getTreeItem(node) {
    if (node.kind === 'session') return sessionItem(node.session);
    if (node.kind === 'idle') {
      const item = new vscode.TreeItem(`Idle (${node.sessions.length})`, vscode.TreeItemCollapsibleState.Collapsed);
      item.id = 'idle-group';
      item.iconPath = new vscode.ThemeIcon('history');
      item.tooltip = 'Sessions idle for longer than agentControl.foldIdleAfterMinutes.';
      return item;
    }
    if (node.kind === 'context') {
      const s = node.session;
      const item = new vscode.TreeItem(contextText(s));
      item.id = `${s.key}/context`;
      const pct = contextPercent(s);
      const color = pct == null ? undefined : pct >= 85 ? 'charts.red' : pct >= 60 ? 'charts.orange' : 'charts.green';
      item.iconPath = new vscode.ThemeIcon('dashboard', color ? new vscode.ThemeColor(color) : undefined);
      item.tooltip =
        s.contextTokens == null
          ? 'Model'
          : s.contextSize
            ? `Context: ${s.contextTokens.toLocaleString()} of ${s.contextSize.toLocaleString()} tokens. Claude Code compacts the conversation when it gets full.`
            : `Context: ${s.contextTokens.toLocaleString()} tokens. The window size shows once a terminal session on this model reports it (status line).`;
      return item;
    }
    if (node.kind === 'git') {
      const g = /** @type {import('./core').GitStatus} */ (node.session.git);
      const item = new vscode.TreeItem(gitText(g));
      item.id = `${node.session.key}/git`;
      item.iconPath = new vscode.ThemeIcon(
        'source-control',
        g.changedCount ? new vscode.ThemeColor('charts.orange') : g.stagedCount ? new vscode.ThemeColor('charts.green') : undefined,
      );
      const md = fileList('Staged', g.staged, g.stagedCount) + fileList('Changes', g.changed, g.changedCount);
      item.tooltip = md ? new vscode.MarkdownString(md) : 'Working tree clean';
      return item;
    }
    if (node.kind === 'activity') {
      const text = activity(node.session) ?? '';
      const item = new vscode.TreeItem(truncate(text, 80));
      item.id = `${node.session.key}/activity`;
      const m = meta(node.session.status);
      item.iconPath = new vscode.ThemeIcon(
        toolIcon(node.session.lastTool ?? ''),
        m.color ? new vscode.ThemeColor(m.color) : undefined,
      );
      item.tooltip = `Now: ${text}`;
      return item;
    }
    if (node.kind === 'summary') {
      const text = summary(node.session) ?? '';
      const isResponse = text === node.session.lastResponse;
      const item = new vscode.TreeItem(truncate(text, 80));
      item.id = `${node.session.key}/summary`;
      item.iconPath = new vscode.ThemeIcon(isResponse ? 'sparkle' : 'comment');
      item.tooltip = `${isResponse ? 'Claude' : 'You'}: ${text}`;
      return item;
    }
    const { port } = node;
    const item = new vscode.TreeItem(`:${port.port}`);
    item.id = `${node.parentKey}/port/${port.pid}/${port.port}`;
    item.description = [port.command, `pid ${port.pid}`, port.viaCwd ? 'same folder' : ''].filter(Boolean).join(' · ');
    item.tooltip = new vscode.MarkdownString(
      [`**${port.command}** listening on \`${port.address}:${port.port}\``, `pid ${port.pid}`, port.cwd ? `cwd \`${port.cwd}\`` : '']
        .filter(Boolean)
        .join('\n\n'),
    );
    item.iconPath = new vscode.ThemeIcon('plug');
    item.contextValue = 'port';
    item.command = { command: 'agentControl.openPort', title: 'Open in Browser', arguments: [node] };
    return item;
  }
}

/** @param {Session} s */
function sessionItem(s) {
  const m = meta(s.status);
  const hasChildren = Boolean(summary(s) || activity(s) || s.model || s.git) || s.contextTokens != null || s.ports.length > 0;
  const item = new vscode.TreeItem(
    displayName(s),
    hasChildren
      ? s.ports.length > 0
        ? vscode.TreeItemCollapsibleState.Expanded
        : vscode.TreeItemCollapsibleState.Collapsed
      : vscode.TreeItemCollapsibleState.None,
  );
  item.id = s.key;
  item.iconPath = new vscode.ThemeIcon(m.icon, m.color ? new vscode.ThemeColor(m.color) : undefined);
  const statusText = s.statusSince ? `${m.label} ${ago(s.statusSince)}` : m.label;
  const ports = s.ports.map((p) => `:${p.port}`).join(' ');
  const folder = displayName(s) !== s.project ? folderLabel(s) : '';
  item.description = [folder, s.branch, statusText, ports, HOST_LABEL[s.host]].filter(Boolean).join(' · ');

  const md = new vscode.MarkdownString(undefined, true);
  md.appendMarkdown(`$(${m.icon.replace('~spin', '')}) **${displayName(s)}** — ${m.label}\n\n`);
  const title = s.customTitle ?? s.aiTitle;
  if (title && title !== displayName(s)) md.appendMarkdown(`_${title}_\n\n`);
  if (s.message) md.appendMarkdown(`> ${s.message}\n\n`);
  if (s.lastPrompt) md.appendMarkdown(`**You:** ${s.lastPrompt}\n\n`);
  if (s.lastResponse) md.appendMarkdown(`**Claude:** ${s.lastResponse}\n\n`);
  const now = activity(s);
  if (now) md.appendMarkdown(`**Now:** ${now}\n\n`);
  const ctx = contextText(s);
  if (ctx) md.appendMarkdown(`**Model:** ${ctx}\n\n`);
  if (s.git) md.appendMarkdown(`**Git:** ${gitText(s.git)}\n\n`);
  md.appendMarkdown(`\`${s.cwd}\`${s.branch ? ` on \`${s.branch}\`` : ''}\n\n`);
  md.appendMarkdown(`${HOST_LABEL[s.host]}${s.tty && s.tty !== '??' ? ` (${s.tty})` : ''} · pid ${s.pid ?? '?'}`);
  if (s.startedAt) md.appendMarkdown(` · started ${ago(s.startedAt)} ago`);
  if (s.status === 'untracked') {
    md.appendMarkdown('\n\n_No hook data: this session started before the status hook was installed._');
  }
  item.tooltip = md;
  item.contextValue = s.pid != null ? 'session.alive' : 'session';
  item.command = { command: 'agentControl.focus', title: 'Focus Terminal', arguments: [{ kind: 'session', session: s }] };
  return item;
}

/** @param {vscode.ExtensionContext} context */
function activate(context) {
  // VSIX extraction may drop the executable bit of the bundled binary.
  try {
    fs.chmodSync(AGENTCTL, 0o755);
  } catch (err) {
    console.error('[agent-control-center] chmod agentctl', err);
  }
  registerWindow(context);

  const sessionsTree = new AgentTree('sessions');
  const portsTree = new AgentTree('ports');
  const sessionsView = vscode.window.createTreeView('agentControl.sessions', { treeDataProvider: sessionsTree });
  const portsView = vscode.window.createTreeView('agentControl.ports', { treeDataProvider: portsTree });

  const statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  statusBar.command = 'workbench.view.extension.agentControl';
  context.subscriptions.push(sessionsView, portsView, statusBar);

  /** @type {Map<string, Status> | undefined} undefined until the first scan, so startup does not notify */
  let lastStatuses;
  let inflight = false;
  let queued = false;
  /** Consecutive failed scans. A reinstall makes a few fail while the folder is being replaced. */
  let failures = 0;
  /** git status runs once per project per scan: at most every 10 s, the last result is kept in between. */
  const GIT_INTERVAL_MS = 10_000;
  let lastGitScan = 0;
  /** @type {Map<string, import('./core').GitStatus | undefined>} */
  let lastGit = new Map();

  /** @param {Snapshot} snap */
  function updateStatusBar(snap) {
    const count = (/** @type {Status} */ st) => snap.sessions.filter((s) => s.status === st).length;
    const working = count('working');
    const waiting = count('waiting');
    const total = snap.sessions.length;
    if (total === 0) {
      statusBar.hide();
      return;
    }
    const parts = [`$(hubot) ${total}`];
    if (working) parts.push(`$(sync~spin) ${working}`);
    if (waiting) parts.push(`$(bell-dot) ${waiting}`);
    statusBar.text = parts.join('  ');
    const usage = planUsageText(snap.rateLimits);
    statusBar.tooltip = `${total} Claude session(s): ${working} working, ${waiting} need input${usage ? `\n${usage}` : ''}`;
    statusBar.backgroundColor = waiting ? new vscode.ThemeColor('statusBarItem.warningBackground') : undefined;
    statusBar.show();
  }

  /** @param {Snapshot} snap */
  function notifyTransitions(snap) {
    const prev = lastStatuses;
    lastStatuses = new Map(snap.sessions.map((s) => [s.key, s.status]));
    // The menu bar app sends native notifications; don't double up.
    // Otherwise only the focused window notifies, so several open VS Code windows don't all pop the same toast.
    if (!prev || snap.menuBarAppRunning || !vscode.window.state.focused) return;
    for (const s of snap.sessions) {
      const before = prev.get(s.key);
      if (before == null || before === s.status) continue;
      if (s.status === 'waiting' && config().get('notifyOnWaiting', true)) {
        vscode.window
          .showWarningMessage(`Claude needs input in ${displayName(s)}${s.message ? `: ${s.message}` : ''}`, 'Focus')
          .then((pick) => pick && focusSession(s));
      } else if (s.status === 'done' && before === 'working' && config().get('notifyOnDone', false)) {
        const reply = s.lastResponse ? `: ${truncate(s.lastResponse, 160)}` : '';
        vscode.window.showInformationMessage(`Claude finished in ${displayName(s)}${reply}`, 'Focus').then((pick) => pick && focusSession(s));
      }
    }
  }

  async function refresh() {
    if (inflight) {
      queued = true;
      return;
    }
    inflight = true;
    try {
      const snap = await snapshot({
        // lsof is the expensive part; skip it while nobody is looking at the sidebar.
        includePorts: sessionsView.visible || portsView.visible,
        // git status is per project and only shown in the sessions view.
        includeGit: sessionsView.visible && Date.now() - lastGitScan >= GIT_INTERVAL_MS,
        ignoredProcesses: config().get('ignoredProcesses', []),
        hideEphemeralPorts: config().get('hideEphemeralPorts', true),
      });
      if (snap.gitScanned) {
        lastGitScan = Date.now();
        lastGit = new Map(snap.sessions.map((s) => [s.key, s.git]));
      } else {
        for (const s of snap.sessions) s.git = lastGit.get(s.key);
      }
      sessionsTree.update(snap);
      portsTree.update(snap);
      updateStatusBar(snap);
      // Shown above the session list.
      sessionsView.message = planUsageText(snap.rateLimits) || undefined;
      notifyTransitions(snap);
      failures = 0;
    } catch (err) {
      console.error('[agent-control-center] refresh failed', err);
      // Report once, and only when it persists.
      if (++failures === 3) {
        const missing = !fs.existsSync(AGENTCTL);
        vscode.window.showErrorMessage(
          missing
            ? 'Agent Control Center was updated: run "Developer: Reload Window" to load the new version.'
            : `Agent Control Center: cannot run agentctl (${err instanceof Error ? err.message : err}). Re-run install.sh.`,
        );
      }
    } finally {
      inflight = false;
      if (queued) {
        queued = false;
        refresh();
      }
    }
  }

  // Polling catches processes and ports; the file watcher makes status changes feel instant.
  let timer = setInterval(refresh, config().get('refreshIntervalMs', 3000));
  context.subscriptions.push({ dispose: () => clearInterval(timer) });

  /** @type {NodeJS.Timeout | undefined} */
  let debounce;
  try {
    fs.mkdirSync(STATUS_DIR, { recursive: true });
    const watcher = fs.watch(STATUS_DIR, (_event, filename) => {
      if (filename === '.focus-request') {
        // The menu bar app (or another window) asks the window owning a session to reveal it.
        handleFocusRequest();
        return;
      }
      clearTimeout(debounce);
      debounce = setTimeout(refresh, 150);
    });
    context.subscriptions.push({ dispose: () => watcher.close() });
  } catch (err) {
    console.error('[agent-control-center] cannot watch', STATUS_DIR, err);
  }

  /** @param {(n: any) => any} fn */
  const onNode = (fn) => (/** @type {any} */ n) => (n ? fn(n) : undefined);

  context.subscriptions.push(
    sessionsView.onDidChangeVisibility(() => sessionsView.visible && refresh()),
    portsView.onDidChangeVisibility(() => portsView.visible && refresh()),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (!e.affectsConfiguration('agentControl')) return;
      clearInterval(timer);
      timer = setInterval(refresh, config().get('refreshIntervalMs', 3000));
      refresh();
    }),
    vscode.commands.registerCommand('agentControl.refresh', refresh),
    vscode.commands.registerCommand(
      'agentControl.focus',
      onNode((/** @type {Node} */ n) => n.kind === 'session' && focusSession(n.session)),
    ),
    vscode.commands.registerCommand(
      'agentControl.openFolder',
      onNode((/** @type {Node} */ n) => n.kind === 'session' && n.session.cwd && openFolderWindow(n.session.cwd)),
    ),
    vscode.commands.registerCommand(
      'agentControl.copyPath',
      onNode((/** @type {Node} */ n) => n.kind === 'session' && vscode.env.clipboard.writeText(n.session.cwd)),
    ),
    vscode.commands.registerCommand(
      'agentControl.openPort',
      onNode((/** @type {Node} */ n) => n.kind === 'port' && vscode.env.openExternal(vscode.Uri.parse(`http://localhost:${n.port.port}`))),
    ),
    vscode.commands.registerCommand(
      'agentControl.stop',
      onNode(async (/** @type {Node} */ n) => {
        if (n.kind !== 'session' || n.session.pid == null) return;
        const ok = await vscode.window.showWarningMessage(
          `Stop the Claude session “${displayName(n.session)}” (pid ${n.session.pid})?`,
          { modal: true },
          'Stop',
        );
        if (ok !== 'Stop') return;
        signal(n.session.pid);
        refresh();
      }),
    ),
    vscode.commands.registerCommand(
      'agentControl.killPort',
      onNode(async (/** @type {Node} */ n) => {
        if (n.kind !== 'port') return;
        const ok = await vscode.window.showWarningMessage(
          `Stop ${n.port.command} (pid ${n.port.pid}) listening on :${n.port.port}?`,
          { modal: true },
          'Stop Process',
        );
        if (ok !== 'Stop Process') return;
        signal(n.port.pid);
        refresh();
      }),
    ),
  );

  refresh();
}

/** @param {number} pid */
function signal(pid) {
  try {
    process.kill(pid, 'SIGTERM');
  } catch (err) {
    vscode.window.showErrorMessage(`Could not stop pid ${pid}: ${err instanceof Error ? err.message : err}`);
  }
}

function deactivate() {}

module.exports = { activate, deactivate };
