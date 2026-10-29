#!/bin/sh
# PreToolUse(Bash): refuse nohup/setsid/disown in a foreground call. A job detached that way sends Claude Code no
# completion notice, so the session never learns it ended. run_in_background jobs notify and survive dcp forks; a job
# that must also outlive Claude Code is detached inside a run_in_background call that waits for it.
in=$(cat)
[ "$(printf '%s' "$in" | jq -r '.tool_input.run_in_background // false')" = true ] && exit 0
printf '%s' "$in" | jq -r '.tool_input.command // ""' |
  grep -qE "(^|[;&|(\`'\"]|\bdo|\bthen|\belse)[[:space:]]*(nohup|setsid|disown)([[:space:]]|$)" || exit 0
cat >&2 <<'EOF'
Bash refused: nohup/setsid/disown in a foreground call detaches the job, so no completion notice ever arrives.
- Normal job: drop nohup and set run_in_background: true. It notifies on exit and survives dcp forks.
- Job that must outlive Claude Code: detach it inside a run_in_background call that waits for it, e.g.
  local:  setsid -w nohup JOB >LOG 2>&1 </dev/null & wait $!; tail -20 LOG
  remote: ssh HOST 'setsid -w nohup JOB >LOG 2>&1 </dev/null & wait $!; tail -20 LOG'
EOF
exit 2
