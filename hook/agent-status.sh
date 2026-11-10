#!/bin/sh
# Claude Code hook: records each session's live status as one JSON file per session,
# read by the Agent Control Center VS Code extension.
#
# Must stay fast (it runs on every tool call), must never print to stdout
# (SessionStart / UserPromptSubmit stdout is injected into Claude's context),
# and must always exit 0 so it can never block a session.

DIR="${AGENT_STATUS_DIR:-$HOME/.claude/agent-status}"
JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=$(command -v jq) || exit 0

input=$(cat)
# \037 (unit separator) is not IFS whitespace, so empty fields are preserved.
fields=$(printf '%s' "$input" | "$JQ" -r '[.session_id // "", .hook_event_name // "", .notification_type // ""] | join("\u001f")' 2>/dev/null) || exit 0
IFS="$(printf '\037')" read -r sid event ntype <<EOF
$fields
EOF
[ -n "$sid" ] || exit 0
case "$sid" in */*|.*) exit 0 ;; esac

mkdir -p "$DIR" 2>/dev/null || exit 0
file="$DIR/$sid.json"

case "$event" in
  SessionEnd)
    rm -f "$file"
    exit 0 ;;
  SessionStart)
    status=idle ;;
  UserPromptSubmit|PreToolUse|PostToolUse|SubagentStop)
    status=working ;;
  PermissionRequest)
    status=waiting ;;
  Notification)
    # "idle_prompt" fires ~60s after Claude finished: the session is done, not blocked.
    [ "$ntype" = "idle_prompt" ] && exit 0
    status=waiting ;;
  Stop)
    status=done ;;
  StopFailure)
    status=error ;;
  *)
    exit 0 ;;
esac

prev='{}'
prevpid=""
if [ -f "$file" ]; then
  prevpid=$("$JQ" -r 'if type == "object" then (.pid // "") else error end' "$file" 2>/dev/null) && prev=$(cat "$file")
fi

# Find the owning claude process. Fast path: the pid recorded earlier is still a claude process.
pid=""
tty=""
if [ -n "$prevpid" ]; then
  set -- $(ps -o tty=,comm= -p "$prevpid" 2>/dev/null)
  case "$*" in *' claude'|*/claude) pid=$prevpid; tty=$1 ;; esac
fi
if [ -z "$pid" ]; then
  # Walk up from our parent: claude -> [sh -c] -> this script.
  p=$PPID
  i=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ $i -lt 6 ]; do
    line=$(ps -o ppid=,tty=,comm= -p "$p" 2>/dev/null) || break
    set -- $line
    pp=$1
    t=$2
    shift 2
    comm="$*"
    if [ "${comm##*/}" = "claude" ]; then
      pid=$p
      tty=$t
      break
    fi
    p=$pp
    i=$((i + 1))
  done
fi

tmp="$file.$$.tmp"
printf '%s' "$input" | "$JQ" -c \
  --argjson prev "$prev" \
  --arg status "$status" \
  --arg event "$event" \
  --arg now "$(date +%s)" \
  --arg pid "$pid" \
  --arg tty "$tty" \
  --arg termProgram "${TERM_PROGRAM:-}" \
  --arg itermSessionId "${ITERM_SESSION_ID:-}" \
  --arg entrypoint "${CLAUDE_CODE_ENTRYPOINT:-}" \
  --arg projectDir "${CLAUDE_PROJECT_DIR:-}" '
  # Markdown reply -> one plain line: drops fences, heading / list / quote markers, link targets,
  # bold and code marks. Underscores are kept (identifiers such as last_prompt).
  def plain:
    gsub("```[^\n]*\n"; "")
    | gsub("(^|\n)[ \t]*(#{1,6}|[-*+>]|[0-9]+\\.)[ \t]+"; "\n")
    | gsub("\\[(?<t>[^\\]]*)\\]\\([^)]*\\)"; "\(.t)")
    | gsub("\\*\\*|`"; "")
    | gsub("\\s+"; " ")
    | gsub("^ +| +$"; "");
  def text: if type == "string" then . elif . == null then "" else tostring end;
  ($now | tonumber) as $t
  | $prev + {
      session_id: .session_id,
      cwd: (.cwd // $prev.cwd),
      # Stable project root: .cwd follows every `cd` the agent makes.
      project_dir: (if $projectDir != "" then $projectDir else ($prev.project_dir // .cwd // $prev.cwd) end),
      status: $status,
      event: $event,
      updated_at: $t,
      started_at: ($prev.started_at // $t),
      status_since: (if $prev.status == $status then ($prev.status_since // $t) else $t end),
      pid: (if $pid != "" then ($pid | tonumber) else $prev.pid end),
      tty: (if $tty != "" then $tty else $prev.tty end),
      term_program: $termProgram,
      iterm_session_id: $itermSessionId,
      entrypoint: $entrypoint,
      message: (
        if $status == "waiting" then (.message // "Waiting for permission")
        elif $status == "error" then ((.error_details // .error) | text | plain | .[0:300] | select(. != "") // null)
        else null end)
    }
  # What Claude answered at the end of the turn. Only the main agent: SubagentStop carries the
  # subagent'"'"'s own reply. A new prompt clears it so it never describes an older turn.
  + (if $event == "Stop" or $event == "StopFailure" then
       ((.last_assistant_message | text | plain) as $r
        | if $r != "" then { last_response: $r[0:300] } else { last_response: null } end)
     elif $event == "UserPromptSubmit" then { last_response: null }
     else {} end)
  # The VS Code extension prepends context such as <ide_opened_file>…</ide_opened_file> and
  # <ide_selection>…</ide_selection> to every prompt; keep only what the user typed.
  # Whitespace is collapsed first so "." also spans what were newlines.
  + ((if (.prompt | type) == "string" then .prompt else "" end)
      | gsub("\\s+"; " ")
      | gsub("<(ide_[a-z_]+)>.*?</\\1>"; "")
      | gsub("^ +| +$"; "")) as $prompt
  | (if $prompt != "" then { last_prompt: $prompt[0:200] } else {} end)
  + (if $event == "PreToolUse" then { last_tool: .tool_name } else {} end)
' > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"
rm -f "$tmp" 2>/dev/null
exit 0
