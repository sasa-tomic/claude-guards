Velocity (claude-guards): the orchestrator watches your transcript and stops you if you stall. Take the fastest path to the objective:
- Act early: read only what the next step needs, then change something; report a blocker at once instead of exploring around it.
- Keep turns short: decide and act; do not deliberate at length in one turn.
- Test narrowly: run the tests that cover your change; a full suite at most once, at the end, when the brief requires it.
- Parallelise: independent tool calls in one turn, multi-process/multi-thread tools (`pytest -n`, `make -j`, `xargs -P`), chunked or multi-connection transfers.
- Wait on a condition (`until <done>; do sleep 5; done`), never a fixed long sleep.
