"""Compare each PDK device between its own simulator and a translation.

Usage:
  python3 -I tools/pdk_devices.py [--pdk NAME[,NAME]] [--target xyce[,vacask]]
      [--only REGEX] [--work DIR] [--baseline tools/pdk-devices-baseline.tsv]
      [--update]
  python3 -I tools/pdk_devices.py --table tools/pdk-devices-baseline.tsv

Needs SPRACK_TEST_PDKS (the PDK trees, as python/test_sprack.py takes them;
sky130 and IHP from SPRACK_TEST_PDKS_INSTALLED where it is set, the trees
ngspice loads as they are: open_pdks' sky130, whose lines of issue 25 are
corrected, and IHP with the OSDI objects its .spiceinit names),
ngspice, and the targets' simulators on PATH (Xyce, vacask); VACASK's raw
files are read with the Conformance Suite's tools/rawcheck.py, at
SPRACK_SUITE. Issue 61.

For every device of a PDK's catalogue a kind is found (its model card's
family, or for a subcircuit its terminals and name), and one small deck is
made with sprack.Circuit: a MOSFET's drain current at two biases, a
resistor's current at 1 V, a capacitor's AC current at 1 MHz, a diode's
forward current at 0.7 V, a BJT's collector current. The deck runs in the
PDK's own simulator (ngspice; `set numdgt=10` so the numbers have the
digits to compare) and its translation in each target. The two HSPICE PDKs
(ASAP7, FreePDK45) have no source run here: their translation still runs,
and loads (no reference, with the target's value) or does not (refused). A target's log is
read for what it dropped ("parameter ignored", "older than the oldest
version supported") and for load errors.

One row per PDK, corner, device, target and quantity: the source value, the
target value, their relative difference, and a verdict: same (within 1e-4),
differs, refused (the target did not load it, or the translation had an
error), no model (no kind to stimulate), no reference (the source did not
load it), not run (the target simulator is not on PATH, or has no reader
here yet). With --baseline the rows are compared with that file's: any
verdict that changed, either way, fails the run; --update rewrites it.
--table prints a baseline's counts per PDK, target and verdict as the
Markdown table of docs/src/pdks.md.
"""
import argparse, csv, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [os.path.join(HERE, "..", "python"), HERE]
import sprack
import sim_check

PDKS = os.environ.get("SPRACK_TEST_PDKS", "")
TREES = {"sky130A": "sky130_fd_pr", "ihp-sg13g2": "ihp", "gf180mcuD": "gf180mcu", "ASAP7": "asap7", "FreePDK45": "freepdk45"}
VDD = {"sky130A": 1.8, "ihp-sg13g2": 1.2, "gf180mcuD": 3.3, "ASAP7": 0.7, "FreePDK45": 1.1}
SUITE = os.environ.get("SPRACK_SUITE", "")
INSTALLED = os.environ.get("SPRACK_TEST_PDKS_INSTALLED", "")
INSTALLED_TREES = {"sky130A": "sky130", "ihp-sg13g2": "ihp"}


def root(name):
    if INSTALLED and name in INSTALLED_TREES:
        return os.path.join(INSTALLED, INSTALLED_TREES[name])
    return os.path.join(PDKS, TREES[name])
TOL = 1e-4
MOS = {"mos1", "mos2", "mos3", "bsim3", "bsim4", "bsimsoi", "bsimcmg", "bsimbulk", "psp103", "hisim2", "hisimhv", "vdmos",
       "mos6", "mos9", "bsim1", "bsim2", "b3soifd", "b3soidd", "b3soipd"}
BJT = {"bjt", "vbic", "hicum2", "mextram"}
DROPS = re.compile(r"(parameter ignored|older than the oldest version supported)", re.I)
COLUMNS = ["pdk", "corner", "device", "target", "quantity", "source", "target_value", "rel", "verdict", "note"]


