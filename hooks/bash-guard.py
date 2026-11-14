"""PreToolUse(Bash): parse the command with shfmt and refuse the two ways a session stops hearing about its own work.
- Detached job: nohup/setsid/disown in a foreground call, or a `&` job that no later `wait`/`kill` in the same shell
  ends, outlives the call, so Claude Code sends no completion notice and the session never learns the job ended.
- Self-matching pgrep: `pgrep -f`/`pkill -f` also matches the calling shell, whose command line holds the pattern, so a
  wait on it never ends and a pkill kills the caller. `-A` (--ignore-ancestors) excludes the caller.
Literal code given to bash/sh -c, eval and ssh is checked the same way. A command shfmt cannot parse is refused.
Registered as `python3 -I <this> || exit 2`: any error refuses the call.
"""
import json
import os
import subprocess
import sys

DETACHERS = {"nohup", "setsid", "disown"}
ENDERS = {"wait", "kill"}
SHELLS = {"bash", "sh", "dash", "zsh"}
PGREP = {"pgrep", "pkill"}
PGREP_ARG_SHORT = set("dgGOPstuUFrq")
PGREP_ARG_LONG = {"delimiter", "pgroup", "group", "older", "parent", "session", "signal", "terminal", "euid", "uid",
                  "pidfile", "runstates", "cgroup", "ns", "nslist", "queue"}
SSH_ARG_SHORT = set("BbcDEeFIiJLlmOoPpQRSWw")
NEW_SHELL = {"Subshell", "CmdSubst", "ProcSubst"}
PIPE = 12  # shfmt BinaryCmd.Op of `|`: each side runs in its own subshell
DETACHED = """Bash refused: this detaches a job, so no completion notice ever arrives.
- Normal job: drop nohup/setsid/disown and `&`, set run_in_background: true. It notifies on exit and survives dcp forks.
- Several jobs in one call: end it with `wait`, e.g. `for v in a b; do job $v & done; wait`; a helper job: `kill $!`.
- Job that must outlive Claude Code: detach it inside a run_in_background call that waits for it, e.g.
  local:  setsid -w nohup JOB >LOG 2>&1 </dev/null & wait $!; tail -20 LOG
  remote: ssh HOST 'setsid -w nohup JOB >LOG 2>&1 </dev/null & wait $!; tail -20 LOG'"""
SELF_MATCH = """Bash refused: `pgrep -f`/`pkill -f` without -A also matches the calling shell, whose command line holds the
pattern: a wait on it never ends, a pkill kills the caller. Add -A (--ignore-ancestors), e.g. `pgrep -Af PATTERN`."""


class Unparsable(Exception):
    pass


def parse(script):
    run = subprocess.run(["shfmt", "-tojson"], input=script, text=True, capture_output=True)
    if run.returncode:
        raise Unparsable(f"Bash refused: shfmt cannot parse the command, so the guards cannot check it:\n{run.stderr}")
    return json.loads(run.stdout)


def word(node):
    """The literal text of a shell word, or None when part of it is only known at run time."""
    text = []
    for p in node["Parts"]:
        if p["Type"] in ("Lit", "SglQuoted"):
            text.append(p["Value"])
        elif p["Type"] == "DblQuoted" and all(q["Type"] == "Lit" for q in p["Parts"]):
            text.extend(q["Value"] for q in p["Parts"])
        else:
            return None
    return "".join(text)


def self_matching(args):
    """pgrep/pkill args select by full command line (-f) without excluding the caller's ancestors (-A)."""
    full = ancestors = False
    args = iter(args)
    for a in args:
        if not a or a[0] != "-":
            continue
        if a.startswith("--"):
            name = a[2:].partition("=")[0]
            full |= name == "full"
            ancestors |= name == "ignore-ancestors"
            if name in PGREP_ARG_LONG and "=" not in a:
                next(args, None)
            continue
        for i, c in enumerate(a[1:], 1):
            full |= c == "f"
            ancestors |= c == "A"
            if c in PGREP_ARG_SHORT:
                if i == len(a) - 1:
                    next(args, None)
                break
    return full and not ancestors


def nested_script(cmd, args):
    """Literal code cmd hands to another shell: bash -c CODE, eval CODE..., ssh [OPTS] HOST CODE..."""
    if cmd in SHELLS:
        if not any(a and a[0] == "-" and a[1:2] != "-" and "c" in a for a in args):
            return None
        args = [a for a in args if not (a and a[0] == "-")][:1]
    elif cmd == "ssh":
        i = 0
        while i < len(args) and args[i] and args[i][0] == "-":
            i += 2 if len(args[i]) == 2 and args[i][1] in SSH_ARG_SHORT else 1
        args = args[i + 1:]
    elif cmd != "eval":
        return None
    return " ".join(a for a in args if a) or None


def check(tree, background, refusals):
    jobs, enders = [], []  # (shell, offset) of each `&` statement's end and of each wait/kill

    def walk(node, shell):
        if isinstance(node, list):
            for n in node:
                walk(n, shell)
            return
        if not isinstance(node, dict):
            return
        if node.get("Type") in NEW_SHELL:
            shell = id(node)
        if node.get("Background"):
            jobs.append((shell, node["End"]["Offset"]))
        if node.get("Type") == "CallExpr" and node["Args"]:
            args = [word(a) for a in node["Args"]]
            cmd = os.path.basename(args[0] or "")
            if cmd in ENDERS:
                enders.append((shell, node["Pos"]["Offset"]))
            if cmd in DETACHERS and not background:
                refusals.add(DETACHED)
            if cmd in PGREP and self_matching(args[1:]):
                refusals.add(SELF_MATCH)
            nested = nested_script(cmd, args[1:])
            if nested:
                check(parse(nested), background, refusals)
        if node.get("Type") == "BinaryCmd" and node["Op"] == PIPE:
            walk(node["X"], id(node["X"]))
            walk(node["Y"], id(node["Y"]))
            return
        for value in node.values():
            walk(value, shell)

    walk(tree, None)
    if any(not any(s == shell and e > end for s, e in enders) for shell, end in jobs):
        refusals.add(DETACHED)


def main():
    tool_input = json.load(sys.stdin)["tool_input"]
    refusals = set()
    try:
        check(parse(tool_input["command"]), tool_input.get("run_in_background", False), refusals)
    except Unparsable as e:
        refusals.add(str(e))
    if refusals:
        print("\n".join(sorted(refusals)), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
