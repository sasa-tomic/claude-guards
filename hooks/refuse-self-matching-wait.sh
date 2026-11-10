#!/bin/sh
# PreToolUse(Bash): refuse a wait loop conditioned on `pgrep -f`. The pattern also matches the loop's own bash
# command line, so the loop never ends: the job finishes, the CPU idles, and no completion notice arrives.
printf '%s' "$(cat)" | jq -r '.tool_input.command // ""' | tr '\n' ' ' |
  grep -qE "\b(while|until)\b[^;]*\bpgrep[[:space:]]+-[a-z]*f" || exit 0
cat >&2 <<'EOF'
Bash refused: a while/until loop on `pgrep -f PATTERN` matches its own shell, whose command line contains PATTERN,
so it never exits. Wait on the job's PID instead: `tail --pid=PID -f /dev/null` or `while kill -0 PID; do sleep 20; done`.
EOF
exit 2