def kind_of(dev):
    """(kind, p-type) of a catalogue device, or (None, False)."""
    name = dev["name"].lower()
    ptype = bool(re.search(r"(^|_)(p|pfet|pmos|pnp)(_|\d|$)|pfet|pmos|pnp", name))
    if dev["kind"] == "model":
        fam = (dev.get("family") or "").lower()
        if fam in MOS:
            return "mosfet", dev.get("polarity") == "p" or ptype
        if fam in BJT:
            return "bjt", dev.get("polarity") == "pnp" or ptype
        if fam in ("resistor", "capacitor", "diode"):
            return fam, False
        return None, False
    ports = [p.lower() for p in dev.get("ports") or []]
    if ports[:4] == ["d", "g", "s", "b"] or (len(ports) == 4 and re.search(r"fet|mos", name)):
        return "mosfet", ptype
    if len(ports) in (3, 4) and ports[:3] in (["c", "b", "e"], ["col", "base", "emit"]):
        return "bjt", ptype
    if re.search(r"npn|pnp|hbt", name) and len(ports) >= 3:
        return "bjt", ptype
    if re.search(r"cap|mim|mom|var", name) and len(ports) >= 2:
        return "capacitor", False
    if re.search(r"dio|diode|^d", name) and len(ports) >= 2:
        return "diode", False
    if re.search(r"res|^r|poly|rppd|rsil|rhigh", name) and len(ports) >= 2:
        return "resistor", False
    return None, False


def deck(pdk, dev, kind, ptype, vdd):
    """{quantity: (circuit, what to print, analysis)} for one device."""
    s = -1 if ptype else 1
    # sky130 sizes are micrometres under its `.option scale=1.0u`: "1u" there is 1e-12 m.
    u = "" if pdk.name == "sky130A" else "u"
    out = {}
    nports = len(dev.get("ports") or []) if dev["kind"] == "subckt" else 0

    def place(c, nodes):
        call = getattr(c, dev["name"])
        if dev["kind"] == "subckt":
            nodes = (list(nodes) + ["0"] * nports)[:nports]
            return call("X1", *nodes)
        if kind == "mosfet":
            # A BSIM-CMG takes fins, not a width: ASAP7's own size (tools/pdk_smoke.py).
            return call("M1", *nodes, **(dict(nfin=3) if dev.get("family") == "bsimcmg" else dict(w=f"1{u}", l=f"1{u}")))
        if kind in ("resistor", "capacitor"):
            return call("1", *nodes[:2], w=f"1{u}", l=f"10{u}")
        return call("1", *nodes[:3 if kind == "bjt" else 2])  # c b e; a diode's two

    def new():
        c = sprack.Circuit(f"{dev['name']} {kind}", pdk=pdk)
        # The PDK simulator's temperature, said, so the target runs the same
        # one. ponytail: HSPICE's 25 and 27 elsewhere (the grammars' `implied` lines).
        t = 25 if pdk.dialect == "hspice" else 27
        c.options(temp=t, tnom=t)
        return c

    if kind == "mosfet":
        for tag, vg, vd in (("id_on", vdd, vdd), ("id_half", vdd / 2, vdd / 2)):
            c = new()
            c.V("d", "d", 0, s * vd)
            c.V("g", "g", 0, s * vg)
            place(c, ("d", "g", "0", "0"))
            c.dc("Vd", s * vd, s * vd, 1)
            out[tag] = (c, "i(Vd)", "dc")
    elif kind == "bjt":
        c = new()
        c.V("c", "c", 0, s * 1.0)
        c.V("b", "b", 0, s * 0.8)
        place(c, ("c", "b", "0", "0"))
        c.dc("Vc", s * 1.0, s * 1.0, 1)
        out["ic"] = (c, "i(Vc)", "dc")
    elif kind in ("resistor", "diode"):
        v = 1.0 if kind == "resistor" else 0.7
        c = new()
        c.V("a", "a", 0, v)
        place(c, ("a", "0", "0"))
        c.dc("Va", v, v, 1)
        out["i_dc" if kind == "resistor" else "i_fwd"] = (c, "i(Va)", "dc")
    elif kind == "capacitor":
        c = new()
        c.V("a", "a", 0, 0, acmag=1)
        place(c, ("a", "0", "0"))
        c.ac("lin", 1, "1meg", "1meg")
        out["i_ac_imag"] = (c, "imag(i(Va))", "ac")
    return out


def run_ngspice(work, text, expr):
    """(value or None, log). The value printed with ten digits."""
    path = os.path.join(work, "src.cir")
    ctl = f".control\nset numdgt=10\nrun\nprint {expr}\n.endc\n"
    open(path, "w").write(re.sub(r"(?im)^\.end\s*$", ctl + ".end", text))
    try:
        p = subprocess.run(["ngspice", "-b", path], capture_output=True, text=True, timeout=300, cwd=work)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    log = p.stdout + p.stderr
    m = re.search(r"^\s*" + re.escape(expr.lower()) + r"\s*=\s*([-+0-9.eE]+)\s*$", log.lower(), re.M)
    return (float(m[1]) if m and p.returncode == 0 else None), log


