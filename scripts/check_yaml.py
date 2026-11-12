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
    "c3c build peercheck": r"^\s*c3c build peercheck\b",
    "s7tool --version": r"^\s*(\S*[/\\])?s7tool(\.exe)? --version\b",
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


def bash_default(body):
    """True when the job sets `defaults: run: shell: bash`."""
    return re.search(r"defaults:\s*\n\s*run:\s*\n\s*shell:\s*bash", body) is not None


def steps_with_run(body):
    return [st for st in re.split(r"\n      - ", body) if re.search(r"(^|\n)\s*(- )?run:", st)]


def check_pins(raw):
    """Every action is pinned to a full commit SHA with the version as a comment; every pip package to an exact version."""
    problems = []
    for line in raw.split("\n"):
        m = re.match(r"^\s*(?:- )?uses:\s*(\S+)@(\S+)\s*(#.*)?$", line)
        if m:
            if not re.fullmatch(r"[0-9a-f]{40}", m.group(2)):
                problems.append("action %s is not pinned to a commit SHA (found @%s)" % (m.group(1), m.group(2)))
            elif not m.group(3) or not re.match(r"#\s*v\d", m.group(3)):
                problems.append("action %s is pinned but its line has no '# vX.Y.Z' comment" % m.group(1))
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        pm = re.search(r"\bpip3?\s+install\s+(.*)$", stripped)
        if pm:
            for token in pm.group(1).split():
                if token.startswith("-") or token.startswith("$") or token.startswith("."):
                    continue
                if "==" not in token:
                    problems.append("pip package %s is not pinned with ==" % token)
    return problems


def check(text):
    problems = check_pins(text)
    text = strip_comments(text)
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
        # an expression such as ${{ github.event.inputs.x }} is pasted into the script before the shell runs it: input from the
        # dispatch form would become shell code. It has to go through the environment.
        if re.search(r"\$\{\{[^}]*\binputs\b", scripts):
            problems.append("job %s pastes a workflow input into a run script; pass it through env: and use the variable" % name)
        # dirname splits on / only: a Windows path has to be converted after the directory is taken, not before
        if re.search(r"dirname\s+\"?\$\(cygpath", scripts):
            problems.append("job %s takes the dirname of a cygpath result; use cygpath -w \"$(dirname ...)\"" % name)
    if not re.search(r"^permissions:", head, re.M) or not re.search(r"contents:\s*read", head):
        problems.append("no top level permissions: contents: read (the token should be read only)")
    for name, body in blocks.items():
        if "windows" in name:
            # the default shell on Windows is PowerShell: the help step runs under bash, or names the .exe
            for step in re.split(r"\n      - ", body):
                if re.search(r"s7tool(\.exe)? --help", step) and not bash_default(body) and "shell: bash" not in step and "s7tool.exe" not in step:
                    problems.append("the s7tool --help step of %s needs shell: bash (or the .exe name)" % name)
        if name in REQUIRED_JOBS or name == "peer":
            if not bash_default(body) and not all("shell: bash" in st for st in steps_with_run(body)):
                problems.append("job %s should run every script under bash (defaults: run: shell: bash)" % name)
        if name == "peer":
            if "venv" not in body:
                problems.append("job peer should install python-snap7 into a venv (the system Python refuses pip)")
            if "exit 1" not in run_scripts(body):
                problems.append("job peer should fail with exit 1 when the peer does not report READY")
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
