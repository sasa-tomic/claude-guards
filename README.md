# claude-guards

Guards for Claude Code: hooks that refuse a tool call at the point of the mistake and tell the model what to do instead, and a watchdog that keeps subagents moving.

- **bash-guard** (Bash, [`hooks/bash-guard.py`](hooks/bash-guard.py)): parses the command with `shfmt` and refuses a job that would end without a completion notice (`nohup`, `setsid` or `disown` in a foreground call; a `&` job with no later `wait` or `kill`) and `pgrep -f`/`pkill -f` without `-A`, which match the calling shell, and, where `limited` can run, pytest and cargo test/build/bench not run under it. The refusal says what to do instead.
- **limited** ([`bin/limited`](bin/limited), on the Bash tool's `PATH` while the plugin is enabled): `limited [-m GB] [-t DURATION] -- COMMAND` runs a command in a transient systemd scope that caps memory (default 65% of RAM, no swap) and CPU for its whole process tree, so a runaway job is killed instead of freezing the machine; it also enforces a deadline, warns when the job stalls or leaves cores idle, and sets `OMP_WAIT_POLICY=PASSIVE` unless the caller set it. Options and mechanism: the script's header. Needs Linux, cgroup v2 and a systemd user session.
- **require-subagent-model** (Agent): refuses a subagent launch without an explicit `model`, so each one runs on a deliberately chosen model instead of the default. Forks are exempt: they always inherit the parent model.
- **subagent velocity** (SessionStart, SubagentStart, plugin monitor): [`context/orchestrator.md`](context/orchestrator.md) lets the main agent delegate large work and makes it own its subagents' velocity; [`context/subagent.md`](context/subagent.md) tells each subagent to take the fastest path. The `subagent-watchdog` monitor ([`monitors/subagents.sh`](monitors/subagents.sh)) notifies the main agent of each background subagent's stalled tool calls, long silent turns, periodic progress and finished work held alive by its own background task, so a stall is caught in minutes, not hours.

Needs `sh`, `jq`, `python3` and [`shfmt`](https://github.com/mvdan/sh) on `PATH`; the watchdog needs Linux `/proc`.

## Install

```
/plugin install guards --marketplace sasa-tomic/claude-guards
```

## Update

```
/plugin marketplace update claude-guards
```

Then `/plugin`, Installed tab, guards, Update now, then `/reload-plugins`.

## Remove

```
/plugin uninstall guards
/plugin marketplace remove claude-guards
/reload-plugins
```

## Test

```
python3 hooks/bash-guard.test.py
bash bin/limited.test.sh
sh hooks/require-subagent-model.test.sh
sh hooks/context.test.sh
sh monitors/subagents.test.sh
```

Each exits 1 on a wrong case and names it.
