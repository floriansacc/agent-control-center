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
fields=$(printf '%s' "$input" | "$JQ" -r '[.session_id // "", .hook_event_name // "", .notification_type // "", .transcript_path // ""] | join("\u001f")' 2>/dev/null) || exit 0
IFS="$(printf '\037')" read -r sid event ntype transcript <<EOF
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

# Context size and model from the transcript's last main-agent API response (subagents write their own
# transcripts). Read from its tail only; lines cut by `tail -c` are skipped by `fromjson?`. The exact window
# size and %, effort and plan limits come from the status line (agent-statusline.sh) where it runs.
ctx=null
case "$event" in
  PreToolUse|Stop|StopFailure|UserPromptSubmit)
    if [ -n "$transcript" ] && [ -r "$transcript" ]; then
      ctx=$(tail -c 262144 "$transcript" 2>/dev/null | grep -F '"usage"' | "$JQ" -cR '
        fromjson? | select(.type == "assistant" and .message.usage != null and .message.model != "<synthetic>")
        | .message.usage as $u
        | { model: .message.model,
            tokens: (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)) }
      ' 2>/dev/null | tail -n 1)
      [ -n "$ctx" ] || ctx=null
    fi ;;
esac

# Session titles: "custom-title" (set with /rename) and "ai-title" (generated), appended to the
# transcript from time to time. They change rarely: only looked up when a turn starts or ends.
titles=null
case "$event" in
  SessionStart|UserPromptSubmit|Stop)
    if [ -n "$transcript" ] && [ -r "$transcript" ]; then
      # Claude Code re-appends the titles regularly: the last 1 MB holds them (and keeps this ~25 ms).
      titles=$(tail -c 1000000 "$transcript" 2>/dev/null | grep -F -e '"type":"custom-title"' -e '"type":"ai-title"' | "$JQ" -cRn '
        [inputs | fromjson? | select(.type == "custom-title" or .type == "ai-title")]
        | { custom: (map(select(.type == "custom-title") | .customTitle) | last),
            ai: (map(select(.type == "ai-title") | .aiTitle) | last) }
      ' 2>/dev/null)
      [ -n "$titles" ] || titles=null
    fi ;;
esac

tmp="$file.$$.tmp"
printf '%s' "$input" | "$JQ" -c \
  --argjson prev "$prev" \
  --argjson ctx "$ctx" \
  --argjson titles "$titles" \
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
  def basename: text | split("/") | last // "";
  # API errors arrive raw, e.g. `400 {"type":"error","error":{"type":"invalid_request_error","message":"prompt is
  # too long: …"}}`: keep only the message ("Prompt is too long: …"). The JSON may be cut off, hence the regex
  # (whose closing quote is optional).
  def readable_error:
    (if type == "object" then (.error.message // .message // tojson)
     elif type == "string" then
       . as $s
       | (index("{")) as $i
       | if $i == null then $s
         else (($s[$i:] | fromjson? | (.error.message? // .message?) | select(type == "string"))
               // ($s | capture("\"message\"\\s*:\\s*\"(?<m>(?:[^\"\\\\]|\\\\.)*)\"?").m
                   | ("\"" + . + "\"" | fromjson?) // .)
               // $s)
         end
     else text end)
    | text | gsub("^\\s+"; "")
    # A bare error code such as "server_error" -> "Server error".
    | if test("^[a-z]+(_[a-z]+)+$") then gsub("_"; " ") else . end
    | (.[0:1] | ascii_upcase) + .[1:];
  # One line about a tool call (input: its tool_input). null when there is nothing worth showing.
  def detail($tool):
    (if $tool == "Bash" then (.description // .command)
     elif ($tool | test("^(Read|Edit|Write|MultiEdit|NotebookEdit)$")) then ((.file_path // .notebook_path) | basename)
     elif $tool == "Grep" or $tool == "Glob" then .pattern
     elif $tool == "WebFetch" then (.url | text | capture("^[a-z]+://(?<h>[^/?#]+)").h? // .url)
     elif $tool == "WebSearch" then .query
     elif $tool == "Task" or $tool == "Agent" then (.description // .subagent_type)
     elif $tool == "TodoWrite" then ([.todos[]? | select(.status == "in_progress") | (.activeForm // .content)] | first)
     elif $tool == "Skill" then (.skill // .command)
     else null end)
    | text | gsub("\\s+"; " ") | gsub("^ +| +$"; "") | .[0:120]
    | if . == "" then null else . end;
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
      # Read by the Control Center window to show the conversation.
      transcript_path: (.transcript_path // $prev.transcript_path),
      message: (
        if $status == "waiting" then (.message // "Waiting for permission")
        elif $status == "error" then ((.error_details // .error) | readable_error | plain | .[0:300] | select(. != "") // null)
        else null end)
    }
  # What Claude answered at the end of the turn. Only the main agent: SubagentStop carries the
  # subagent'"'"'s own reply. A new prompt clears it so it never describes an older turn.
  + (if $event == "Stop" or $event == "StopFailure" then
       ((.last_assistant_message | text | plain) as $r
        | if $r != "" then { last_response: $r[0:300] } else { last_response: null } end)
     elif $event == "UserPromptSubmit" then { last_response: null }
     else {} end)
  # Prompts can carry context the user did not type: the VS Code extension prepends
  # <ide_opened_file>…</ide_opened_file> / <ide_selection>…</ide_selection>, and the desktop app sends
  # <system-reminder>…</system-reminder> (e.g. when a session moves to it). Keep only what the user typed.
  # Whitespace is collapsed first so "." also spans what were newlines.
  + ((if (.prompt | type) == "string" then .prompt else "" end)
      | gsub("\\s+"; " ")
      | gsub("<(ide_[a-z_]+|system-reminder)>.*?</\\1>"; "")
      | gsub("^ +| +$"; "")) as $prompt
  | (if $prompt != "" then { last_prompt: $prompt[0:200] } else {} end)
  + (if $titles != null then
       (if ($titles.custom // "") != "" then { custom_title: $titles.custom } else {} end)
       + (if ($titles.ai // "") != "" then { ai_title: $titles.ai } else {} end)
     else {} end)
  + (if $ctx != null and $ctx.tokens > 0 then { model_id: $ctx.model, context_tokens: $ctx.tokens } else {} end)
  # The step Claude is on, e.g. Bash "Run the tests" or Edit "Theme.swift". Kept while it waits for a
  # permission (that is what it asks about); cleared when a turn starts or ends.
  + (if $event == "PreToolUse" then
       { last_tool: .tool_name, tool_detail: (.tool_name as $tool | (.tool_input // {}) | detail($tool)) }
     elif $event == "UserPromptSubmit" or $event == "Stop" or $event == "StopFailure" or $event == "SessionStart" then
       { last_tool: null, tool_detail: null }
     else {} end)
' > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"
rm -f "$tmp" 2>/dev/null
exit 0
