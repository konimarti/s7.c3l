#!/usr/bin/env python3
"""Checks that a CI workflow file has what the project needs. Standard library only.

usage: check_yaml.py .github/workflows/ci.yml

Prints "ok" and exits 0 when the workflow has the push, pull_request and workflow_dispatch triggers, the jobs build-linux,
build-macos and build-windows, and in each of those jobs the steps that run the tests, build s7tool and run it with --help.
Anything missing is reported and the exit status is 1. It does not parse YAML; it reads the text, ignoring comment lines, and a
command only counts when a line of a `run:` value (or of its script block) starts with it.
"""
import re
import sys

REQUIRED_TRIGGERS = ["push:", "pull_request:", "workflow_dispatch:"]
REQUIRED_JOBS = ["build-linux", "build-macos", "build-windows"]
# step name -> regular expression that the beginning of a command line of a run script must match
REQUIRED_STEPS = {
    "c3c test": r"^\s*c3c test\b",
    "c3c build s7tool": r"^\s*c3c build s7tool\b",
    "s7tool --help": r"^\s*(\S*[/\\])?s7tool(\.exe)? --help\b",
}


def strip_comments(text):
    """Drops lines that are only a comment, and trailing ` # comment` parts."""
    lines = []
    for line in text.split("\n"):
        if line.lstrip().startswith("#"):
            continue
        lines.append(re.sub(r"\s+#.*$", "", line))
    return "\n".join(lines)


def run_scripts(block):
    """The text of all `run:` values of a job: the rest of a `run:` line and the lines of a `run: |` block."""
    out = []
    lines = block.split("\n")
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)(?:- )?run:\s*(.*)$", lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        rest = m.group(2)
        if rest in ("|", ">", "|-", ">-"):
            i += 1
            while i < len(lines) and (lines[i].strip() == "" or len(lines[i]) - len(lines[i].lstrip()) > indent):
                out.append(lines[i])
                i += 1
            continue
        out.append(rest)
        i += 1
    return "\n".join(out)


def job_blocks(text):
    """Maps job name -> its text; a job starts at a line with two spaces of indent and a name ending in a colon."""
    in_jobs = False
    blocks = {}
    current = None
    for line in text.split("\n"):
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


def check(text):
    text = strip_comments(text)
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
        scripts = run_scripts(blocks[job])
        for step, pattern in REQUIRED_STEPS.items():
            if not re.search(pattern, scripts, re.M):
                problems.append("job %s has no step running '%s'" % (job, step))
    for name, body in blocks.items():
        scripts = run_scripts(body)
        # dirname splits on / only: a Windows path has to be converted after the directory is taken, not before
        if re.search(r"dirname\s+\"?\$\(cygpath", scripts):
            problems.append("job %s takes the dirname of a cygpath result; use cygpath -w \"$(dirname ...)\"" % name)
    if not re.search(r"C3_VERSION:\s*v0\.8\.6\b", text):
        problems.append("the compiler version v0.8.6 is not pinned in C3_VERSION")
    return problems


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    with open(argv[1], "r", encoding="utf-8") as f:
        text = f.read()
    problems = check(text)
    if problems:
        for p in problems:
            print("problem:", p)
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
