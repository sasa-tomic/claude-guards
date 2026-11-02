#!/bin/sh
# One pass of the subagent watchdog (monitors/monitors.json loops it): report each background subagent of this Claude Code
# process that stalls, so the main agent corrects or stops it within minutes instead of finding a 2h stall by chance.
# Each stdout line reaches the main agent as a notification; <statedir> remembers what was already reported.
# Discovery: the claude process ($CLAUDE_PID) holds its task-output dir open once its first background task starts
# (none before: nothing to watch yet); every background subagent of any depth has an <agentId>.output symlink there,
# and its transcript is ~/.claude/projects/**/agent-<agentId>.jsonl.
# stall: seconds a tool call or a silent model turn may run before it is reported (p99 of 4.7k measured gaps: ~180s).
# digest: seconds between progress summaries per subagent active within that window.
stall=180 digest=600
state=${1:?usage: subagents.sh <statedir>}
die() { echo "subagent watchdog stopped: $*"; exit 1; }
[ -n "$CLAUDE_PID" ] || die "CLAUDE_PID is unset; it must run as a Claude Code plugin monitor"
kill -0 "$CLAUDE_PID" 2>/dev/null || die "claude process $CLAUDE_PID is gone"
tasks=$(for fd in /proc/"$CLAUDE_PID"/fd/*; do readlink "$fd"; done | grep -m1 '/tasks$')
[ -n "$tasks" ] || exit 0
once() { # key message: print a report line the first time key is seen for subagent $id
  [ -e "$state/$id.$1" ] && return
  echo "subagent $id${who:+ ($who)}: $2"
  touch "$state/$id.$1"
}
for out in "$tasks"/a*.output; do
  [ -L "$out" ] || continue # bash/monitor outputs are regular files; only subagent outputs are symlinks
  id=$(basename "$out" .output) who=
  [ -e "$state/$id.done" ] && continue
  log=$(find "$HOME/.claude/projects" -name "agent-$id.jsonl" -print -quit)
  [ -n "$log" ] || { once missing "transcript agent-$id.jsonl not found under ~/.claude/projects"; continue; }
  meta=${log%.jsonl}.meta.json
  m=$(jq -r 'if .finished or .stoppedByUser then "finished" else "\"\(.description)\", \(.model // "inherited model")\(.parentAgentId | if . then ", spawned by subagent \(.)" else "" end)" end' "$meta" 2>&1) ||
    { once unreadable "metadata $meta unreadable: $m"; continue; }
  if [ "$m" = finished ]; then # it is done only once its own background tasks end: until then they keep it alive
    : "${running=$(for c in $(pgrep -P "$CLAUDE_PID"); do for fd in /proc/"$c"/fd/*; do readlink "$fd"; done; done 2>/dev/null)}" # a background task is a child of claude holding its .output open; 2>/dev/null: a child exiting mid-scan
    bgs=$(jq -r -s '(map(.message.content | arrays | .[] | select(.type == "tool_use") | {key: .id, value: .input.command})
      | from_entries) as $cmd | .[] | (.toolUseResult | objects | .backgroundTaskId // empty) as $b
      | "\($b)\t\($cmd[.message.content[0].tool_use_id] // "" | tostring | gsub("\\s+"; " ")[0:150])"' "$log" 2>&1) ||
      { once unreadable "transcript $log unreadable: $bgs"; continue; }
    held=0
    while IFS="$(printf '\t')" read -r b c; do
      printf '%s\n' "$running" | grep -qxF "$tasks/$b.output" || continue
      held=1; once "held-$b" "finished its work but its background task $b still runs and keeps it alive: $c; transcript $log"
    done <<EOT
$bgs
EOT
    [ $held = 1 ] || touch "$state/$id.done"
    continue
  fi
  who=$m
  report=$(jq -r -s --argjson now "$(date +%s)" --argjson stall $stall --argjson digest $digest '
    def ts: .timestamp[0:19] + "Z" | fromdate;
    def cmd: (.input.command // .input.file_path // .input.pattern // .input.description // "") | tostring | gsub("\\s+"; " ")[0:150];
    [.[] | select(.type == "assistant" or .type == "user")] as $r
    | ($r[0] | ts) as $start | ($r[-1] | ts) as $last
    | [$r[] | select(.type == "assistant") | ts as $t | .message.content[] | select(.type == "tool_use") | . + {t: $t}] as $calls
    | [$r[] | select(.type == "user") | .message.content | arrays | .[] | select(.type == "tool_result") | .tool_use_id] as $done
    | ([$calls[] | select(.id as $i | $done | index($i) | not)] | last) as $open
    | select($r[-1].message.stop_reason != "end_turn") # idle: its turn ended, it waits for a message
    | if $open then
        select($now - $open.t >= $stall)
        | "tool-\($open.id)\ttool call \($open.name) running \($now - $open.t)s: \($open | cmd)"
      elif $now - $last >= $stall then
        "quiet-\($last)\tno transcript activity for \($now - $last)s; last record: \($r[-1] | .type) \($r[-1].message.content | if type == "string" then . else map(.text // .content // .thinking // .name // "" | tostring) | join(" ") end | gsub("\\s+"; " ")[0:150])"
      else empty end,
      ((($now - $start) / $digest | floor) as $k | select($k >= 1 and $now - $last < $digest) # a stalled agent is reported above, once
        | ([$r[] | select(.type == "assistant") | {key: .message.id, value: (.message.usage.output_tokens // 0)}] | from_entries | add // 0) as $tok
        | "digest-\($k)\trunning \(($now - $start) / 60 | floor)m: \($calls | length) tool calls (\($calls | group_by(.name) | map("\(.[0].name) \(length)") | join(", "))), \([$calls[] | select(.name | IN("Write", "Edit", "MultiEdit", "NotebookEdit"))] | length) file edits, \($tok) output tokens; last call \($calls | last | if . then "\($now - .t)s ago: \(.name) \(cmd)" else "none" end)")
  ' "$log" 2>&1) || { once unreadable "transcript $log unreadable: $report"; continue; }
  printf '%s\n' "$report" | while IFS="$(printf '\t')" read -r key msg; do
    [ -n "$key" ] || continue
    once "$key" "$msg; transcript $log"
  done
done
