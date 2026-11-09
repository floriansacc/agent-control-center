// @ts-check
'use strict';

// Registers this VS Code window (extension host pid, folders, terminal shell pids) so agentctl can
// raise the exact window owning a session. Read by core/Sources/AgentCore/VSCodeWindows.swift.

const fs = require('fs');
const path = require('path');
const vscode = require('vscode');
const { STATUS_DIR } = require('./core');

const WINDOWS_DIR = path.join(STATUS_DIR, '.windows');
// Every extension in a window shares one extension host process, the Claude extension included,
// so Claude panel sessions are direct children of this pid.
const FILE = path.join(WINDOWS_DIR, `${process.pid}.json`);

async function write() {
  const pids = await Promise.all(vscode.window.terminals.map((t) => t.processId));
  const entry = {
    extHostPid: process.pid,
    roots: (vscode.workspace.workspaceFolders ?? []).map((f) => f.uri.fsPath),
    workspaceFile: vscode.workspace.workspaceFile?.scheme === 'file' ? vscode.workspace.workspaceFile.fsPath : undefined,
    terminalShellPids: pids.filter((p) => p != null),
  };
  try {
    fs.mkdirSync(WINDOWS_DIR, { recursive: true });
    const tmp = `${FILE}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(entry));
    fs.renameSync(tmp, FILE);
  } catch (err) {
    console.error('[agent-control-center] window registry', err);
  }
}

/** @param {vscode.ExtensionContext} context */
function registerWindow(context) {
  write();
  context.subscriptions.push(
    vscode.workspace.onDidChangeWorkspaceFolders(write),
    vscode.window.onDidOpenTerminal(write),
    vscode.window.onDidCloseTerminal(write),
    { dispose: unregisterWindow },
  );
}

function unregisterWindow() {
  try {
    fs.unlinkSync(FILE);
  } catch {
    // Already gone; agentctl also prunes entries of dead extension hosts.
  }
}

module.exports = { registerWindow };
