#!/usr/bin/env python3
"""Checks that a CI workflow file has what the project needs. Standard library only.

usage: check_yaml.py .github/workflows/ci.yml

Prints "ok" and exits 0 when the workflow has the push, pull_request and workflow_dispatch triggers, the jobs build-linux,
build-macos and build-windows, and in each of those jobs the steps that run the tests, build s7tool and run it with --help.
Anything missing is reported and the exit status is 1. It does not parse YAML; it reads the text.
"""
import re
import sys

REQUIRED_TRIGGERS = ["push:", "pull_request:", "workflow_dispatch:"]
REQUIRED_JOBS = ["build-linux", "build-macos", "build-windows"]
REQUIRED_STEPS = ["c3c test", "c3c build s7tool", "s7tool --help"]


def job_blocks(text):
    """Maps job name -> its text; a job starts at a line with two spaces of indent and a name ending in a colon."""
    lines = text.split("\n")
    in_jobs = False
    blocks = {}
    current = None
    for line in lines:
        if re.match(r"^jobs:\s*$", line):
            in_jobs = True
            continue
        if not in_jobs:
            continue
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            current = m.group(1)
            blocks[current] = []
            continue
        if re.match(r"^\S", line):
            in_jobs = False
            current = None
            continue
        if current is not None:
            blocks[current].append(line)
    return {name: "\n".join(body) for name, body in blocks.items()}


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    with open(argv[1], "r", encoding="utf-8") as f:
        text = f.read()
    problems = []
    head = text.split("\njobs:")[0]
    for trigger in REQUIRED_TRIGGERS:
        if trigger not in head:
            problems.append("missing trigger " + trigger)
    blocks = job_blocks(text)
    for job in REQUIRED_JOBS:
        if job not in blocks:
            problems.append("missing job " + job)
            continue
        for step in REQUIRED_STEPS:
            if step not in blocks[job]:
                problems.append("job %s has no step running '%s'" % (job, step))
    if "v0.8.6" not in text:
        problems.append("the compiler version v0.8.6 is not pinned")
    if problems:
        for p in problems:
            print("problem:", p)
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
