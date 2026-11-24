"""Summarize a corpus audit (corpus_audit.py's table).

Usage: python3 -I corpus_summary.py <audit.tsv> [from] [top-n]

Runs that read a deck in the dialect it is written in (`from` = `declared`)
are counted apart from those that read it in another: the second kind's
errors are mostly the wrong reader's. A deck the suite expects to be refused
(`expect` = error) whose translation reports an error agrees with its oracle
and is listed apart, not counted as a failure. A table from before these
columns is read as if every run were the deck's own.
"""
import sys, csv, collections

rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t", quoting=csv.QUOTE_NONE))
if len(sys.argv) > 2 and sys.argv[2]:
    rows = [r for r in rows if r["from"] == sys.argv[2]]
topn = int(sys.argv[3]) if len(sys.argv) > 3 else 45
I = lambda r, k: int(r.get(k) or 0)
own = lambda r: r.get("declared", r["from"]) in ("", None, r["from"])
refused = lambda r: r.get("expect") == "error"
ran = lambda r: r["rc"] in ("0", "1")  # 1: a silent difference (issue 54)
EXCUSES = ("untranslated", "unsupported", "loss", "synthesized", "invalid", "ambiguous", "oneway", "rename")

print("runs:", len(rows), " files:", len({r["file"] for r in rows}), " own-dialect runs:", sum(1 for r in rows if own(r)))
bad = [r for r in rows if not ran(r)]
print("crashes and timeouts:", len(bad))
for r in bad[:10]:
    print("   ", r["file"], r["from"], "->", r["to"], "rc", r["rc"], r.get("stmts"))

for label, pick in (("OWN DIALECT", own), ("OTHER DIALECT", lambda r: not own(r))):
    sel = [r for r in rows if pick(r)]
    if not sel:
        continue
    src = {}
    for r in sel:
        if ran(r):
            src[(r["file"], r["from"])] = r
    tot = sum(I(r, "stmts") for r in src.values()) or 1
    opq = sum(I(r, "opaque") for r in src.values())
    clean = sum(1 for r in src.values() if I(r, "opaque") == 0)
    print(f"\n{label}\nREADING: {tot} statements in {len(src)} files; {tot-opq} understood ({100*(tot-opq)/tot:.1f}%), {opq} not; files fully understood: {clean}")
    keys = collections.Counter(); kfiles = collections.Counter()
    for r in src.values():
        for kv in filter(None, (r.get("keys") or "").split(",")):
            k, _, n = kv.rpartition(":"); keys[k] += int(n); kfiles[k] += 1
    print("  lines not understood, by first word (count / files):")
    for k, n in keys.most_common(topn):
        print(f"    {k:<16}{n:>6} / {kfiles[k]}")
    print("WRITING, per target (decks expected to be refused apart):")
    print(f"  {'target':<9}{'files':>6}{'same':>6}{'explained':>10}{'SILENT':>8}{'reread?':>9}{'err files':>10}{'refused ok':>11}  untranslated/unsupported/loss/synth/caveat/rename")
    for t in ["ngspice", "hspice", "xyce", "spectre", "vacask"]:
        rs = [r for r in sel if r["to"] == t and ran(r)]
        agree = [r for r in rs if refused(r) and I(r, "errors") > 0]
        rs = [r for r in rs if r not in agree]
        same = sum(1 for r in rs if r["same"] == "1")
        expl = sum(1 for r in rs if r["same"] != "1" and sum(I(r, k) for k in EXCUSES))
        silent = sum(1 for r in rs if r["same"] != "1" and not sum(I(r, k) for k in EXCUSES))
        rr = sum(1 for r in rs if I(r, "reread_opaque") > (I(r, "opaque") if r["from"] == t else 0))
        ef = sum(1 for r in rs if I(r, "errors") > 0)
        s = lambda k: sum(I(r, k) for r in rs)
        print(f"  {t:<9}{len(rs):>6}{same:>6}{expl:>10}{silent:>8}{rr:>9}{ef:>10}{len(agree):>11}  {s('untranslated')}/{s('unsupported')}/{s('loss')}/{s('synthesized')}/{s('caveat')}/{s('rename')}")

refused_ok = sorted({r["file"] for r in rows if ran(r) and own(r) and refused(r) and I(r, "errors") > 0})
print(f"\nDecks expected to be refused that a translation refuses too: {len(refused_ok)}")
for f in refused_ok[:25]:
    print("   ", f)
silent = [r for r in rows if ran(r) and r["same"] != "1" and not sum(I(r, k) for k in EXCUSES)]
print("\nSILENT differences (same=0 with nothing in the report):", len(silent))
for r in silent[:25]:
    print("   ", r["from"], "->", r["to"], r["file"], "stmts", r["stmts"])
open(sys.argv[1] + ".silent", "w").write("\n".join(f"{r['from']}\t{r['to']}\t{r['file']}" for r in silent))
