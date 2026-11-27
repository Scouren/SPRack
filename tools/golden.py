"""Byte-identical goldens: the gate a refactor must pass.

    python3 -I tools/golden.py snapshot <sprack> <out-dir> [--suite DIR] [--pdks DIR]
                                        [--mutants N] [--jobs N] [--only PREFIX]
    python3 -I tools/golden.py diff <dir-a> <dir-b> [--show N]

`snapshot` runs one binary over every case and keeps, for each, its exit
status, standard output and standard error. `diff` compares two snapshots
case by case, prints IDENTICAL or the cases that differ, and exits 1 when
any does. A refactor is done when the snapshot of the new binary is
IDENTICAL to the one taken before it; a behaviour change lands apart, with
the cases it moved named in its commit.

The cases, all read as data (nothing in a corpus is executed):

  corpus/   every deck of the conformance suite (SPRACK_SUITE, or --suite),
            read in its own dialect and as ngspice and HSPICE, written for
            every dialect (`translate`), read as JSON (`read`) and audited.
  pdk/      every model library of the test PDKs (SPRACK_TEST_PDKS, or
            --pdks) as a project for every dialect: the tree written, as
            one digest a file, and the report.
  mutant/   --mutants N damaged copies of each corpus deck (seeded, so two
            snapshots damage them alike), through one target each: the
            paths only wrong input reaches.

A snapshot holds `manifest.tsv` (case, exit status, digests) and one file a
case under `cases/`.
"""

import argparse
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

TARGETS = ["ngspice", "hspice", "xyce", "spectre", "vacask", "ltspice", "cdl"]
EXTRA_SOURCES = ["ngspice", "hspice"]
TIMEOUT_S = 300
SEPARATOR = b"\n--8<-- stderr --8<--\n"

# The libraries each test PDK is entered by, and the dialect they are in.
PDK_ENTRIES = [
    ("sky130", "ngspice", "sky130_fd_pr/models/sky130.lib.spice"),
    ("ihp-mos", "ngspice", "ihp/ihp-sg13g2/libs.tech/ngspice/models/cornerMOSlv.lib"),
    ("ihp-hbt", "ngspice", "ihp/ihp-sg13g2/libs.tech/ngspice/models/cornerHBT.lib"),
    ("ihp-res", "ngspice", "ihp/ihp-sg13g2/libs.tech/ngspice/models/cornerRES.lib"),
    ("ihp-cap", "ngspice", "ihp/ihp-sg13g2/libs.tech/ngspice/models/cornerCAP.lib"),
    ("asap7", "hspice", "asap7/models/hspice/7nm_TT.pm"),
    ("freepdk45", "hspice", "freepdk45/FreePDK45/ncsu_basekit/models/hspice/hspice_nom.include"),
    ("gf180", "ngspice", "gf180mcu/models/ngspice/sm141064.spice"),
]


def declared_dialect(path):
    """The dialect a suite deck is written in, as tools/corpus_audit.py reads it."""
    stem, ext = os.path.splitext(path)
    declared = "vacask" if ext == ".sim" else "ngspice"
    try:
        with open(stem + ".expected.json", encoding="utf-8") as f:
            oracle = json.load(f)
    except (OSError, ValueError):
        return declared
    if not isinstance(oracle, dict):
        return declared
    return oracle.get("tokenizer") or declared


def suite_decks(root):
    decks = []
    for directory, _, files in sorted(os.walk(root)):
        for name in sorted(files):
            if name.endswith((".sp", ".sim")):
                decks.append(os.path.relpath(os.path.join(directory, name), root))
    return decks


def corpus_cases(suite):
    """(case id, argv after the binary, cwd, stdin bytes or None)."""
    cases = []
    for deck in suite_decks(suite):
        own = declared_dialect(os.path.join(suite, deck))
        sources = [own] + ([s for s in EXTRA_SOURCES if s != own] if deck.endswith(".sp") else [])
        for source in sources:
            cases.append((f"corpus/read/{source}/{deck}", ["read", "--from", source, deck], suite, None))
            for target in TARGETS:
                pair = f"{source}-{target}"
                argv = ["--from", source, "--to", target, deck]
                cases.append((f"corpus/translate/{pair}/{deck}", ["translate"] + argv, suite, None))
                cases.append((f"corpus/audit/{pair}/{deck}", ["audit"] + argv, suite, None))
    return cases


def mutate(data, rng):
    """A damaged copy: a few bytes dropped, doubled, or replaced."""
    out = bytearray(data)
    for _ in range(rng.randint(1, 4)):
        if not out:
            break
        at = rng.randrange(len(out))
        action = rng.randrange(4)
        if action == 0:
            del out[at : at + rng.randint(1, 8)]
        elif action == 1:
            out[at:at] = out[at : at + rng.randint(1, 8)]
        elif action == 2:
            out[at] = rng.choice(b" \t\n+=(){}[]'\",.*$;:/\\-0123456789eEkKmMuUnNpP")
        else:
            out[at] = rng.randrange(256)
    return bytes(out)


def mutant_cases(suite, count):
    cases = []
    for index, deck in enumerate(suite_decks(suite)):
        path = os.path.join(suite, deck)
        own = declared_dialect(path)
        with open(path, "rb") as f:
            data = f.read()
        for n in range(count):
            rng = random.Random(f"{deck}#{n}")
            target = TARGETS[(index + n) % len(TARGETS)]
            argv = ["translate", "--from", own, "--to", target]
            cases.append((f"mutant/{own}-{target}/{deck}#{n}", argv, suite, mutate(data, rng)))
    return cases


