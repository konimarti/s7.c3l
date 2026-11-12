#!/usr/bin/env python3
"""Tests of check_yaml.py with small synthetic workflows. Standard library only: python3 -I scripts/test_check_yaml.py"""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "check_yaml.py")
REAL = os.path.join(HERE, "..", ".github", "workflows", "ci.yml")


def run_check(text):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "w.yml")
        with open(path, "w") as f:
            f.write(text)
        r = subprocess.run([sys.executable, "-I", CHECK, path], capture_output=True, text=True)
        return r.returncode, r.stdout


SHA = "11d5960a326750d5838078e36cf38b85af677262"


def job(name, extra=""):
    return f"""  {name}:
    runs-on: x
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@{SHA} # v4.4.0
      - name: tests
        run: c3c test
      - name: build
        run: c3c build s7tool
      - name: build the other tool
        run: c3c build peercheck
      - name: help
        {extra}run: build/s7tool --help
      - name: version
        run: build/s7tool --version
"""


def workflow(jobs, head="on:\n  push:\n  pull_request:\n  workflow_dispatch:\nenv:\n  C3_VERSION: v0.8.6\n"):
    return head + "jobs:\n" + "".join(jobs)


GOOD = workflow(
    [job("build-linux"), job("build-macos"), job("build-windows")],
    head="permissions:\n  contents: read\non:\n  push:\n  pull_request:\n  workflow_dispatch:\nenv:\n  C3_VERSION: v0.8.6\n",
)


class CheckYaml(unittest.TestCase):
    def test_good_workflow_is_ok(self):
        code, out = run_check(GOOD)
        self.assertEqual((code, out.strip()), (0, "ok"))

    def test_a_commented_out_step_does_not_count(self):
        text = GOOD.replace("        run: c3c test\n", "        # run: c3c test\n", 1)
        code, out = run_check(text)
        self.assertEqual(code, 1, out)
        self.assertIn("c3c test", out)

    def test_a_command_that_is_only_mentioned_does_not_count(self):
        text = GOOD.replace("run: build/s7tool --help", "run: echo s7tool --help", 1)
        code, out = run_check(text)
        self.assertEqual(code, 1, out)

    def test_the_version_in_a_comment_does_not_count(self):
        text = GOOD.replace("  C3_VERSION: v0.8.6\n", "  # v0.8.6\n  C3_VERSION: v0.8.5\n")
        code, out = run_check(text)
        self.assertEqual(code, 1, out)

    def test_the_windows_path_step_converts_after_taking_the_directory(self):
        good = GOOD + '''  setup:
    steps:
      - run: |
          echo "$(cygpath -w "$(dirname "$C3C")")" >> "$GITHUB_PATH"
'''
        self.assertEqual(run_check(good)[0], 0)
        bad = good.replace('echo "$(cygpath -w "$(dirname "$C3C")")"', 'echo "$(dirname "$(cygpath -w "$C3C")")"')
        code, out = run_check(bad)
        self.assertEqual(code, 1, out)
        self.assertIn("dirname", out)

    def test_workflow_input_must_not_be_pasted_into_a_script(self):
        bad = GOOD.replace("run: c3c test", 'run: |\n          VERSION="${{ github.event.inputs.version }}"\n          c3c test', 1)
        code, out = run_check(bad)
        self.assertEqual(code, 1, out)
        self.assertIn("workflow input", out)
        # through the environment it is fine
        fine = GOOD.replace("run: c3c test", 'env:\n          INPUT_VERSION: ${{ github.event.inputs.version }}\n        run: |\n          VERSION="${INPUT_VERSION:-v0.8.6}"\n          c3c test', 1)
        self.assertEqual(run_check(fine)[0], 0)

    def test_scripts_must_run_under_bash(self):
        bad = GOOD.replace("    defaults:\n      run:\n        shell: bash\n", "")
        code, out = run_check(bad)
        self.assertEqual(code, 1, out)
        self.assertIn("bash", out)
        # a shell on every step is as good as the default
        steps = bad.replace("        run: ", "        shell: bash\n        run: ")
        self.assertEqual(run_check(steps)[0], 0)

    def test_actions_are_pinned_to_a_commit_sha_with_a_version_comment(self):
        for bad_line in ("      - uses: actions/checkout@v4\n", "      - uses: actions/checkout@main\n",
                         "      - uses: actions/checkout@%s\n" % SHA, "      - uses: actions/checkout@%s # latest\n" % SHA,
                         "      - uses: actions/checkout@%s\n" % SHA[:39]):
            bad = GOOD.replace("      - uses: actions/checkout@%s # v4.4.0\n" % SHA, bad_line, 1)
            code, out = run_check(bad)
            self.assertEqual(code, 1, bad_line + out)
            self.assertIn("checkout", out)

    def test_pip_packages_are_pinned_exactly(self):
        bad = GOOD.replace("run: c3c test", "run: python3 -m pip install python-snap7", 1)
        code, out = run_check(bad)
        self.assertEqual(code, 1, out)
        self.assertIn("python-snap7", out)
        for fine in ("python3 -m pip install python-snap7==3.5.0", ".venv/bin/pip install --upgrade pip==24.0 python-snap7==3.5.0"):
            self.assertNotIn("pip package", run_check(GOOD.replace("run: c3c test", "run: " + fine, 1))[1])

    def test_every_tool_is_built_and_the_version_is_printed(self):
        for gone in ("run: c3c build peercheck", "run: build/s7tool --version"):
            bad = GOOD.replace(gone, "run: echo nothing", 1)
            code, out = run_check(bad)
            self.assertEqual(code, 1, gone + out)

    def test_the_token_is_read_only(self):
        bad = GOOD.replace("permissions:\n  contents: read\n", "")
        code, out = run_check(bad)
        self.assertEqual(code, 1, out)
        self.assertIn("permissions", out)

    def test_the_peer_job_uses_a_venv_and_fails_when_the_peer_does_not_start(self):
        peer = """  peer:
    defaults:
      run:
        shell: bash
    steps:
      - run: python3 -m pip install python-snap7
      - run: |
          for i in 1 2 3; do
            if grep -q READY peer.log; then break; fi
          done
"""
        code, out = run_check(GOOD + peer)
        self.assertEqual(code, 1, out)
        self.assertIn("venv", out)
        self.assertIn("exit 1", out)
        fine = peer.replace("python3 -m pip install python-snap7", ".venv/bin/pip install python-snap7==3.5.0").replace("          done\n", "          done\n          grep -q READY peer.log || exit 1\n") + "      - run: python3 -m venv .venv\n"
        self.assertEqual(run_check(GOOD + fine)[0], 0)

    def test_the_real_workflow_is_ok(self):
        with open(REAL) as f:
            code, out = run_check(f.read())
        self.assertEqual((code, out.strip()), (0, "ok"), out)


if __name__ == "__main__":
    unittest.main()
