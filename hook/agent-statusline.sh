#!/bin/sh
# Claude Code status line: prints one line under the prompt (model, effort, context, plan usage) and
# records the same data for Agent Control Center in ~/.claude/agent-status/.statusline/<session_id>.json.
#
# It writes its own file instead of the hook's status file: both run concurrently, and a read-modify-write
# race on one file could undo a status change. Claude Code runs the status line in terminal sessions only
# (not in the VS Code panel or the desktop app); those get model and tokens from the hook instead.
#
# Must stay fast (it runs after every message) and must never fail loudly.

DIR="${AGENT_STATUS_DIR:-$HOME/.claude/agent-status}/.statusline"
JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=$(command -v jq) || exit 0

input=$(cat)
sid=$(printf '%s' "$input" | "$JQ" -r '.session_id // ""' 2>/dev/null)
case "$sid" in ''|*/*|.*) ;; *)
  if mkdir -p "$DIR" 2>/dev/null; then
    tmp="$DIR/$sid.json.$$.tmp"
    printf '%s' "$input" | "$JQ" -c --arg now "$(date +%s)" '{
        session_id,
        updated_at: ($now | tonumber),
        model_id: .model.id,
        model: .model.display_name,
        effort: .effort.level,
        context_tokens: .context_window.total_input_tokens,
        context_size: .context_window.context_window_size,
        context_percent: .context_window.used_percentage,
        rate_limits: .rate_limits
      }' > "$tmp" 2>/dev/null && mv -f "$tmp" "$DIR/$sid.json"
    rm -f "$tmp" 2>/dev/null
  fi ;;
esac

# The visible line, e.g. "Opus 5.5 · high · ctx 62% 124k/200k · 5h 34% · week 61%".
# Claude Code dims the status line; colors only mark the context / usage levels.
printf '%s' "$input" | "$JQ" -r '
  def k: if . >= 1000000 then "\((. / 100000 | floor) / 10)M" elif . >= 1000 then "\(. / 1000 | floor)k" else tostring end;
  def level($p): if $p >= 85 then "\u001b[31m" elif $p >= 60 then "\u001b[33m" else "\u001b[32m" end;
  def pct($p): "\(level($p))\($p | floor)%\u001b[0m";
  [ .model.display_name,
    .effort.level,
    (.context_window as $c | if $c.used_percentage != null
       then "ctx \(pct($c.used_percentage)) \($c.total_input_tokens | k)/\($c.context_window_size | k)"
       else empty end),
    (.rate_limits.five_hour.used_percentage | if . != null then "5h \(pct(.))" else empty end),
    (.rate_limits.seven_day.used_percentage | if . != null then "week \(pct(.))" else empty end)
  ] | map(select(. != null and . != "")) | join(" · ")
' 2>/dev/null
exit 0
