#!/usr/bin/env bash
# Tests for limited (default: next to this file, or $1): deadline, extend, idle kill, cpu warning, caps, ls, arguments.
set -u
L=${1:-$(dirname "$0")/limited}
export LIMITED_SAMPLE_S=1
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# the deadline kills the job, exit 124, and says how to extend
t0=$EPOCHSECONDS
err=$("$L" -t 3s -i 0 -- sleep 60 2>&1 >/dev/null); rc=$?
dt=$(( EPOCHSECONDS - t0 ))
[[ $rc -eq 124 && $dt -lt 10 && $err == *"past its deadline"*"limited extend"* ]] && ok "deadline kill" || bad "deadline kill" "rc=$rc dt=$dt err=$err"

# extend by the pid of any job process moves the deadline: a 3s job extended to 8s lives ~8s
f=$(mktemp)
"$L" -t 3s -i 0 -- sh -c 'echo $$ > '"$f"'; sleep 60' 2>"$f.err" & lp=$!
for _ in $(seq 50); do [[ -s $f ]] && break; sleep 0.2; done; [[ -s $f ]] || { bad extend "job never started: $(<"$f.err")"; exit 1; }
t0=$EPOCHSECONDS
out=$("$L" extend "$(<"$f")" 8s); erc=$?
wait $lp; rc=$?; dt=$(( EPOCHSECONDS - t0 ))
[[ $erc -eq 0 && $out == *deadline* && $rc -eq 124 && $dt -ge 7 && $dt -le 11 ]] && ok "extend" || bad "extend" "erc=$erc out=$out rc=$rc dt=$dt err=$(<"$f.err")"
rm -f "$f" "$f.err"

# extend refuses a process outside any job
err=$("$L" extend 1 1h 2>&1); rc=$?
[[ $rc -eq 1 && $err == *"not in a limited job"* ]] && ok "extend refuses foreign pid" || bad "extend refuses foreign pid" "rc=$rc err=$err"

# a deadline warning comes before the deadline kill, naming the extend command
err=$("$L" -t 4s -i 0 -- sleep 60 2>&1 >/dev/null); rc=$?
[[ $rc -eq 124 && $err == *"deadline in "*"limited extend"*"past its deadline"* ]] && ok "deadline warning" || bad "deadline warning" "rc=$rc err=$err"

# a job ending before the first sample gets no warning at all
err=$("$L" -- sleep 0.5 2>&1 >/dev/null)
[[ -z $err ]] && ok "no warnings when short" || bad "no warnings when short" "err=$err"

# an idle (stalled) job is killed after the idle window, exit 124
t0=$EPOCHSECONDS
err=$("$L" -i 3s -- sleep 60 2>&1 >/dev/null); rc=$?
dt=$(( EPOCHSECONDS - t0 ))
[[ $rc -eq 124 && $dt -lt 10 && $err == *"idle:"* ]] && ok "idle kill" || bad "idle kill" "rc=$rc dt=$dt err=$err"

# a busy job is not killed as idle, and keeps its own exit code
err=$("$L" -i 2s -- timeout 5 sh -c 'while :; do :; done' 2>&1 >/dev/null); rc=$?
[[ $rc -eq 124 && $err != *"limited: killed"* ]] && ok "busy job not idle" || bad "busy job not idle" "rc=$rc err=$err"
err=$("$L" -- sh -c 'exit 7' 2>&1 >/dev/null); rc=$?
[[ $rc -eq 7 && -z $err ]] && ok "exit code passthrough" || bad "exit code passthrough" "rc=$rc err=$err"

# a raised floor kills a job that uses less than it
err=$("$L" -i 3s -c 2 -- timeout 30 sh -c 'while :; do :; done' 2>&1 >/dev/null); rc=$?
[[ $rc -eq 124 && $err == *"idle:"*"floor 2"* ]] && ok "idle floor" || bad "idle floor" "rc=$rc err=$err"