def run_xyce(work, text, expr, analysis):
    """(value or None, log) from the .prn Xyce writes for the deck's .print."""
    path = os.path.join(work, "tgt.cir")
    pr = f".print {analysis} {expr if analysis == 'dc' else 'ii(' + expr[len('imag(i('):-2] + ')'}\n"
    open(path, "w").write(re.sub(r"(?im)^\.end\s*$", pr + ".end", text))
    try:
        p = subprocess.run(["Xyce", path], capture_output=True, text=True, timeout=300, cwd=work)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    log = p.stdout + p.stderr
    prn = path + (".prn" if analysis == "dc" else ".FD.prn")
    if p.returncode != 0 or not os.path.exists(prn):
        return None, log
    rows = [l.split() for l in open(prn).read().splitlines()[1:] if l.split() and l.split()[0].isdigit()]
    return (float(rows[0][-1]) if rows else None), log


def run_vacask(work, text, expr, analysis):
    """(value or None, log) from the raw file VACASK writes for the deck's one analysis."""
    d = tempfile.mkdtemp(dir=work)
    try:
        open(os.path.join(d, "tgt.sim"), "w").write(text)
        try:
            p = subprocess.run(sim_check.command("vacask", "tgt.sim", None), capture_output=True, text=True, timeout=300, cwd=d)
        except (OSError, subprocess.TimeoutExpired) as e:
            return None, str(e)
        log = p.stdout + p.stderr
        raws = [f for f in os.listdir(d) if f.endswith(".raw")]
        if p.returncode != 0 or len(raws) != 1:
            return None, log
        m = re.fullmatch(r"(imag\()?i\((\w+)\)\)?", expr)
        want = m[2].lower() + "#branch"  # VACASK's `Vd:flow(br)`, folded as sim_check folds it
        for _, names, _, _, tab in sim_check.rawcheck.parse_raw(open(os.path.join(d, raws[0]), "rb").read()):
            cols = [sim_check.column(n) for n in names]
            if want in cols and tab:
                v = tab[0][cols.index(want)]
                return (v.imag if m[1] else v.real), log
        return None, log
    finally:
        shutil.rmtree(d, ignore_errors=True)


RUN = {"xyce": ("Xyce", run_xyce), "vacask": ("vacask", run_vacask)}


def compare(pdk_name, corner, devices, targets, work):
    rows = []
    pdk = sprack.PDK(pdk_name, root=root(pdk_name), corner=corner, cache_dir=os.path.join(work, "cache"))
    vdd = VDD[pdk_name]
    for name, dev in sorted(pdk.devices.items()):
        if devices and not re.search(devices, name):
            continue
        kind, ptype = kind_of(dev)
        if kind is None:
            for t in targets:
                rows.append([pdk_name, corner, name, t, "-", "", "", "", "no model", "no kind to stimulate"])
            continue
        try:
            decks = deck(pdk, dev, kind, ptype, vdd)
        except Exception as e:  # a device the builder refuses: recorded, not fatal
            for t in targets:
                rows.append([pdk_name, corner, name, t, "-", "", "", "", "refused", f"builder: {e}"[:200]])
            continue
        for q, (c, expr, analysis) in decks.items():
            if pdk.dialect == "ngspice":
                ref, slog = run_ngspice(work, c.netlist(pdk.dialect, strict=False), expr)
                why_no_ref = first_error(slog) or "ngspice gave no value"
            else:
                ref, why_no_ref = None, f"{pdk.dialect}: the PDK's own simulator is not here"
            for t in targets:
                row = [pdk_name, corner, name, t, q, "" if ref is None else repr(ref)]
                if ref is None and pdk.dialect == "ngspice":
                    rows.append(row + ["", "", "no reference", why_no_ref])
                    continue
                # The library's own errors are anywhere in it: the run says
                # whether this device's translation stands; they go in the note.
                note = ""
                try:
                    text = c.netlist(t)
                except sprack.Unsupported as e:
                    note = str(e).splitlines()[1].strip()[:200] if "\n" in str(e) else str(e)[:200]
                    text = c.netlist(t, strict=False)
                exe, run = RUN[t]
                why = f"{t}: no simulator on PATH" if shutil.which(exe) is None else "vacask: no reader (SPRACK_SUITE unset)" if t == "vacask" and not SUITE else ""
                if why:
                    rows.append(row + ["", "", "not run", f"{why}; {note}" if note else why])
                    continue
                val, tlog = run(work, text, expr, analysis)
                dropped = "; ".join(sorted(set(m[0] for m in DROPS.finditer(tlog))))
                if val is None:
                    rows.append(row + ["", "", "refused", first_error(tlog) or note])
                    continue
                if ref is None:
                    rows.append(row + [repr(val), "", "no reference", "; ".join(x for x in (why_no_ref, dropped, note) if x)])
                    continue
                rel = abs(val - ref) / max(abs(ref), 1e-30)
                rows.append(row + [repr(val), f"{rel:.3g}", "same" if rel <= TOL else "differs", "; ".join(x for x in (dropped, note) if x)])
    return rows


