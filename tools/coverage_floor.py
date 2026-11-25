"""Hold each file's line coverage to its recorded floor (issue 65).

Usage:
  python3 -I tools/coverage_floor.py zig  <kcov-dir> <floor.tsv> [--update]
  python3 -I tools/coverage_floor.py py   <py_coverage.tsv> <floor.tsv> [--update]

The first form reads kcov's report (`zig build coverage` writes it into
zig-out/coverage; the merged `kcov-merged/coverage.json`, or the one
under the test binary's directory); the second, tools/py_coverage.py's
table. A file whose line coverage falls more than one point below its
floor fails the run; --update writes the floor from this run. A floor
file that does not exist yet is written and gates nothing.
"""
import glob, json, os, sys

kind, src, floor_path = sys.argv[1], sys.argv[2], sys.argv[3]
cover = {}
if kind == "zig":
    found = sorted(glob.glob(os.path.join(src, "**", "coverage.json"), recursive=True), key=lambda p: ("kcov-merged" not in p, p))
    if not found:
        sys.exit(f"no coverage.json under {src}: run `zig build coverage` first")
    for f in json.load(open(found[0]))["files"]:
        path = f["file"]
        at = path.find("/src/")
        cover[path[at + 1:] if at >= 0 else path] = float(f["percent_covered"])
else:
    for line in open(src).read().splitlines()[1:]:
        name, pct = line.split("\t")[:2]
        cover[name] = float(pct)

floor = {}
if os.path.exists(floor_path):
    for line in open(floor_path).read().splitlines()[1:]:
        name, pct = line.split("\t")[:2]
        floor[name] = float(pct)
fail = []
for name in sorted(cover):
    was = floor.get(name)
    mark = ""
    if was is not None and cover[name] < was - 1.0:
        mark = "  <- below its floor"
        fail.append(name)
    print(f"{name:<32}{cover[name]:>7.1f}%{'' if was is None else f'   floor {was:.1f}%'}{mark}")
if "--update" in sys.argv[4:] or not floor:
    with open(floor_path, "w") as f:
        f.write("file\tlines_covered_percent\n" + "".join(f"{n}\t{cover[n]:.1f}\n" for n in sorted(cover)))
    print(f"floor written to {floor_path}")
elif fail:
    sys.exit(f"FAIL: line coverage fell more than one point in {', '.join(fail)}")
