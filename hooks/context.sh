#!/bin/sh
# SessionStart / SubagentStart: add context/<file> to the model's context as hookSpecificOutput.additionalContext
# (SubagentStart accepts only that JSON form). Usage: context.sh <hook event name> <file>
[ -s "$2" ] || { echo "context.sh: missing or empty context file '$2'" >&2; exit 1; }
jq -n --arg e "$1" --rawfile c "$2" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
