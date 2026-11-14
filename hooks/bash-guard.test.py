"""Self-check for bash-guard.py: python3 hooks/bash-guard.test.py"""
import json
import pathlib
import subprocess
import sys
import unittest

HOOK = pathlib.Path(__file__).with_name("bash-guard.py")


class BashGuard(unittest.TestCase):
    def check(self, want, message, cases, background=False):
        for command in cases:
            with self.subTest(command=command):
                hook_input = json.dumps({"tool_input": {"command": command, "run_in_background": background}})
                run = subprocess.run([sys.executable, "-I", HOOK], input=hook_input, text=True, capture_output=True)
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
        ])

    def test_allows_pgrep_that_cannot_match_its_own_shell(self):
        self.check(0, "", ["pgrep -Aaf ximl.py", "pkill --ignore-ancestors -f job.py", "pgrep -d f job",
                           "pgrep --delimiter -f job", "pgrep -x python", 'grep -c "pgrep -f" notes.md'])

    def test_refuses_command_shfmt_cannot_parse(self):
        self.check(2, "cannot parse", ["echo $(", "ssh h 'echo $('"])


if __name__ == "__main__":
    unittest.main()
