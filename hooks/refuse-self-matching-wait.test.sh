#!/bin/sh
# Self-check for refuse-self-matching-wait.sh: sh hooks/refuse-self-matching-wait.test.sh
hook=$(dirname "$0")/refuse-self-matching-wait.sh
fail=0
check() { # expected-exit command
  jq -nc --arg c "$2" '{tool_input:{command:$c}}' | sh "$hook" 2>/dev/null
  got=$?; [ "$got" = "$1" ] || { echo "FAIL want $1 got $got: $2"; fail=1; }
}
check 2 'while pgrep -f ximl.py >/dev/null; do sleep 20; done; tail log'
check 2 'until ! pgrep -f "xsearch.py idx" >/dev/null; do sleep 20; done'
check 2 'cd x && while pgrep -af job | grep -q py; do sleep 5; done'
check 0 'while kill -0 1234 2>/dev/null; do sleep 20; done'
check 0 'tail --pid=1234 -f /dev/null; cat log'
check 0 'pgrep -af ximl | cut -c1-100'
check 0 'while read l; do echo $l; done < f'
[ $fail = 0 ] && echo ok
exit $fail
