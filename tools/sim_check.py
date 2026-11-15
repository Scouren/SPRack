"""Simulate a deck and its translation, and judge both against the oracle.

Usage: python3 -I tools/sim_check.py <sprack> <suite> <audit.tsv> <out.tsv>
           [--targets xyce,vacask] [--timeout 60] [--rtol 1e-3] [--jobs N] [--work DIR] [--only TEXT]

<suite> is the Conformance Suite root: decks under tests/, and its
tools/rawcheck.py, whose raw-file reader and judge are used as they are.
Every ngspice deck with an `.expected.json` whose translation to a target has
0 errors in the audit is run twice: the source in ngspice, the translation in
the target, each writing a binary raw file. The target's plot and column
names are folded to ngspice's (`X1:3` is `x1.3`, `Vin:flow(br)` is
`vin#branch`), and a transient plot judged row by row in the oracle is judged
by interpolation at the oracle's times instead, since another simulator takes
other steps, and every tolerance is widened to --rtol. A row of out.tsv is a deck whose source passes and whose
translation does not, with the first failing check; a summary goes to stdout.
"""
import argparse, bisect, copy, csv, importlib.util, json, os, re, shutil, signal, subprocess, sys, tempfile, time
from collections import Counter
from concurrent.futures import ProcessPoolExecutor

PLOT = {  # target plot names that are ngspice's under another name
    "ac small signal analysis": "AC Analysis",
    "small-signal noise analysis": "Noise Spectral Density Curves",
    "noise analysis": "Noise Spectral Density Curves",
}
AXES = {"time", "frequency"}
SWEEP = re.compile(r"sweep\d*")  # Xyce `sweep`, VACASK `sweep1`
rawcheck = None


def load_rawcheck(suite):
    global rawcheck
    spec = importlib.util.spec_from_file_location("rawcheck", os.path.join(suite, "tools", "rawcheck.py"))
    rawcheck = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rawcheck)
    plain = rawcheck.canonical
    # ngspice names a branch current i(v1) in one plot and v1#branch in another.
    rawcheck.canonical = lambda n: plain(re.sub(r"^i\((.+)\)$", r"\1#branch", n.lower()))
    rawcheck.sample = sample


def sample(plot, axis, col, t, rtol, atol):
    """rawcheck.sample, with the axis column built once per plot instead of once per value."""
    tab = plot[4]
    key = (id(tab), axis)
    if _axis[0] != key:
        _axis[:] = [key, [r[axis].real for r in tab]]
    xs = _axis[1]
    if not xs:
        raise ValueError("no samples")
    if t < xs[0] or t > xs[-1]:
        end = 0 if t < xs[0] else len(xs) - 1
        if rawcheck.close(complex(xs[end], 0), complex(t, 0), rtol, atol):
            return tab[end][col]
        raise ValueError(f"axis does not reach {t}")
    hi = min(max(bisect.bisect_right(xs, t), 1), len(xs) - 1)
    lo = hi - 1
    if xs[hi] == xs[lo]:
        return tab[lo][col]
    return tab[lo][col] + (t - xs[lo]) / (xs[hi] - xs[lo]) * (tab[hi][col] - tab[lo][col])


_axis = [None, []]


def column(name):
    """A target's column name in ngspice's spelling."""
    n = name.lower().replace(":", ".")
    if n in AXES:
        return n
    if SWEEP.fullmatch(n):
        return "v(v-sweep)"
    m = re.fullmatch(r"(.+)\.flow\(br\)", n)  # VACASK branch current
    if m:
        return m.group(1) + "#branch"
    if n == "onoise":
        return "onoise_spectrum"
    return n if "(" in n or "#" in n or n.endswith("_spectrum") else f"v({n})"


