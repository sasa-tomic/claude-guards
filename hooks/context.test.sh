#!/bin/sh
# Self-check for context.sh: sh hooks/context.test.sh
hook=$(dirname "$0")/context.sh
ctx=$(dirname "$0")/../context
fail=0
for f in "$ctx"/*.md; do
  out=$(sh "$hook" SubagentStart "$f") || { echo "FAIL exit $?: $f"; fail=1; continue; }
  [ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" = SubagentStart ] || { echo "FAIL event: $f"; fail=1; }
  [ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" = "$(cat "$f")" ] || { echo "FAIL context: $f"; fail=1; }
done
sh "$hook" SessionStart "$ctx/absent.md" 2>/dev/null && { echo "FAIL missing file accepted"; fail=1; }
[ $fail = 0 ] && echo ok
exit $fail
