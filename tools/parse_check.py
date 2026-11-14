"""Load every error-free translation in its target simulator.

Usage: python3 -I tools/parse_check.py <sprack> <suite/tests> <audit.tsv> <out.tsv>
           [--targets ngspice,xyce,vacask] [--timeout 10] [--jobs N] [--work DIR] [--only TEXT]

For each audit row with rc 0 and 0 errors whose target is one of --targets
(round trips included, as a control), the deck is translated and the target
loads it:

    ngspice  ngspice -b -n deck    no -r: parses and binds, runs only .print/.plot/.four decks
    xyce     Xyce -norun deck      syntax and topology, no analysis
    vacask   vacask --no-output -sp deck   (no parse-only mode: a full run)

Each source deck is loaded once in its own simulator the same way (HSPICE has
no free simulator, so an hspice-read deck is checked with ngspice in its
HSPICE compatibility mode, ngbehavior=hsa). A failure counts only when the
source loads; otherwise the row is `excluded`.

Every run gets its own directory of symlinks to the deck's neighbours, so
relative includes resolve, and is killed after --timeout seconds. Results are
loaded, syntax, runtime or timeout. out.tsv lists every row that did not load,
with the simulator's error lines; a summary per target goes to stdout. The
suite is read as data only.
"""
import argparse, csv, os, re, shutil, subprocess, sys, tempfile, time
from collections import Counter
from concurrent.futures import ProcessPoolExecutor

EXT = {"ngspice": ".cir", "xyce": ".cir", "vacask": ".sim", "hspice": ".sp"}
# Lines that are errors; a match on RUNTIME makes it a runtime error.
ERROR = re.compile(r"error|unknown|not found|undefined|cannot|can't|could not|unrecognized|abort|interrupted|fatal|failed|invalid|illegal|missing|unexpected", re.I)
BENIGN = re.compile(r"no simulations run|incomplete or empty netlist|or no \"\.plot\"|MSG_FATAL errors and \d+ MSG_ERROR|^\*\*\* Xyce Abort|^\s*errors\s*$|unknown\.$|compatibility mode", re.I)
RUNTIME = re.compile(r"timestep too small|singular|gmin stepping|source stepping|iteration limit|no convergence|doAnalyses|analysis failed|converge|"
                     r"factorization failed|homotopy failed|analysis '\w+' aborted|dc solution failed|measure '", re.I)
# ngspice warnings are not failures, except an instance dropped for want of its model.
WARNING = re.compile(r"^\s*warning\b(?!.*can't find model)|<<NAN, error", re.I)


def command(sim, deck, dialect):
    if sim == "ngspice":
        return ["ngspice", "-b", "-n"] + (["-D", "ngbehavior=hsa"] if dialect == "hspice" else []) + [deck]
    if sim == "xyce":
        return ["Xyce", "-norun", deck]
    return ["vacask", "-qp", "--no-output", "-sp", deck]


def farm(src, work, name):
    """A directory of symlinks to src's neighbours, so relative paths resolve."""
    d = tempfile.mkdtemp(dir=work)
    for e in os.listdir(os.path.dirname(src)):
        if e != name:
            os.symlink(os.path.join(os.path.dirname(src), e), os.path.join(d, e))
    return d


def classify(sim, rc, out):
    lines = [l.rstrip() for l in out.splitlines()]
    errs, skip = [], -1
    for i, l in enumerate(lines):
        if i != skip and ERROR.search(l) and not BENIGN.search(l) and not WARNING.search(l):
            # ngspice and Xyce put the reason on the line after "Error on line N" / "Netlist error in ...".
            nxt = lines[i + 1].strip() if i + 1 < len(lines) and lines[i + 1].startswith(" ") else ""
            skip = i + 1 if nxt else -1
            errs.append((l.strip() + (" :: " + nxt if nxt else ""))[:300])
    errs = list(dict.fromkeys(errs))
    # ngspice -b exits 1 when it parsed everything and found nothing to run, so only its messages count.
    if not errs and (rc == 0 or sim == "ngspice"):
        return "loaded", ""
    kind = "runtime" if any(RUNTIME.search(e) for e in errs) else "syntax"
    return kind, " | ".join(errs[:6]) or f"exit {rc}"


