import sys, csv, collections
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t", quoting=csv.QUOTE_NONE))
if len(sys.argv) > 2 and sys.argv[2]: rows = [r for r in rows if r["from"] == sys.argv[2]]
topn = int(sys.argv[3]) if len(sys.argv) > 3 else 45
I = lambda r, k: int(r[k] or 0)
print("runs:", len(rows), " files:", len({r["file"] for r in rows}))
bad = [r for r in rows if r["rc"] != "0"]
print("non-zero exit (crash/timeout):", len(bad))
for r in bad[:10]: print("   ", r["file"], r["from"], "->", r["to"], "rc", r["rc"], r.get("stmts"))

src = {}
for r in rows:
    if r["rc"] == "0": src[(r["file"], r["from"])] = r
tot = sum(I(r, "stmts") for r in src.values()); opq = sum(I(r, "opaque") for r in src.values())
clean = sum(1 for r in src.values() if I(r, "opaque") == 0)
print(f"\nREADING: {tot} statements in {len(src)} files; {tot-opq} understood ({100*(tot-opq)/tot:.1f}%), {opq} not; files fully understood: {clean} ({100*clean/len(src):.0f}%)")
keys = collections.Counter(); kfiles = collections.Counter()
for r in src.values():
    for kv in filter(None, (r.get("keys") or "").split(",")):
        k, _, n = kv.rpartition(":"); keys[k] += int(n); kfiles[k] += 1
print("  lines not understood, by first word (count / files):")
for k, n in keys.most_common(topn): print(f"    {k:<16}{n:>6} / {kfiles[k]}")

print("\nWRITING, per target:")
print(f"  {'target':<9}{'files':>6}{'same':>6}{'explained':>10}{'SILENT':>8}{'reread?':>9}{'err files':>10}  untranslated/unsupported/loss/synth/caveat/rename")
silent = []
for t in ["ngspice", "hspice", "xyce", "spectre", "vacask"]:
    rs = [r for r in rows if r["to"] == t and r["rc"] == "0"]
    same = sum(1 for r in rs if r["same"] == "1")
    expl = 0
    for r in rs:
        if r["same"] == "1": continue
        excuse = I(r, "untranslated") + I(r, "unsupported") + I(r, "loss") + I(r, "synthesized") + I(r, "invalid") + I(r, "ambiguous") + I(r, "oneway") + I(r, "rename")
        if excuse: expl += 1
        else: silent.append(r)
    rr = sum(1 for r in rs if I(r, "reread_opaque") > (I(r, "opaque") if r["from"] == t else 0))
    ef = sum(1 for r in rs if I(r, "errors") > 0)
    s = lambda k: sum(I(r, k) for r in rs)
    print(f"  {t:<9}{len(rs):>6}{same:>6}{expl:>10}{len([x for x in silent if x['to']==t]):>8}{rr:>9}{ef:>10}  {s('untranslated')}/{s('unsupported')}/{s('loss')}/{s('synthesized')}/{s('caveat')}/{s('rename')}")
print("\nSILENT differences (same=0 with nothing in the report):", len(silent))
for r in silent[:25]: print("   ", r["from"], "->", r["to"], r["file"], "stmts", r["stmts"])
open(sys.argv[1] + ".silent", "w").write("\n".join(f"{r['from']}\t{r['to']}\t{r['file']}" for r in silent))