# -i 0 overrides LIMITED_IDLE
err=$(LIMITED_IDLE=2s "$L" -t 5s -i 0 -- sleep 60 2>&1 >/dev/null); rc=$?
[[ $rc -eq 124 && $err != *"idle:"* && $err == *deadline* ]] && ok "idle kill off" || bad "idle kill off" "rc=$rc err=$err"

# a stalled job gets a cpu warning at the first sample and every 3 samples, and is not killed by default
err=$("$L" -- sleep 4.5 2>&1 >/dev/null); rc=$?
n=$(grep -c '^limited: cpu: job used 0.0[0-4] cores' <<< "$err")
[[ $rc -eq 0 && $n -eq 2 && $err != *killed* ]] && ok "cpu warning when stalled" || bad "cpu warning when stalled" "rc=$rc n=$n err=$err"
# a busy job is warned only for an idle machine: every warning reports >= a quarter of the cores idle
err=$("$L" -c 0 -- timeout 4.5 sh -c 'while :; do :; done' 2>&1 >/dev/null)
bad_lines=$(awk -v n="$(nproc --all)" '/^limited: cpu:/ { if ($8 < n / 4) print }' <<< "$err")
[[ -z $bad_lines ]] && ok "cpu warning only for idle machine" || bad "cpu warning only for idle machine" "$bad_lines"
# LIMITED_IDLE turns the idle kill on without -i
err=$(LIMITED_IDLE=3s "$L" -- sleep 60 2>&1 >/dev/null); rc=$?
[[ $rc -eq 124 && $err == *"killed: idle:"* ]] && ok "LIMITED_IDLE" || bad "LIMITED_IDLE" "rc=$rc err=$err"

# caps: claude-limited.slice gets 65% of MemTotal, the scope -m GB, no swap; OMP_WAIT_POLICY defaults to PASSIVE, a caller's value wins
gb=$(awk '$1 == "MemTotal:" { print int($2 * 0.65 / 1048576) }' /proc/meminfo)
out=$("$L" -m 3 -- sh -c 'c=/sys/fs/cgroup$(sed -n "s/^0:://p" /proc/self/cgroup); cat $c/memory.max $c/memory.swap.max $c/../memory.max; basename $(dirname $c); echo $OMP_WAIT_POLICY')
[[ $out == "$((3 << 30))"$'\n'0$'\n'"$((gb << 30))"$'\n'claude-limited.slice$'\n'PASSIVE ]] && ok "caps" || bad "caps" "out=$out gb=$gb"
out=$(OMP_WAIT_POLICY=ACTIVE "$L" -- printenv OMP_WAIT_POLICY)
[[ $out == ACTIVE ]] && ok "caller OMP_WAIT_POLICY kept" || bad "caller OMP_WAIT_POLICY kept" "out=$out"

# ls lists a running job with its time left
"$L" -t 1h -i 0 -- sleep 30 2>/dev/null & lp=$!
sleep 2
out=$("$L" ls); kill $lp; wait $lp 2>/dev/null
[[ $out == *"sleep 30"* && $out == *"59m"* ]] && ok "ls" || bad "ls" "out=$out"

# stdin reaches the job (a backgrounded job would get /dev/null)
out=$("$L" -- cat <<< "piped")
[[ $out == piped ]] && ok "stdin passthrough" || bad "stdin passthrough" "out=$out"

# arguments reach the job verbatim (systemd-run expands $VAR, ${VAR} and $$ by default)
out=$(HOME=x "$L" -- echo '$HOME' '${HOME}' '$$')
[[ $out == '$HOME ${HOME} $$' ]] && ok "arguments verbatim" || bad "arguments verbatim" "out=$out"

# bad arguments are refused before anything runs
for a in "-t soon" "-m x" "-m $((gb + 1))" "-i forever" "-c lots"; do
  "$L" $a -- true 2>/dev/null; rc=$?
  [[ $rc -eq 2 ]] && ok "bad $a refused" || bad "bad $a refused" "rc=$rc"
done

exit $fail
