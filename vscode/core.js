// @ts-check
'use strict';

// Thin bridge to the bundled `agentctl` binary (core/Sources/agentctl). All scanning, port
// attribution and out-of-window focusing lives in the Swift AgentCore; this file only calls it.

const path = require('path');
const os = require('os');
const fs = require('fs');
const { execFile } = require('child_process');

const AGENTCTL = path.join(__dirname, 'bin', 'agentctl');
const STATUS_DIR = process.env.AGENT_STATUS_DIR || path.join(os.homedir(), '.claude', 'agent-status');
const FOCUS_REQUEST = path.join(STATUS_DIR, '.focus-request');

// Mirrors core/Sources/AgentCore/Models.swift — keep in sync.
/**
 * @typedef {{ port: number, address: string, pid: number, command: string, cwd?: string, viaCwd?: boolean }} Listener
 * @typedef {'working'|'waiting'|'error'|'done'|'idle'|'untracked'} Status
 * @typedef {'iterm'|'vscode-terminal'|'vscode-panel'|'other'} Host
 * @typedef {{
 *   key: string, sessionId?: string, pid?: number, cwd: string, project: string, branch?: string,
 *   status: Status, statusSince?: number, updatedAt?: number, startedAt?: number,
 *   lastPrompt?: string, lastResponse?: string, lastTool?: string, message?: string,
 *   host: Host, tty?: string, itermSessionId?: string, statusFile?: string, ports: Listener[]
 * }} Session
 * @typedef {{ sessions: Session[], otherPorts: Listener[], portsScanned: boolean, scannedAt: number, menuBarAppRunning: boolean }} Snapshot
 */

/**
 * @param {string[]} args
 * @returns {Promise<{ code: number, stdout: string, stderr: string }>}
 */
function agentctl(args, timeout = 15_000) {
  return new Promise((resolve) => {
    const run = (/** @type {boolean} */ retry) =>
      execFile(AGENTCTL, args, { timeout, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
        // Reinstalling the extension re-extracts the VSIX over this folder, which drops the executable bit.
        if (retry && err && /** @type {NodeJS.ErrnoException} */ (err).code === 'EACCES') {
          try {
            fs.chmodSync(AGENTCTL, 0o755);
            return run(false);
          } catch {
            // Fall through and report the original error.
          }
        }
        const code = err ? (typeof err.code === 'number' ? err.code : -1) : 0;
        resolve({ code, stdout: String(stdout), stderr: String(stderr || (err && !stdout ? err.message : '')) });
      });
    run(true);
  });
}

/**
 * @param {{ includePorts: boolean, ignoredProcesses: string[], hideEphemeralPorts: boolean }} opts
 * @returns {Promise<Snapshot>}
 */
async function snapshot({ includePorts, ignoredProcesses, hideEphemeralPorts }) {
  const args = ['snapshot', '--ignore', ignoredProcesses.join(',')];
  if (!includePorts) args.push('--no-ports');
  if (!hideEphemeralPorts) args.push('--show-ephemeral');
  const res = await agentctl(args);
  if (res.code !== 0) throw new Error(`agentctl snapshot failed (${res.code}): ${res.stderr.trim()}`);
  return JSON.parse(res.stdout);
}

/**
 * pid followed by its ancestors, nearest first.
 * @param {number} pid
 * @returns {Promise<number[]>}
 */
async function ancestors(pid) {
  const res = await agentctl(['ancestors', String(pid)]);
  return res.code === 0 ? JSON.parse(res.stdout) : [];
}

/**
 * Focus a session outside this window (iTerm tab, or another VS Code window).
 * @param {Session} s
 * @returns {Promise<'focused'|'automation-denied'|'not-found'>}
 */
async function focusExternal(s) {
  const target = s.sessionId ?? (s.pid != null ? String(s.pid) : s.key);
  const res = await agentctl(['focus', target]);
  const out = res.stdout.trim();
  return out === 'focused' || out === 'automation-denied' ? out : 'not-found';
}

module.exports = { snapshot, ancestors, focusExternal, STATUS_DIR, FOCUS_REQUEST, AGENTCTL };
