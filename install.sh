#!/bin/sh
# Installs (or with --uninstall, removes) the pieces of Agent Control Center.
#
#   ./install.sh                 everything: hook + VS Code extension + menu bar app + agentctl CLI
#   ./install.sh vscode app      only some parts (hook | vscode | app | cli)
#   ./install.sh --uninstall     remove everything
#
# Idempotent. Existing Claude hooks (e.g. iTerm's cc-status) are kept.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
HOOK="$ROOT/hook/agent-status.sh"
CMD="\"$HOOK\""
SETTINGS="$HOME/.claude/settings.json"
EVENTS="SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse Notification PermissionRequest Stop StopFailure SubagentStop"
EXT_ID="local.agent-control-center"
VSIX="$ROOT/dist/agent-control-center.vsix"
APP="$HOME/Applications/Agent Control Center.app"
APP_EXE="AgentControlApp"
CLI="$HOME/.local/bin/agentctl"
BUNDLE_ID="local.agent-control-center"
CODE=$(command -v code || echo "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")

# Names of VS Code profiles that keep their own extension list (`code --install-extension`
# only targets the default profile; profiles sharing the default extensions are skipped).
# Newline-separated so names with spaces survive the `for` loops below.
profiles() {
  storage="$HOME/Library/Application Support/Code/User/globalStorage/storage.json"
  [ -f "$storage" ] || return 0
  jq -r '.userDataProfiles[]? | select(.useDefaultFlags.extensions != true) | .name' "$storage"
}
IFS='
'

update_settings() {
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  tmp="$SETTINGS.tmp.$$"
  jq --arg cmd "$CMD" --arg events "$EVENTS" "$1" "$SETTINGS" > "$tmp"
  if cmp -s "$tmp" "$SETTINGS"; then
    rm -f "$tmp"
    return
  fi
  cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
  mv "$tmp" "$SETTINGS"
}

build_core() {
  echo "→ Building Swift core (agentctl + menu bar app)"
  swift build -c release --package-path "$ROOT/core"
  BIN_DIR=$(swift build -c release --package-path "$ROOT/core" --show-bin-path)
}

install_hook() {
  echo "→ Registering hook in $SETTINGS"
  chmod +x "$HOOK"
  update_settings '
    reduce ($events | split(" "))[] as $e (.;
      .hooks[$e] = ((.hooks[$e] // [])
        | if any(.[]; any(.hooks[]?; .command == $cmd)) then .
          else . + [{ hooks: [{ type: "command", command: $cmd, timeout: 5 }] }] end))'
}

install_vscode() {
  echo "→ Packaging VS Code extension"
  mkdir -p "$ROOT/vscode/bin" "$ROOT/dist"
  cp "$BIN_DIR/agentctl" "$ROOT/vscode/bin/agentctl"
  chmod +x "$ROOT/vscode/bin/agentctl"
  (cd "$ROOT/vscode" && npx --yes @vscode/vsce@3.2.1 package --no-dependencies --allow-missing-repository --skip-license -o "$VSIX")

  echo "→ Installing extension (default profile + every named profile)"
  "$CODE" --install-extension "$VSIX" --force
  for profile in $(profiles); do
    "$CODE" --install-extension "$VSIX" --force --profile "$profile"
  done
}

install_cli() {
  echo "→ Installing agentctl to $CLI"
  mkdir -p "$(dirname "$CLI")"
  # A copy, not a symlink: it must survive `swift package clean`.
  cp "$BIN_DIR/agentctl" "$CLI.tmp"
  chmod +x "$CLI.tmp"
  mv -f "$CLI.tmp" "$CLI"
  case ":$PATH:" in
    *":$(dirname "$CLI"):"*) ;;
    *) echo "  $(dirname "$CLI") is not on your PATH; add it to use \`agentctl\` directly." ;;
  esac
}

install_app() {
  echo "→ Bundling $APP"
  pkill -x "$APP_EXE" 2>/dev/null || true
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN_DIR/$APP_EXE" "$APP/Contents/MacOS/$APP_EXE"
  # TODO: add an AppIcon.icns (only visible in Finder / Login Items; the app lives in the menu bar).
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Agent Control Center</string>
  <key>CFBundleDisplayName</key><string>Agent Control Center</string>
  <key>CFBundleExecutable</key><string>$APP_EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Agent Control Center selects the iTerm tab of the Claude session you click.</string>
</dict>
</plist>
PLIST
  # Ad-hoc signature: required for notifications and the login item on recent macOS.
  codesign --force --sign - "$APP"
  open "$APP"
}

if [ "${1:-}" = "--uninstall" ]; then
  update_settings '
    .hooks |= (with_entries(.value |= (map(.hooks |= map(select(.command != $cmd))) | map(select(.hooks | length > 0))))
               | with_entries(select(.value | length > 0)))'
  "$CODE" --uninstall-extension "$EXT_ID" || true
  for profile in $(profiles); do
    "$CODE" --uninstall-extension "$EXT_ID" --profile "$profile" || true
  done
  if [ -d "$APP" ]; then
    pkill -x "$APP_EXE" 2>/dev/null || true
    "$APP/Contents/MacOS/$APP_EXE" --unregister-login-item 2>/dev/null || true
    rm -rf "$APP"
  fi
  rm -f "$CLI"
  rm -rf "$HOME/.claude/agent-status"
  echo "Uninstalled. Reload VS Code windows to remove the sidebar."
  exit 0
fi

[ $# -gt 0 ] || set -- hook vscode app cli
for part in "$@"; do
  case "$part" in
    hook|vscode|app|cli) ;;
    *) echo "unknown part: $part (expected hook, vscode, app, cli)" >&2; exit 64 ;;
  esac
done
for part in "$@"; do
  if [ "$part" != hook ]; then
    build_core
    break
  fi
done
for part in "$@"; do
  case "$part" in
    hook) install_hook ;;
    vscode)
      install_vscode
      echo "Run 'Developer: Reload Window' in open VS Code windows."
      ;;
    app)
      install_app
      echo "Agent Control Center is in the menu bar (and starts at login)."
      ;;
    cli) install_cli ;;
  esac
done
echo "Done."
