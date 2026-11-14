"""Generate large ngspice netlists for memory and speed benchmarks.

Usage:
  python3 -I tools/gen_bench.py mesh <n> <out.sp>    n x n RC mesh, ~2n^2 R + n^2 C
  python3 -I tools/gen_bench.py cat <dir> <out.sp>   every *.spice / *.sp under dir, flattened

The outputs are large; keep them out of git.
"""
import os, sys


def mesh(n, out):
    w = out.write
    w(f"* {n}x{n} RC mesh\n.param rval=1k cval=1f\n")
    w("V1 n0_0 0 PULSE(0 1.8 0 10p 10p 1n 2n)\n")
    for i in range(n):
        for j in range(n):
            a = f"n{i}_{j}"
            if j + 1 < n:
                w(f"R{i}_{j}h {a} n{i}_{j + 1} {{rval*1.01}}\n")
            if i + 1 < n:
                w(f"R{i}_{j}v {a} n{i + 1}_{j} 1.5k\n")
            w(f"C{i}_{j} {a} 0 {{cval}} $ cap at {a}\n")
    w(".tran 1p 10n\n.end\n")


def cat(root, out):
    out.write("* flattened library\n")
    for dp, _, files in sorted(os.walk(root)):
        for f in sorted(files):
            if not (f.endswith(".spice") or f.endswith(".sp")):
                continue
            with open(os.path.join(dp, f), errors="replace") as src:
                for line in src:
                    # `.end` would stop the read; `.include` would point nowhere.
                    low = line.strip().lower()
                    if low == ".end" or low.startswith(".include") or low.startswith(".lib"):
                        continue
                    out.write(line)
    out.write(".end\n")


if __name__ == "__main__":
    mode, arg, path = sys.argv[1:4]
    with open(path, "w") as f:
        mesh(int(arg), f) if mode == "mesh" else cat(arg, f)
