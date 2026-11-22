"""Self-check for bash-guard.py: python3 hooks/bash-guard.test.py"""
import json
import os
import pathlib
import subprocess
import sys
import unittest

HOOK = pathlib.Path(__file__).with_name("bash-guard.py")
# systemd's default PATH: hooks of sessions started by a systemd unit get no ~/bin or ~/.local/bin
SYSTEMD_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


class BashGuard(unittest.TestCase):
    def check(self, want, message, cases, background=False, env=None):
        for command in cases:
            with self.subTest(command=command):
                hook_input = json.dumps({"tool_input": {"command": command, "run_in_background": background}})
                run = subprocess.run([sys.executable, "-I", HOOK], input=hook_input, text=True, capture_output=True,
                                     env={**os.environ, "PATH": SYSTEMD_PATH, **(env or {})})
                self.assertEqual(run.returncode, want, run.stderr)
                self.assertIn(message, run.stderr)

    def test_refuses_detaching_command_in_foreground_call(self):
        self.check(2, "no completion notice", [
            "nohup python x.py > log 2>&1",
            "cd /a && nohup ~/bin/limited -- job",
            "ssh h 'cd /root && nohup job'",
            "setsid job",
            "for m in 5 3; do nohup job; done",
        ])

    def test_refuses_unwaited_background_job_in_any_call(self):
        self.check(2, "no completion notice", ["( python a.py > log 2>&1 & )", "cd x && job > log 2>&1 &"])
        self.check(2, "no completion notice", ["for v in a b; do job $v & done", "job & disown"], background=True)

    def test_allows_waited_jobs_and_text_that_only_looks_like_one(self):
        self.check(0, "", ["for v in a b; do (cd $v && job) & done; wait", "a && b 2>&1 | c &>f; curl 'x?a=1&b=2'",
                           "cat > f <<EOF\nR & D\nnohup x\nEOF", "grep -c nohup /tmp/x.txt",
                           "srv & sleep 1; curl x; kill $!"])
        self.check(0, "", ["setsid -w nohup job >log 2>&1 </dev/null & wait $!; tail -20 log",
                           "ssh h 'setsid -w nohup job >log 2>&1 </dev/null & wait $!'"], background=True)

    def test_refuses_pgrep_or_pkill_by_full_command_line_without_ignore_ancestors(self):
        self.check(2, "-A", [
            'P=$(pgrep -d" " -f "research/selloff.py"); for p in $P; do tail --pid=$p -f /dev/null; done',
            'echo "$(/usr/bin/pgrep -af job | cut -c1-9)"',
            "pkill --full job.py",
            "bash -c 'pgrep job -f'",
            "cat <<EOF\n$(pgrep -f job)\nEOF",
            "pgrep -f '' \"\"",
        ])

    def test_allows_pgrep_that_cannot_match_its_own_shell(self):
        self.check(0, "", ["pgrep -Aaf ximl.py", "pkill --ignore-ancestors -f job.py", "pgrep -d f job",
                           "pgrep --delimiter -f job", "pgrep -x python", 'grep -c "pgrep -f" notes.md'])

    def test_refuses_command_shfmt_cannot_parse(self):
        self.check(2, "cannot parse", ["echo $(", "ssh h 'echo $('"])

    def test_refuses_heavy_job_without_limited(self):
        self.check(2, "under `limited`", [
            ".venv/bin/python -m pytest tests/", "cd x && pytest -x", "uv run pytest", "timeout 60 py.test",
            "cargo +nightly test --release", "cargo build", "bash -c 'cargo nextest run'", "FOO=1 python3 -u -m pytest",
        ])

    def test_allows_heavy_job_under_limited_light_commands_and_remote_jobs(self):
        self.check(0, "", ["limited -m 8 -- pytest -x", "cd x && ~/bin/limited -t 2h -- cargo test", "cargo fmt",
                           "python -m pip install pytest", "grep -r pytest .", "echo cargo test",
                           "ssh h 'cd /x && pytest'", "uv run limited -- pytest"])

    def test_heavy_job_allowed_where_limited_cannot_run(self):
        self.check(0, "", ["pytest -x", "cargo test"], env={"XDG_RUNTIME_DIR": "/nonexistent"})


if __name__ == "__main__":
    unittest.main()
