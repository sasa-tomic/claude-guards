# claude-guards

Guards for Claude Code: hooks that refuse a tool call at the point of the mistake and tell the model what to do instead, and a watchdog that keeps subagents moving.

- **refuse-detached-bash** (Bash): refuses `nohup`, `setsid` and `disown` in a foreground call. A job detached that way sends Claude Code no completion notice, so the session never learns it ended. `run_in_background: true` calls pass; the refusal message shows how to run a job that must outlive Claude Code.
- **require-subagent-model** (Agent): refuses a subagent launch without an explicit `model`, so each one runs on a deliberately chosen model instead of the default. Forks are exempt: they always inherit the parent model.
- **subagent velocity** (SessionStart, SubagentStart, plugin monitor): [`context/orchestrator.md`](context/orchestrator.md) lets the main agent delegate large work and makes it own its subagents' velocity; [`context/subagent.md`](context/subagent.md) tells each subagent to take the fastest path. The `subagent-watchdog` monitor ([`monitors/subagents.sh`](monitors/subagents.sh)) notifies the main agent of each background subagent's stalled tool calls, long silent turns and periodic progress, so a stall is caught in minutes, not hours.

Needs `sh` and `jq`; the watchdog needs Linux `/proc`.

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
sh hooks/refuse-detached-bash.test.sh
sh hooks/require-subagent-model.test.sh
sh hooks/context.test.sh
sh monitors/subagents.test.sh
```

Each prints `ok`, or a `FAIL` line per wrong case and exits 1.
