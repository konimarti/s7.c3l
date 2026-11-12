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


def job(name, extra=""):
    return f"""  {name}:
    runs-on: x
    steps:
      - name: tests
        run: c3c test
      - name: build
        run: c3c build s7tool
      - name: help
        {extra}run: build/s7tool --help
"""


def workflow(jobs, head="on:\n  push:\n  pull_request:\n  workflow_dispatch:\nenv:\n  C3_VERSION: v0.8.6\n"):
    return head + "jobs:\n" + "".join(jobs)


GOOD = workflow([job("build-linux"), job("build-macos"), job("build-windows")])


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
        good = workflow([job("build-linux"), job("build-macos"), job("build-windows")]) + '''  setup:
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

    def test_the_real_workflow_is_ok(self):
        with open(REAL) as f:
            code, out = run_check(f.read())
        self.assertEqual((code, out.strip()), (0, "ok"), out)


if __name__ == "__main__":
    unittest.main()
