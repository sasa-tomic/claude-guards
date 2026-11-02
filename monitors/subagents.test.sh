#!/bin/sh
# Self-check for subagents.sh: sh monitors/subagents.test.sh
# Fakes the claude process: a sleep holding fd 3 on a temp tasks dir, a HOME with subagent transcripts.
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'kill $fake 2>/dev/null; rm -rf "$t"' EXIT
mkdir -p "$t/tasks" "$t/state" "$t/home/.claude/projects/p/s/subagents"
sleep 60 3<"$t/tasks" & fake=$!
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
{ rec user 5000 u0 '"go"'; } | agent afinished '{"description":"x","finished":true}'
echo 'not json' | agent abroken "$M"
: | agent abadmeta 'not json'
touch "$t/tasks/bshell.output"
out=$(run); code=$?
[ $code = 0 ] || { echo "FAIL exit $code"; fail=1; }
expect "stalled tool call" 'subagent aslowtool ("migrate", sonnet): tool call Bash running 40[0-9]s: sleep 900; transcript .*agent-aslowtool.jsonl' "$out"
expect "digest" 'subagent aslowtool .*running 11m: 2 tool calls (Bash 2), 0 file edits, 14 output tokens; last call 40[0-9]s ago: Bash sleep 900' "$out"
expect "silent model turn, inherited model" 'subagent aquiet ("quiet", inherited model): no transcript activity for 28[0-9]s; last record: user ok' "$out"
reject "fresh agent is quiet" 'abusy' "$out"
reject "no digest without recent activity" 'astale .*running' "$out"
reject "idle agent (turn ended) is quiet" 'aend' "$out"
reject "finished agent" 'afinished' "$out"
expect "unreadable transcript" 'subagent abroken ("migrate", sonnet): transcript .*agent-abroken.jsonl unreadable' "$out"
expect "unreadable metadata" 'subagent abadmeta: metadata .*agent-abadmeta.meta.json unreadable' "$out"
reject "shell task outputs are ignored" 'bshell' "$out"
again=$(run)
[ -z "$again" ] || { echo "FAIL repeated reports: $again"; fail=1; }
rm "$t/tasks/afinished.output"; ln -s x "$t/tasks/agone.output"
expect "missing transcript" 'subagent agone: transcript agent-agone.jsonl not found' "$(run)"
expect "no claude" 'watchdog stopped: CLAUDE_PID is unset' "$(run '')"
run '' >/dev/null && { echo "FAIL unset CLAUDE_PID exits 0"; fail=1; }
expect "dead claude" 'watchdog stopped: claude process 999999999 is gone' "$(run 999999999)"
expect "no tasks dir" "watchdog stopped: claude process $$ holds no task-output dir" "$(run $$)"
[ $fail = 0 ] && echo ok
exit $fail