def fold(plots):
    out = []
    for name, cols, rows, cplx, tab in plots:
        name = PLOT.get(name.lower(), name)
        swept = any(SWEEP.fullmatch(c.lower()) for c in cols)
        if name.lower() in ("dc transfer characteristic", "operating point"):
            # Xyce writes .op as a one-point DC sweep; VACASK writes a DC sweep as an operating point.
            name = "DC transfer characteristic" if swept and rows > 1 else "Operating Point"
            if name == "Operating Point" and swept:
                keep = [i for i, c in enumerate(cols) if not SWEEP.fullmatch(c.lower())]
                cols, tab = [cols[i] for i in keep], [[r[i] for i in keep] for r in tab]
        low = [c.lower() for c in cols]
        if "onoise" in low and "gain" in low:
            # VACASK writes noise as power densities and the power gain; ngspice as V/sqrt(Hz), in and out.
            o, g = low.index("onoise"), low.index("gain")
            tab = [r[:o] + [abs(r[o]) ** 0.5] + r[o + 1:] + [abs(r[o] / r[g]) ** 0.5 if r[g] else float("inf")] for r in tab]
            cols = cols + ["inoise_spectrum"]
        out.append((name, [column(c) for c in cols], rows, cplx, tab))
    return out


def resample(oracle, rtol):
    """The oracle as another simulator can meet it.

    Exact-row transient plots become samples at the oracle's own times. Every
    tolerance is widened to `rtol`, with an absolute floor of `rtol` times the
    column's largest value: the oracle's tolerances are one ngspice build's
    round-off, not the spread between two simulators. A DC sweep's axis is
    the sweep column whatever ngspice called it (v-sweep, i-sweep, temp-sweep).
    """
    o = copy.deepcopy(oracle)
    for p in o["expect"].get("plots", []):
        axis = p.get("axis")
        if axis and axis["name"].lower() == "time" and p["match"] == "exact":
            p["match"] = "samples"
            p.pop("row_count", None)
        if axis and p["name"].lower() == "dc transfer characteristic":
            axis["name"] = "v(v-sweep)"
        for col in list(p["columns"].values()) + ([axis] if axis else []):
            big = max((abs(rawcheck.scalar(v)) for v in col["values"]), default=0)
            col["rtol"], col["atol"] = max(col["rtol"], rtol), max(col["atol"], rtol * big)
    for c in o["expect"].get("checks", []):
        c["rtol"], c["atol"] = max(c["rtol"], rtol), max(c["atol"], rtol * abs(c["value"]))
    return o


def command(sim, deck, raw):
    if sim == "ngspice":
        return ["ngspice", "-b", "-n", "-r", raw, deck]
    if sim == "xyce":
        return ["Xyce", "-r", raw, deck]
    return ["vacask", "-qp", "-sp", deck]  # one <analysis>.raw per analysis in the cwd


def simulate(sim, path, deck_text_from, timeout, work):
    """(rc, stdout, raw bytes) of one run in a directory of symlinks beside the deck."""
    d = tempfile.mkdtemp(dir=work)
    try:
        src_dir = os.path.dirname(path)
        for e in os.listdir(src_dir):
            if e != os.path.basename(path):
                os.symlink(os.path.join(src_dir, e), os.path.join(d, e))
        deck = os.path.join(d, os.path.basename(path) if deck_text_from is None else "deck.x" + (".sim" if sim == "vacask" else ".cir"))
        if deck_text_from is None:
            os.symlink(path, deck)
        else:
            open(deck, "w").write(deck_text_from)
        raw = os.path.join(d, "result.raw")
        before = set(os.listdir(d))
        try:
            p = subprocess.run(command(sim, os.path.basename(deck), raw), cwd=d, capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return None, "timeout", b""
        if sim == "vacask":
            data = b"".join(open(os.path.join(d, f), "rb").read() for f in sorted(set(os.listdir(d)) - before) if f.endswith(".raw"))
        else:
            data = open(raw, "rb").read() if os.path.exists(raw) else b""
        return p.returncode, p.stdout.decode(errors="replace"), data
    finally:
        shutil.rmtree(d, ignore_errors=True)


def judge(oracle, rc, out, raw, folded):
    if rc is None:
        return [("run", False, "timeout")]
    real = rawcheck.parse_raw
    if folded:
        rawcheck.parse_raw = lambda data: fold(real(data))
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError("judging took over 60 s")))
    signal.alarm(60)  # ponytail: rawcheck judges in pure Python; a huge raw file is given up on
    try:
        return rawcheck.judge(oracle, rc, out, raw)
    except Exception as e:  # a raw file the reader cannot take
        return [("raw file", False, f"{type(e).__name__}: {e}")]
    finally:
        signal.alarm(0)
        rawcheck.parse_raw = real


