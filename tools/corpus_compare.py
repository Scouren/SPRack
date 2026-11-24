"""Gate a corpus audit against the committed baseline.

Usage: python3 -I corpus_compare.py <baseline> <new.tsv> [--update]
Fails if any run is SILENT (as corpus_summary.py counts it), or if crashes
or an error count rise against the baseline. Errors are counted per target,
apart for runs in the deck's own dialect (`own.<target>`) and in another
(`other.<target>`); a deck the suite expects to be refused whose
translation reports an error is not counted (issue 59). The baseline is a
summary: `runs`, `crashes` and each count, one per line. A key the baseline
does not have yet gates nothing; `--update` rewrites it from <new.tsv> when
the gate passes.
"""
import sys, csv, collections

EXCUSES = ("untranslated", "unsupported", "loss", "synthesized", "invalid", "ambiguous", "oneway", "rename")


def tally(path):
    rows = list(csv.DictReader(open(path), delimiter="\t", quoting=csv.QUOTE_NONE))
    I = lambda r, k: int(r.get(k) or 0)
    ok = [r for r in rows if r["rc"] in ("0", "1")]  # 1: a silent difference (issue 54)
    errors = collections.Counter()
    for r in ok:
        if r.get("expect") == "error" and I(r, "errors") > 0:
            continue
        own = r.get("declared", r["from"]) in ("", None, r["from"])
        errors[("own." if own else "other.") + r["to"]] += I(r, "errors")
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
    known = t in base_err
    mark = "  <- rose" if known and err[t] > base_err[t] else ("  (new)" if not known else "")
    print(f"  errors {t:<14}{base_err[t] if known else '-':>7} -> {err[t]}{mark}")
    if known and err[t] > base_err[t]:
        fail.append(f"errors {t} rose")
if fail:
    sys.exit("FAIL: " + "; ".join(fail))
if "--update" in sys.argv[3:]:
    with open(sys.argv[1], "w") as f:
        f.write(f"runs\t{runs}\ncrashes\t{crash}\n" + "".join(f"{t}\t{err[t]}\n" for t in sorted(err)))
print("ok")
