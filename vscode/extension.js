// @ts-check
'use strict';

const vscode = require('vscode');
const fs = require('fs');
const { snapshot, STATUS_DIR, AGENTCTL } = require('./core');
const { focusSession, handleFocusRequest, openFolderWindow } = require('./focus');

/**
 * @typedef {import('./core').Session} Session
 * @typedef {import('./core').Listener} Listener
 * @typedef {import('./core').Snapshot} Snapshot
 * @typedef {import('./core').Status} Status
 * @typedef {{ kind: 'session', session: Session }
 *   | { kind: 'port', port: Listener, parentKey: string }
 *   | { kind: 'prompt', session: Session }} Node
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
      // Already sorted by agentctl: needs-attention first.
      return this.snap.sessions.map((session) => ({ kind: 'session', session }));
    }
    if (node.kind !== 'session') return [];
    /** @type {Node[]} */
    const children = [];
    if (node.session.lastPrompt) children.push({ kind: 'prompt', session: node.session });
    for (const port of node.session.ports) children.push({ kind: 'port', port, parentKey: node.session.key });
    return children;
  }

  /** @param {Node} node */
  getTreeItem(node) {
    if (node.kind === 'session') return sessionItem(node.session);
    if (node.kind === 'prompt') {
      const item = new vscode.TreeItem(truncate(node.session.lastPrompt ?? '', 80));
      item.id = `${node.session.key}/prompt`;
      item.iconPath = new vscode.ThemeIcon('comment');
      item.tooltip = node.session.lastPrompt;
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
  const hasChildren = Boolean(s.lastPrompt) || s.ports.length > 0;
  const item = new vscode.TreeItem(
    s.project,
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
  item.description = [s.branch, statusText, ports, HOST_LABEL[s.host]].filter(Boolean).join(' · ');

  const md = new vscode.MarkdownString(undefined, true);
  md.appendMarkdown(`$(${m.icon.replace('~spin', '')}) **${s.project}** — ${m.label}\n\n`);
  if (s.message) md.appendMarkdown(`> ${s.message}\n\n`);
  if (s.lastPrompt) md.appendMarkdown(`**Last prompt:** ${s.lastPrompt}\n\n`);
  if (s.lastTool && s.status === 'working') md.appendMarkdown(`**Last tool:** ${s.lastTool}\n\n`);
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
  /** Show the "agentctl missing" error once, not every 3s. */
  let reportedFailure = false;

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
    statusBar.tooltip = `${total} Claude session(s): ${working} working, ${waiting} need input`;
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
          .showWarningMessage(`Claude needs input in ${s.project}${s.message ? `: ${s.message}` : ''}`, 'Focus')
          .then((pick) => pick && focusSession(s));
      } else if (s.status === 'done' && before === 'working' && config().get('notifyOnDone', false)) {
        vscode.window.showInformationMessage(`Claude finished in ${s.project}`, 'Focus').then((pick) => pick && focusSession(s));
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
        ignoredProcesses: config().get('ignoredProcesses', []),
        hideEphemeralPorts: config().get('hideEphemeralPorts', true),
      });
      sessionsTree.update(snap);
      portsTree.update(snap);
      updateStatusBar(snap);
      notifyTransitions(snap);
      reportedFailure = false;
    } catch (err) {
      console.error('[agent-control-center] refresh failed', err);
      if (!reportedFailure) {
        reportedFailure = true;
        vscode.window.showErrorMessage(`Agent Control Center: cannot run ${AGENTCTL}. Re-run install.sh.`);
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
          `Stop the Claude session in ${n.session.project} (pid ${n.session.pid})?`,
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
