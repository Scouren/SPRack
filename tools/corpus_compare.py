"""Gate a corpus audit against the committed baseline.

Usage: python3 -I corpus_compare.py <baseline> <new.tsv> [--update]
Fails if any run is SILENT (as corpus_summary.py counts it), or if crashes
or the error count for any target rise against the baseline. The baseline is
a summary: `runs`, `crashes` and each target's error count, one per line.
`--update` rewrites it from <new.tsv> when the gate passes.
"""
import sys, csv, collections

EXCUSES = ("untranslated", "unsupported", "loss", "synthesized", "invalid", "ambiguous", "oneway", "rename")


def tally(path):
    rows = list(csv.DictReader(open(path), delimiter="\t", quoting=csv.QUOTE_NONE))
    I = lambda r, k: int(r[k] or 0)
    ok = [r for r in rows if r["rc"] == "0"]
    errors = collections.Counter()
    for r in ok:
        errors[r["to"]] += I(r, "errors")
    silent = [r for r in ok if r["same"] != "1" and not sum(I(r, k) for k in EXCUSES)]
    return len(rows), len(rows) - len(ok), errors, silent


def summary(path):
    vals = dict(line.split("\t") for line in open(path).read().splitlines() if line)
    return int(vals.pop("runs")), int(vals.pop("crashes")), collections.Counter({k: int(v) for k, v in vals.items()})


base_runs, base_crash, base_err = summary(sys.argv[1])
runs, crash, err, silent = tally(sys.argv[2])
fail = []
print(f"runs {base_runs} -> {runs}; crashes {base_crash} -> {crash}; SILENT {len(silent)}")
if crash > base_crash:
    fail.append("crashes rose")
if silent:
    fail.append(f"{len(silent)} SILENT")
    for r in silent[:25]:
        print("  silent:", r["from"], "->", r["to"], r["file"])
for t in sorted(set(base_err) | set(err)):
    mark = "  <- rose" if err[t] > base_err[t] else ""
    print(f"  errors to {t:<8}{base_err[t]:>7} -> {err[t]}{mark}")
    if mark:
        fail.append(f"errors to {t} rose")
if fail:
    sys.exit("FAIL: " + "; ".join(fail))
if "--update" in sys.argv[3:]:
    with open(sys.argv[1], "w") as f:
        f.write(f"runs\t{runs}\ncrashes\t{crash}\n" + "".join(f"{t}\t{err[t]}\n" for t in sorted(err)))
print("ok")