def first_error(log):
    """The first error line and the one after it (Xyce says where on one line and what on the next)."""
    lines = log.splitlines()
    for i, line in enumerate(lines):
        if re.search(r"error|fatal|unknown|refus", line, re.I):
            return " ".join(l.strip() for l in lines[i:i + 2])[:200].rstrip()
    return next((l.strip()[:200] for l in reversed(lines) if l.strip()), "")


VERDICTS = ["same", "differs", "refused", "no model", "no reference", "not run"]


def table(path):
    with open(path) as f:
        rows = list(csv.reader(f, delimiter="\t"))[1:]
    counts = {}
    for r in rows:
        counts.setdefault((r[0], r[3]), {}).setdefault(r[8], set()).add((r[2], r[4]))
    print("| PDK | target | devices | " + " | ".join(VERDICTS) + " |")
    print("|---|---|---|" + "---|" * len(VERDICTS))
    for (p, t), by in counts.items():
        devices = len({d for rs in by.values() for d, _ in rs})
        print(f"| {p} | {t} | {devices} | " + " | ".join(str(len(by.get(v, ()))) for v in VERDICTS) + " |")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pdk", default=",".join(TREES))
    ap.add_argument("--target", default="xyce,vacask")
    ap.add_argument("--corner", default="")
    ap.add_argument("--only", default="")
    ap.add_argument("--work", default="")
    ap.add_argument("--baseline", default="")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--out", default="-")
    ap.add_argument("--table", default="")
    a = ap.parse_args()
    if a.table:
        return table(a.table)
    if not PDKS:
        sys.exit("set SPRACK_TEST_PDKS to the directory of PDK trees")
    work = a.work or tempfile.mkdtemp(prefix="pdk_devices.")
    if SUITE:
        sim_check.load_rawcheck(SUITE)
    rows = []
    for name in a.pdk.split(","):
        corner = a.corner or None
        pdk_corner = corner or sprack.PDK(name, root=root(name), cache_dir=os.path.join(work, "cache")).corner
        rows += compare(name, pdk_corner, a.only, a.target.split(","), work)
    out = sys.stdout if a.out == "-" else open(a.out, "w", newline="")
    w = csv.writer(out, delimiter="\t", lineterminator="\n")
    w.writerow(COLUMNS)
    w.writerows(rows)
    if a.out != "-":
        out.close()
    if a.baseline:
        key = lambda r: tuple(r[:5])
        old = {}
        if os.path.exists(a.baseline):
            with open(a.baseline) as f:
                old = {key(r): r for r in list(csv.reader(f, delimiter="\t"))[1:]}
        changed = [(r, old.get(key(r))) for r in rows if key(r) in old and old[key(r)][8] != r[8]]
        for r, o in changed[:50]:
            print(f"verdict changed: {' '.join(r[:5])}: {o[8]} -> {r[8]}", file=sys.stderr)
        if a.update or not old:
            with open(a.baseline, "w", newline="") as f:
                csv.writer(f, delimiter="\t", lineterminator="\n").writerows([COLUMNS] + rows)
        elif changed:
            sys.exit(f"{len(changed)} verdicts changed against {a.baseline}")
    counts = {}
    for r in rows:
        counts[(r[0], r[3], r[8])] = counts.get((r[0], r[3], r[8]), 0) + 1
    for (p, t, v), n in sorted(counts.items()):
        print(f"{p}\t{t}\t{v}\t{n}", file=sys.stderr)


if __name__ == "__main__":
    main()
