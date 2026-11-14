"""Run `sprack audit` over every SPICE deck in a directory tree.

Usage: python3 -I audit_all.py <sprack-binary> <fixtures-root> <out.tsv>
The fixtures are read as data only; nothing in that tree is executed.
"""
import subprocess, sys, os, time
from concurrent.futures import ThreadPoolExecutor

sprack_bin, root, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
targets = ["ngspice", "hspice", "xyce", "spectre", "vacask"]
sources = sys.argv[4].split(",") if len(sys.argv) > 4 else ["ngspice"]

jobs = []
for dp, _, files in os.walk(root):
    for f in sorted(files):
        p = os.path.join(dp, f)
        rel = os.path.relpath(p, root)
        if f.endswith(".sp"):
            for frm in sources:
                jobs += [(frm, t, p, rel) for t in targets]
        elif f.endswith(".sim"):
            jobs += [("vacask", t, p, rel) for t in targets]

def run(job):
    frm, to, path, rel = job
    t0 = time.time()
    try:
        r = subprocess.run([sprack_bin, "audit", "--from", frm, "--to", to, path], capture_output=True, timeout=120)
        rc, line, err = r.returncode, r.stdout.decode("utf-8", "replace").strip(), r.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        rc, line, err = -999, "", "timeout"
    ms = int((time.time() - t0) * 1000)
    cols = line.split("\t")[1:] if line else []
    return [rel, frm, to, str(rc), str(ms)] + cols + ([err.strip().splitlines()[0][:200]] if rc not in (0,) and err.strip() else [])

t0 = time.time()
with ThreadPoolExecutor(max_workers=2) as ex:
    rows = list(ex.map(run, jobs))
with open(out_path, "w") as f:
    f.write("file\tfrom\tto\trc\tms\tstmts\topaque\tsame\terrors\tuntranslated\tunsupported\tloss\tsynthesized\tcaveat\trename\tcosmetic\tinvalid\tambiguous\toneway\treread_opaque\tkeys\n")
    for r in rows:
        f.write("\t".join(r) + "\n")
print(f"{len(jobs)} runs over {len({j[3] for j in jobs})} files in {time.time()-t0:.0f}s -> {out_path}")
