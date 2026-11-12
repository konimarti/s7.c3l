#!/usr/bin/env python3
"""Tests of gen_fuzz_corpus.py: python3 -I scripts/test_gen_fuzz_corpus.py (standard library only)."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "gen_fuzz_corpus.py")
REPO = os.path.join(HERE, "..")


def run(root, *args):
    env = dict(os.environ, S7_REPO_ROOT=root)
    return subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True, env=env)


class Corpus(unittest.TestCase):
    def test_the_corpus_of_the_repository_is_complete(self):
        r = run(REPO, "--check")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "ok"), r.stdout)

    def test_a_new_fixture_makes_the_check_fail_until_the_corpus_is_regenerated(self):
        with tempfile.TemporaryDirectory() as d:
            shutil.copytree(os.path.join(REPO, "src", "test"), os.path.join(d, "src", "test"))
            self.assertEqual(run(d, "--check").returncode, 0)
            with open(os.path.join(d, "src", "test", "new_fixtures.c3"), "w") as f:
                f.write('module s7;\nconst String FX_NEW_ONE = "03 00 00 07 02 F0 80";\n')
            r = run(d, "--check")
            self.assertEqual(r.returncode, 1, r.stdout)
            self.assertIn("out of date", r.stdout)
            self.assertEqual(run(d).returncode, 0)
            self.assertEqual(run(d, "--check").returncode, 0)
            with open(os.path.join(d, "src", "test", "fuzz_corpus.c3")) as f:
                self.assertIn("FX_NEW_ONE", f.read())

    def test_a_non_hex_constant_is_not_a_fixture(self):
        with tempfile.TemporaryDirectory() as d:
            shutil.copytree(os.path.join(REPO, "src", "test"), os.path.join(d, "src", "test"))
            with open(os.path.join(d, "src", "test", "other.c3"), "w") as f:
                f.write('module s7;\nconst String FX_TEXT = "not hex";\n')
            self.assertEqual(run(d, "--check").returncode, 0)


if __name__ == "__main__":
    unittest.main()
