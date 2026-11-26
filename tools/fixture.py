"""Fixtures: one file a behaviour, read by the test `fixtures` in src/tests.zig.

    python3 -I tools/fixture.py new   <sprack> <name> <from> <to> < netlist
    python3 -I tools/fixture.py bless <sprack> <file.case>...
    python3 -I tools/fixture.py check <sprack> [<file.case>...]

A fixture is a netlist, the dialect it is in, the dialect it is written for,
and the output and the report that must come out, byte for byte:

    # issue 28: a capacitor's ic= crosses into VACASK as a source in series
    from: ngspice
    to: vacask
    --- input
    t
    C1 a 0 1p ic=0.5
    .end
    --- output
    ...
    --- report
    info[oneway]: line 2: ...

`new` writes tests/fixtures/<name>.case from a netlist on standard input,
with the output and report the binary gives now: read them before you commit
them, they are the claim. `bless` rewrites those two sections of existing
fixtures after a change that is meant to move them. `check` runs them (all
of tests/fixtures by default) and prints each difference; `zig build test`
does the same from inside the library, with the checks every translation of
the test suite goes through.
"""

import difflib
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(os.path.dirname(HERE), "tests", "fixtures")
SECTIONS = ("input", "output", "report")


def parse(path):
    """({'from', 'to'}, comment lines, {'input', 'output', 'report'})."""
    head, comments, sections = {}, [], {name: "" for name in SECTIONS}
    current = None
    with open(path, encoding="utf-8", newline="") as f:
        for line in f:
            marker = line.rstrip("\n")
            if marker.startswith("--- ") and marker[4:] in SECTIONS:
                current = marker[4:]
            elif current is not None:
                sections[current] += line
            elif line.startswith("#"):
                comments.append(line)
            elif ":" in line:
                key, value = line.split(":", 1)
                head[key.strip()] = value.strip()
    for key in ("from", "to"):
        if key not in head:
            sys.exit(f"{path}: no `{key}:` line")
    return head, comments, sections


def run(binary, head, text):
    argv = [binary, "translate", "--from", head["from"], "--to", head["to"]]
    done = subprocess.run(argv, input=text.encode(), capture_output=True)
    if done.returncode not in (0, 1):
        sys.exit(f"{' '.join(argv)}: exit status {done.returncode}: {done.stderr.decode()[:200]}")
    return done.stdout.decode(), done.stderr.decode()


def write(path, head, comments, sections):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.writelines(comments)
        f.write(f"from: {head['from']}\nto: {head['to']}\n")
        for name in SECTIONS:
            f.write(f"--- {name}\n{sections[name]}")


def bless(binary, paths):
    for path in paths:
        head, comments, sections = parse(path)
        sections["output"], sections["report"] = run(binary, head, sections["input"])
        write(path, head, comments, sections)
        print(f"blessed {path}")


def check(binary, paths):
    failed = 0
    for path in paths or sorted(glob.glob(os.path.join(FIXTURES, "*.case"))):
        head, _, sections = parse(path)
        output, report = run(binary, head, sections["input"])
        for name, got in (("output", output), ("report", report)):
            if got == sections[name]:
                continue
            failed += 1
            print(f"{path}: {name} differs")
            want = sections[name].splitlines()
            for line in difflib.unified_diff(want, got.splitlines(), "expected", "got", lineterm=""):
                print("    " + line)
    print(f"{failed} differences")
    sys.exit(1 if failed else 0)


def new(binary, name, source, target):
    path = os.path.join(FIXTURES, name + ".case")
    if os.path.exists(path):
        sys.exit(f"{path} exists")
    head = {"from": source, "to": target}
    sections = {"input": sys.stdin.read(), "output": "", "report": ""}
    if not sections["input"].endswith("\n"):
        sections["input"] += "\n"
    sections["output"], sections["report"] = run(binary, head, sections["input"])
    write(path, head, [f"# {name}: say here what this holds, and the issue or commit it comes from\n"], sections)
    print(path)


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("new", "bless", "check"):
        sys.exit(__doc__)
    command, binary = sys.argv[1], sys.argv[2]
    if command == "new":
        new(binary, *sys.argv[3:6])
    elif command == "bless":
        bless(binary, sys.argv[3:])
    else:
        check(binary, sys.argv[3:])