def run(job):
    sprack, suite, path, rel, to, timeout, work, rtol = job
    load_rawcheck(suite) if rawcheck is None else None
    oracle = json.load(open(os.path.splitext(path)[0] + ".expected.json"))
    kinds = {c["kind"] for c in oracle["expect"].get("checks", [])} - rawcheck.PORTED
    if kinds:
        return (rel, to, "skip", "", "oracle check kind not ported: " + ",".join(sorted(kinds)))
    t = subprocess.run([sprack, "translate", "--from", "ngspice", "--to", to, path], capture_output=True, timeout=60)
    src = judge(oracle, *simulate("ngspice", path, None, timeout, work), False)
    dst = judge(resample(oracle, rtol), *simulate(to, path, t.stdout.decode(), timeout, work), True)
    s_ok, d_ok = all(ok for _, ok, _ in src), all(ok for _, ok, _ in dst)
    first = next(((l, d) for l, ok, d in dst if not ok), ("", ""))
    status = {(True, True): "match", (True, False): "mismatch", (False, True): "source-fails", (False, False): "both-fail"}[(s_ok, d_ok)]
    return (rel, to, status, first[0], first[1][:300])


def cause(label, detail):
    if label == "simulation succeeded":
        return "translation does not run"
    if label == "rejected with a diagnostic":
        return "error deck accepted"
    if label.startswith("plot ") and "missing" in detail:
        return "plot missing"
    if "matches" in detail:
        return "column missing"
    if label == "raw file" or detail == "timeout":
        return "no raw file / timeout"
    if label.startswith("measure"):
        return "measure differs"
    return "values differ"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sprack"); ap.add_argument("suite"); ap.add_argument("audit"); ap.add_argument("out")
    ap.add_argument("--targets", default="xyce,vacask")
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--work", default=None)
    ap.add_argument("--only", default="")
    ap.add_argument("--rtol", type=float, default=1e-3, help="tolerance between two simulators")
    a = ap.parse_args()
    sprack, suite = os.path.abspath(a.sprack), os.path.abspath(a.suite)
    tests = os.path.join(suite, "tests")
    rows = [r for r in csv.DictReader(open(a.audit), delimiter="\t", quoting=csv.QUOTE_NONE)
            if r["from"] == "ngspice" and r["rc"] == "0" and r["errors"] == "0" and r["to"] in a.targets.split(",")
            and a.only in r["file"] and os.path.exists(os.path.join(tests, os.path.splitext(r["file"])[0] + ".expected.json"))]
    work = tempfile.mkdtemp(prefix="sim_check.", dir=a.work)
    jobs = [(sprack, suite, os.path.join(tests, r["file"]), r["file"], r["to"], a.timeout, work, a.rtol) for r in rows]
    t0 = time.time()
    try:
        with ProcessPoolExecutor(max_workers=a.jobs) as ex:
            res = list(ex.map(run, jobs))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    count, causes = Counter(), Counter()
    with open(a.out, "w") as f:
        f.write("file\tto\tstatus\tcause\tcheck\tdetail\n")
        for r in res:
            count[(r[1], r[2])] += 1
            if r[2] == "mismatch":
                c = cause(r[3], r[4])
                causes[(r[1], c)] += 1
                f.write(f"{r[0]}\t{r[1]}\t{r[2]}\t{c}\t{r[3]}\t{r[4]}\n")
    print(f"{len(jobs)} decks in {time.time() - t0:.0f}s -> {a.out}")
    for to in sorted({k[0] for k in count}):
        print(f"ngspice>{to}: " + ", ".join(f"{s} {count[(to, s)]}" for s in ("match", "mismatch", "source-fails", "both-fail", "skip")))
        for (t, c), n in sorted(causes.items()):
            if t == to:
                print(f"    {c}: {n}")


if __name__ == "__main__":
    main()