def run(job):
    """job = (sprack, path, rel, frm, sim, timeout, work); sim None = load the source itself."""
    sprack, path, rel, frm, sim, timeout, work = job
    base = os.path.splitext(os.path.basename(path))[0]
    d = farm(path, work, os.path.basename(path))
    try:
        if sim is None:
            deck, dialect = os.path.join(d, os.path.basename(path)), frm
            os.symlink(path, deck)
            sim = "ngspice" if frm == "hspice" else frm
        else:
            dialect = sim
            deck = os.path.join(d, base + ".x" + EXT[sim])
            t = subprocess.run([sprack, "translate", "--from", frm, "--to", sim, path, "-o", deck], capture_output=True, timeout=60)
            if t.returncode != 0 or not os.path.exists(deck):
                return (rel, frm, sim, "translate", t.stderr.decode(errors="replace").strip()[-300:])
        try:
            p = subprocess.run(command(sim, os.path.basename(deck), dialect),
                               cwd=d, capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return (rel, frm, sim, "timeout", f"killed after {timeout}s")
        return (rel, frm, sim) + classify(sim, p.returncode, p.stdout.decode(errors="replace") + "\n" + p.stderr.decode(errors="replace"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sprack"); ap.add_argument("tests"); ap.add_argument("audit"); ap.add_argument("out")
    ap.add_argument("--targets", default="ngspice,xyce,vacask")
    ap.add_argument("--timeout", type=float, default=10)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--work", default=None)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    sprack, tests = os.path.abspath(a.sprack), os.path.abspath(a.tests)
    targets = a.targets.split(",")
    rows = [r for r in csv.DictReader(open(a.audit), delimiter="\t", quoting=csv.QUOTE_NONE)
            if r["rc"] == "0" and r["errors"] == "0" and r["to"] in targets and a.only in r["file"]]
    work = tempfile.mkdtemp(prefix="parse_check.", dir=a.work)
    sources = sorted({(r["file"], r["from"]) for r in rows})
    jobs = [(sprack, os.path.join(tests, f), f, frm, None, a.timeout, work) for f, frm in sources]
    jobs += [(sprack, os.path.join(tests, r["file"]), r["file"], r["from"], r["to"], a.timeout, work) for r in rows]
    t0 = time.time()
    try:
        with ProcessPoolExecutor(max_workers=a.jobs) as ex:
            res = list(ex.map(run, jobs, chunksize=4))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    src = {(r[0], r[1]): r for r in res[:len(sources)]}
    count = Counter()
    with open(a.out, "w") as f:
        f.write("file\tfrom\tto\tstatus\tsource\terror\n")
        for r in res[:len(sources)]:
            if r[3] != "loaded":
                f.write(f"{r[0]}\t{r[1]}\t(source)\t{r[3]}\t-\t{r[4]}\n")
        for r in res[len(sources):]:
            s = src[(r[0], r[1])][3]
            if r[3] == "loaded":
                count[(r[1], r[2], "loaded")] += 1
            elif s == "syntax":  # the source loaded if it got as far as running
                count[(r[1], r[2], "excluded")] += 1
                f.write(f"{r[0]}\t{r[1]}\t{r[2]}\texcluded:{r[3]}\t{s}\t{r[4]}\n")
            else:
                count[(r[1], r[2], r[3])] += 1
                f.write(f"{r[0]}\t{r[1]}\t{r[2]}\t{r[3]}\t{s}\t{r[4]}\n")
    print(f"{len(jobs)} runs ({len(sources)} source loads) in {time.time() - t0:.0f}s -> {a.out}")
    print(f"{'pair':<18}{'loaded':>8}{'syntax':>8}{'runtime':>8}{'timeout':>8}{'transl':>8}{'excluded':>9}")
    for frm, to in sorted({(k[0], k[1]) for k in count}):
        c = lambda s: count[(frm, to, s)]
        print(f"{frm + '>' + to:<18}{c('loaded'):>8}{c('syntax'):>8}{c('runtime'):>8}{c('timeout'):>8}{c('translate'):>8}{c('excluded'):>9}")
    sc = Counter((r[1], r[3]) for r in res[:len(sources)])
    print("source loads:", ", ".join(f"{k[0]} {k[1]} {v}" for k, v in sorted(sc.items())))


if __name__ == "__main__":
    main()
