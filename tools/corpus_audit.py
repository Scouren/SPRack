"""Run `sprack audit` over every SPICE deck in a directory tree.

Usage: python3 -I corpus_audit.py <sprack-binary> <fixtures-root> <out.tsv> [sources]
The fixtures are read as data only; nothing in that tree is executed.

Each deck is read in the dialect it is written in: the `tokenizer` its
oracle (`<stem>.expected.json` beside it) names, else ngspice; a `.sim`
file is VACASK. `sources` (comma-separated, default ngspice) adds reads in
other dialects as well: they still find reader bugs, and the silent gate
holds for them, but their errors are artefacts of the wrong reader, so the
`declared` column tells them apart. The `expect` column is the oracle's
`expect.status` (`error` for a deck the suite expects to be refused, else
`success`). `sprack audit` exits 1 for a silent difference (issue 54);
that row is kept and the status is in `rc`.
"""
import json, subprocess, sys, os, time
from concurrent.futures import ThreadPoolExecutor

sprack_bin, root, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
targets = ["ngspice", "hspice", "xyce", "spectre", "vacask"]
sources = sys.argv[4].split(",") if len(sys.argv) > 4 else ["ngspice"]


def oracle(path):
    """(declared dialect, expected status) from the oracle beside a deck."""
    stem, ext = os.path.splitext(path)
    if ext == ".sim":
        declared = "vacask"
    else:
        declared = "ngspice"
    try:
        with open(stem + ".expected.json", encoding="utf-8") as f:
            o = json.load(f)
    except (OSError, ValueError):
        return declared, "success"
    if not isinstance(o, dict):
        return declared, "success"
    expect = o.get("expect") if isinstance(o.get("expect"), dict) else {}
    status = "error" if expect.get("status") == "error" else "success"
    return (o.get("tokenizer") or declared), status


jobs = []
for dp, _, files in os.walk(root):
    for f in sorted(files):
        p = os.path.join(dp, f)
        rel = os.path.relpath(p, root)
        if not (f.endswith(".sp") or f.endswith(".sim")):
            continue
        declared, expect = oracle(p)
        froms = [declared] + ([s for s in sources if s != declared] if f.endswith(".sp") else [])
        for frm in froms:
            jobs += [(frm, t, p, rel, declared, expect) for t in targets]


def run(job):
    frm, to, path, rel, declared, expect = job
    t0 = time.time()
    try:
        r = subprocess.run([sprack_bin, "audit", "--from", frm, "--to", to, path], capture_output=True, timeout=120)
        rc, line, err = r.returncode, r.stdout.decode("utf-8", "replace").strip(), r.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        rc, line, err = -999, "", "timeout"
    ms = int((time.time() - t0) * 1000)
    cols = line.split("\t")[1:] if line else []
    return [rel, frm, to, declared, expect, str(rc), str(ms)] + cols + ([err.strip().splitlines()[0][:200]] if rc not in (0, 1) and err.strip() else [])


t0 = time.time()
with ThreadPoolExecutor(max_workers=2) as ex:
    rows = list(ex.map(run, jobs))
with open(out_path, "w") as f:
    f.write("file\tfrom\tto\tdeclared\texpect\trc\tms\tstmts\topaque\tsame\terrors\tuntranslated\tunsupported\tloss\tsynthesized\tcaveat\trename\tcosmetic\tinvalid\tambiguous\toneway\treread_opaque\tkeys\n")
    for r in rows:
        f.write("\t".join(r) + "\n")
print(f"{len(jobs)} runs over {len({j[3] for j in jobs})} files in {time.time()-t0:.0f}s -> {out_path}")