def pdk_cases(pdks):
    cases = []
    for name, source, entry in PDK_ENTRIES:
        if not os.path.exists(os.path.join(pdks, entry)):
            continue
        for target in TARGETS:
            argv = ["project", "--from", source, "--to", target, "--lib", "--out", "@OUT@", entry]
            cases.append((f"pdk/{name}/{source}-{target}", argv, pdks, None))
    return cases


def tree_digest(root):
    """Every file under `root` as `path sha256`, sorted: the tree as text."""
    lines = []
    for directory, _, files in os.walk(root):
        for name in files:
            path = os.path.join(directory, name)
            with open(path, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            lines.append(f"{os.path.relpath(path, root)} {digest}")
    return ("\n".join(sorted(lines)) + "\n").encode()


def run_case(binary, case):
    case_id, argv, cwd, stdin = case
    out_dir = None
    if "@OUT@" in argv:
        out_dir = tempfile.mkdtemp(prefix="golden-")
        argv = [out_dir if a == "@OUT@" else a for a in argv]
    try:
        done = subprocess.run([binary] + argv, cwd=cwd, input=stdin if stdin is not None else b"",
                              capture_output=True, timeout=TIMEOUT_S)
        status, stdout, stderr = done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired:
        status, stdout, stderr = -999, b"", b"timeout"
    if out_dir is not None:
        # The report names no output path; the tree stands in for stdout.
        stdout = tree_digest(out_dir)
        shutil.rmtree(out_dir, ignore_errors=True)
    return case_id, status, stdout, stderr


def snapshot(args):
    suite = args.suite or os.environ.get("SPRACK_SUITE", "")
    pdks = args.pdks or os.environ.get("SPRACK_TEST_PDKS", "")
    binary = os.path.abspath(args.binary)
    cases = []
    if suite:
        tests = os.path.join(suite, "tests") if os.path.isdir(os.path.join(suite, "tests")) else suite
        cases += corpus_cases(tests)
        cases += mutant_cases(tests, args.mutants)
    if pdks:
        cases += pdk_cases(pdks)
    if args.only:
        cases = [c for c in cases if c[0].startswith(args.only)]
    if not cases:
        sys.exit("no cases: give --suite and/or --pdks (or SPRACK_SUITE, SPRACK_TEST_PDKS)")
    body_dir = os.path.join(args.out, "cases")
    os.makedirs(body_dir, exist_ok=True)
    rows = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for case_id, status, stdout, stderr in pool.map(lambda c: run_case(binary, c), cases):
            body = stdout + SEPARATOR + stderr
            name = hashlib.sha256(case_id.encode()).hexdigest()[:24]
            with open(os.path.join(body_dir, name), "wb") as f:
                f.write(body)
            rows.append(f"{case_id}\t{status}\t{hashlib.sha256(body).hexdigest()}\t{name}\n")
    with open(os.path.join(args.out, "manifest.tsv"), "w", encoding="utf-8") as f:
        f.writelines(sorted(rows))
    crashes = sum(1 for r in rows if r.split("\t")[1] not in ("0", "1", "2"))
    print(f"{len(rows)} cases -> {args.out} ({crashes} with a status other than 0, 1 or 2)")


def load_manifest(root):
    rows = {}
    with open(os.path.join(root, "manifest.tsv"), encoding="utf-8") as f:
        for line in f:
            case_id, status, digest, name = line.rstrip("\n").split("\t")
            rows[case_id] = (status, digest, name)
    return rows


def show_difference(case_id, a_root, a_row, b_root, b_row):
    import difflib

    print(f"--- {case_id}: status {a_row[0]} -> {b_row[0]}")
    with open(os.path.join(a_root, "cases", a_row[2]), "rb") as f:
        a_text = f.read().decode("utf-8", "replace").splitlines()
    with open(os.path.join(b_root, "cases", b_row[2]), "rb") as f:
        b_text = f.read().decode("utf-8", "replace").splitlines()
    for line in list(difflib.unified_diff(a_text, b_text, "before", "after", lineterm="", n=1))[:40]:
        print("    " + line)


def diff(args):
    a, b = load_manifest(args.a), load_manifest(args.b)
    missing = sorted(set(a) ^ set(b))
    changed = sorted(c for c in set(a) & set(b) if a[c][:2] != b[c][:2])
    if not missing and not changed:
        print(f"IDENTICAL ({len(a)} cases)")
        return
    for case_id in missing:
        print(f"only in {'before' if case_id in a else 'after'}: {case_id}")
    for case_id in changed[: args.show]:
        show_difference(case_id, args.a, a[case_id], args.b, b[case_id])
    for case_id in changed[args.show :]:
        print(f"differs: {case_id}")
    print(f"DIFFERENT: {len(changed)} of {len(a)} cases differ, {len(missing)} in one snapshot only")
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    snap = commands.add_parser("snapshot")
    snap.add_argument("binary")
    snap.add_argument("out")
    snap.add_argument("--suite", default="")
    snap.add_argument("--pdks", default="")
    snap.add_argument("--mutants", type=int, default=2)
    snap.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 1))
    snap.add_argument("--only", default="")
    snap.set_defaults(run=snapshot)
    compare = commands.add_parser("diff")
    compare.add_argument("a")
    compare.add_argument("b")
    compare.add_argument("--show", type=int, default=5)
    compare.set_defaults(run=diff)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
