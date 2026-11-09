// @ts-check
'use strict';

// Focus handling that needs the VS Code API (this window's terminals / Claude panel).
// Anything outside this window is delegated to agentctl.

const fs = require('fs/promises');
const path = require('path');
const { execFile } = require('child_process');
const vscode = require('vscode');
const { ancestors, focusExternal, FOCUS_REQUEST } = require('./core');

/** @typedef {import('./core').Session} Session */

/** Focus requests older than this are ignored (e.g. left over from a closed window). */
const FOCUS_REQUEST_TTL_MS = 5000;

/**
 * Shows this window's terminal that runs the given claude pid.
 * @param {number | undefined} pid
 */
async function showTerminalFor(pid) {
  if (pid == null) return false;
  const chain = new Set(await ancestors(pid));
  for (const t of vscode.window.terminals) {
    const shellPid = await t.processId;
    if (shellPid != null && chain.has(shellPid)) {
      t.show(false);
      return true;
    }
  }
  return false;
}

/**
 * Handles a session that lives in this window. Returns false when it is not ours.
 * @param {{ host: string, pid?: number | null, sessionId?: string | null }} s
 */
async function focusInThisWindow(s) {
  if (s.pid == null) return false;
  if (s.host === 'vscode-terminal') return showTerminalFor(s.pid);
  if (s.host === 'vscode-panel') {
    // Claude panel processes are children of their window's extension host, which is our process.
    // (Matching by folder is ambiguous: two windows can contain the same folder.)
    if (!(await ancestors(s.pid)).includes(process.pid)) return false;
    // Reveals the tab / sidebar already holding this session. Never use `claude-vscode.focus`:
    // when no Claude panel is visible it falls back to opening a new conversation.
    if (s.sessionId) await vscode.commands.executeCommand('claude-vscode.editor.open', s.sessionId);
    return true;
  }
  return false;
}

/**
 * Opens (or focuses, when already open) the VS Code window for a folder.
 * @param {string} folder
 */
function openFolderWindow(folder) {
  const cli = path.join(vscode.env.appRoot, 'bin', 'code');
  // Inherited VSCODE_* / ELECTRON_* variables would route the CLI back to this window.
  const env = Object.fromEntries(
    Object.entries(process.env).filter(([k]) => !k.startsWith('VSCODE_') && !k.startsWith('ELECTRON_')),
  );
  execFile(cli, [folder], { env }, (err) => {
    if (err) vscode.window.showErrorMessage(`Could not open ${folder}: ${err.message}`);
  });
}

/** @param {Session} s */
async function focusSession(s) {
  if (await focusInThisWindow(s)) return;
  const result = await focusExternal(s);
  if (result === 'automation-denied') {
    vscode.window.showErrorMessage(
      'Allow VS Code to control iTerm: System Settings → Privacy & Security → Automation → Visual Studio Code → iTerm.',
    );
  } else if (result === 'not-found') {
    vscode.window.showWarningMessage(`Could not locate the terminal for ${s.project}.`);
  }
}

/**
 * Called when agentctl (menu bar app, or another window) asks the window owning a session to reveal it.
 * Every window receives it; only the one that has the terminal / folder acts.
 */
async function handleFocusRequest() {
  /** @type {{ pid?: number | null, sessionId?: string | null, cwd: string, host: string, at: number }} */
  let req;
  try {
    req = JSON.parse(await fs.readFile(FOCUS_REQUEST, 'utf8'));
  } catch {
    return;
  }
  if (!req || Date.now() - Number(req.at) > FOCUS_REQUEST_TTL_MS) return;
  await focusInThisWindow(req);
}

module.exports = { focusSession, handleFocusRequest, openFolderWindow };
