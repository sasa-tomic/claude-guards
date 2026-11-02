#!/bin/sh
# Self-check for subagents.sh: sh monitors/subagents.test.sh
# Fakes the claude process: a sleep holding fd 3 on a temp tasks dir, with a child writing a background task output;
# a HOME with subagent transcripts.
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'kill $fake $serve 2>/dev/null; rm -rf "$t"' EXIT
mkdir -p "$t/tasks" "$t/state" "$t/home/.claude/projects/p/s/subagents"
# shellcheck disable=SC2094 # fd 3 only holds the dir open, the child writes a file inside it
T="$t/tasks" sh -c 'sleep 60 >"$T/bserve.output" & exec sleep 60' 3<"$t/tasks" & fake=$! # its child: a running background task
until serve=$(pgrep -P $fake); do sleep 0.1; done
now=$(date +%s); fail=0
iso() { date -u -d "@$((now - $1))" +%Y-%m-%dT%H:%M:%S.000Z; }
agent() { # id meta-json, transcript jsonl on stdin
  touch "$t/tasks/$1.output.target"; ln -s "$t/tasks/$1.output.target" "$t/tasks/$1.output"
  cat >"$t/home/.claude/projects/p/s/subagents/agent-$1.jsonl"
  printf '%s' "$2" >"$t/home/.claude/projects/p/s/subagents/agent-$1.meta.json"
}
rec() { # type ago message-id content-json [stop_reason]
  printf '{"type":"%s","timestamp":"%s","message":{"id":"%s","stop_reason":%s,"usage":{"output_tokens":7},"content":%s}}\n' \
    "$1" "$(iso "$2")" "$3" "${5:-null}" "$4"
}
use() { printf '[{"type":"tool_use","id":"%s","name":"%s","input":{"command":"%s"}}]' "$1" "$2" "$3"; }
res() { printf '[{"type":"tool_result","tool_use_id":"%s","content":"ok"}]' "$1"; }
bg() { # ago tool-use-id background-task-id: the tool_result of a Bash call started in the background
  printf '{"type":"user","timestamp":"%s","toolUseResult":{"backgroundTaskId":"%s"},"message":{"content":%s}}\n' "$(iso "$1")" "$3" "$(res "$2")"
}
run() { HOME="$t/home" CLAUDE_PID=${1-$fake} sh "$here/subagents.sh" "$t/state"; }
expect() { # description grep-pattern output
  printf '%s\n' "$3" | grep -q -- "$2" || { echo "FAIL $1: want /$2/ in: $3"; fail=1; }
}
reject() {
  printf '%s\n' "$3" | grep -q -- "$2" && { echo "FAIL $1: unwanted /$2/ in: $3"; fail=1; }
}
M='{"description":"migrate","model":"sonnet"}'
{ rec user 700 u0 '"go"'; rec assistant 690 m1 "$(use t1 Bash 'pytest -x')"; rec user 680 u1 "$(res t1)"
  rec assistant 400 m2 '[{"type":"thinking","thinking":"x"}]'; rec assistant 400 m2 "$(use t2 Bash 'sleep 900')"; } |
  agent aslowtool "$M" # m2 is one message logged per content block: its tokens count once
{ rec user 300 u0 '"go"'; rec assistant 290 m1 "$(use t1 Read f)"; rec user 285 u1 "$(res t1)"; } | agent aquiet '{"description":"quiet"}'
{ rec user 100 u0 '"go"'; rec assistant 90 m1 "$(use t1 Edit f)"; rec user 89 u1 "$(res t1)"; } | agent abusy "$M"
{ rec user 5000 u0 '"go"'; rec assistant 4000 m1 '[{"type":"text","text":"done"}]' '"end_turn"'; } | agent aend "$M"
{ rec user 5000 u0 '"go"'; rec assistant 4000 m1 "$(use t1 Bash ls)"; rec user 3900 u1 "$(res t1)"; } | agent astale "$M"
{ rec user 300 u0 '"go"'; rec assistant 290 m1 "$(use t1 Read f)"; } |
  agent anested '{"description":"leaf","model":"haiku","spawnDepth":2,"parentAgentId":"aorch"}'
{ rec user 500 u0 '"go"'; rec assistant 490 m1 "$(use t1 Bash 'python3 -m http.server')"; bg 489 t1 bserve
  rec assistant 480 m2 "$(use t2 Bash 'make')"; bg 479 t2 bdone; touch "$t/tasks/bdone.output"; } |
  agent aheld '{"description":"serve","finished":true}'
{ rec user 5000 u0 '"go"'; rec assistant 490 m1 "$(use t1 Bash 'make')"; bg 489 t1 bdone; } | agent afinished '{"description":"x","finished":true}'
echo 'not json' | agent abroken "$M"
: | agent abadmeta 'not json'
touch "$t/tasks/bshell.output"
out=$(run); code=$?
[ $code = 0 ] || { echo "FAIL exit $code"; fail=1; }
expect "stalled tool call" 'subagent aslowtool ("migrate", sonnet): tool call Bash running 40[0-9]s: sleep 900; transcript .*agent-aslowtool.jsonl' "$out"
expect "digest" 'subagent aslowtool .*running 11m: 2 tool calls (Bash 2), 0 file edits, 14 output tokens; last call 40[0-9]s ago: Bash sleep 900' "$out"
expect "silent model turn, inherited model" 'subagent aquiet ("quiet", inherited model): no transcript activity for 28[0-9]s; last record: user ok' "$out"
expect "nested agent names its parent" 'subagent anested ("leaf", haiku, spawned by subagent aorch): tool call Read running' "$out"
reject "fresh agent is quiet" 'abusy' "$out"
reject "no digest without recent activity" 'astale .*running' "$out"
reject "idle agent (turn ended) is quiet" 'aend' "$out"
reject "finished agent whose background tasks ended" 'afinished' "$out"
expect "finished agent holding a running background task" 'subagent aheld: finished its work but its background task bserve still runs and keeps it alive: python3 -m http.server; transcript .*agent-aheld.jsonl' "$out"
reject "ended background task of a finished agent" 'bdone' "$out"
expect "unreadable transcript" 'subagent abroken ("migrate", sonnet): transcript .*agent-abroken.jsonl unreadable' "$out"
expect "unreadable metadata" 'subagent abadmeta: metadata .*agent-abadmeta.meta.json unreadable' "$out"
reject "shell task outputs are ignored" 'bshell' "$out"
again=$(run)
[ -z "$again" ] || { echo "FAIL repeated reports: $again"; fail=1; }
kill "$serve"; while [ -e /proc/"$serve"/fd/1 ]; do sleep 0.1; done # an unreaped zombie: wait for its output to close
rm "$t/tasks/afinished.output"; ln -s x "$t/tasks/agone.output"
expect "missing transcript" 'subagent agone: transcript agent-agone.jsonl not found' "$(run)"
[ -e "$t/state/aheld.done" ] || { echo "FAIL held agent not done once its background task ended"; fail=1; }
expect "no claude" 'watchdog stopped: CLAUDE_PID is unset' "$(run '')"
run '' >/dev/null && { echo "FAIL unset CLAUDE_PID exits 0"; fail=1; }
expect "dead claude" 'watchdog stopped: claude process 999999999 is gone' "$(run 999999999)"
out=$(run $$); code=$? # no background task yet: the claude process opens its task-output dir lazily
if [ $code != 0 ] || [ -n "$out" ]; then echo "FAIL no tasks dir yet: exit $code, output: $out"; fail=1; fi
[ $fail = 0 ] && echo ok
exit $fail
