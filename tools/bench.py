"""Speed of the command on large netlists: the number a faster path must move.

    python3 -I tools/bench.py <sprack> [<other-sprack>] [--pdks DIR] [--runs N] [--work DIR]

Each row is one translation of one netlist, run N times (3 by default); the
fastest run counts, since everything else on the machine only adds time. The
time is the process's own (user plus system), not the wall clock, and with
`perf` on PATH the instructions it retired are counted too: on a machine that
is doing other work those two hold still where the wall clock does not. With
a second binary the same rows are measured for it, and the last column is
how many times faster the first is (by instructions when counted, else by
time).

The netlists are made once into --work (a temporary directory otherwise):

  mesh    a 500 x 500 RC mesh, 27 MB of flat R and C lines with expressions
          and trailing comments (tools/gen_bench.py).
  cells   every .spice file of sky130's cells in one file, when --pdks (or
          SPRACK_TEST_PDKS) names the PDK trees: subcircuits, MOSFETs,
          parameters, model cards.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TARGETS = ["ngspice", "spectre", "xyce", "vacask"]


def make_netlists(work, pdks):
    """(name, path) for each benchmark netlist, generated when missing."""
    generator = os.path.join(HERE, "gen_bench.py")
    netlists = []
    mesh = os.path.join(work, "mesh500.sp")
    if not os.path.exists(mesh):
        subprocess.run([sys.executable, "-I", generator, "mesh", "500", mesh], check=True)
    netlists.append(("mesh", mesh))
    cells_root = os.path.join(pdks, "sky130_fd_pr", "cells") if pdks else ""
    if cells_root and os.path.isdir(cells_root):
        cells = os.path.join(work, "sky130cells.sp")
        if not os.path.exists(cells):
            subprocess.run([sys.executable, "-I", generator, "cat", cells_root, cells], check=True)
        netlists.append(("cells", cells))
    return netlists


def run_once(binary, target, path, perf):
    """(cpu seconds, instructions or 0, peak resident KiB) of one translation to /dev/null."""
    argv = [binary, "translate", "--from", "ngspice", "--to", target, path, "-o", os.devnull]
    counts = ""
    if perf:
        counts = os.path.join(tempfile.gettempdir(), f"sprack-bench-{os.getpid()}.perf")
        argv = [perf, "stat", "-x,", "-e", "instructions:u", "-o", counts, "--"] + argv
    child = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, status, usage = os.wait4(child.pid, 0)
    child.returncode = os.waitstatus_to_exitcode(status)
    if child.returncode not in (0, 1):
        sys.exit(f"{' '.join(argv)}: exit status {child.returncode}")
    instructions = 0
    if perf:
        with open(counts, encoding="utf-8") as f:
            for line in f:
                fields = line.split(",")
                if len(fields) > 2 and fields[2].startswith("instructions") and fields[0].isdigit():
                    instructions = int(fields[0])
        os.remove(counts)
    return usage.ru_utime + usage.ru_stime, instructions, usage.ru_maxrss


def best(binary, target, path, runs, perf):
    return min(run_once(binary, target, path, perf) for _ in range(runs))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("binary")
    parser.add_argument("other", nargs="?")
    parser.add_argument("--pdks", default=os.environ.get("SPRACK_TEST_PDKS", ""))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--work", default="")
    args = parser.parse_args()
    work = args.work or tempfile.mkdtemp(prefix="sprack-bench-")
    os.makedirs(work, exist_ok=True)

    perf = shutil.which("perf") or ""
    header = (f"{'netlist':8} {'to':8} {'MB':>6} {'lines':>9} {'cpu s':>7} {'MB/s':>7} "
              f"{'ns/line':>8} {'instr/line':>10} {'peak MB':>8}")
    print(header + (f" {'other s':>8} {'faster':>7}" if args.other else ""))
    for name, path in make_netlists(work, args.pdks):
        megabytes = os.path.getsize(path) / 1e6
        with open(path, "rb") as f:
            lines = sum(chunk.count(b"\n") for chunk in iter(lambda: f.read(1 << 20), b""))
        for target in TARGETS:
            seconds, instructions, peak = best(args.binary, target, path, args.runs, perf)
            row = (f"{name:8} {target:8} {megabytes:6.1f} {lines:9d} {seconds:7.3f} "
                   f"{megabytes / seconds:7.1f} {seconds / lines * 1e9:8.0f} "
                   f"{instructions / lines:10.0f} {peak / 1024:8.1f}")
            if args.other:
                other_s, other_i, _ = best(args.other, target, path, args.runs, perf)
                ratio = other_i / instructions if instructions else other_s / seconds
                row += f" {other_s:8.3f} {ratio:6.2f}x"
            print(row, flush=True)


if __name__ == "__main__":
    main()
