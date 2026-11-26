"""One inverter per PDK, simulated natively and translated to Xyce.

Usage: python3 tools/pdk_smoke.py [workdir]      (needs SPRACK_TEST_PDKS, ngspice, Xyce)

Each inverter is built with sprack.Circuit, swept with .dc, and its switching
point (the input where the output crosses VDD/2) is found in ngspice from the
netlist in the PDK's own dialect or its ngspice translation, and in Xyce from
the Xyce translation. sky130 runs natively from sprack's ngspice copy of its
library (ngspice 45 takes 132 s to load the checkout's tt itself; docs/verification.md 4.28). ASAP7 is BSIM-CMG, which ngspice has only as OSDI, so it
runs in Xyce alone.
"""
import os, re, subprocess, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))
import sprack

PDKS = os.environ["SPRACK_TEST_PDKS"]
work = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="pdk_smoke.")


def inverter(name, sub, vdd, n, p, **kw):
    pdk = sprack.PDK(name, root=os.path.join(PDKS, sub), cache_dir=os.path.join(work, "cache"))
    c = sprack.Circuit(f"{name} inverter", pdk=pdk)
    # At the PDK's own simulator's temperature, said, so every target runs
    # the same one (an unset one is an error where the defaults differ).
    # ponytail: HSPICE's 25 and 27 elsewhere, as the grammars' `implied` lines say.
    t = 25 if pdk.dialect == "hspice" else 27
    c.options(temp=t, tnom=t)
    c.V("dd", "vdd", 0, vdd)
    c.V("in", "in", 0, 0)
    getattr(c, p[0])("Mp", "out", "in", "vdd", "vdd", **p[1])
    getattr(c, n[0])("Mn", "out", "in", 0, 0, **n[1])
    c.dc("Vin", 0, vdd, vdd / 200)
    c.print_("dc", sprack.v("out"))
    return c, pdk


# Known lines the simulators reject, edited in the cached copy so the inverter
# can run; each one is printed. ponytail: delete an entry once sprack handles it.
PATCHES = [
    # (None left: SPRack now renames a parameter named vt and writes
    # dev/gauss= as a random function itself, issue 67.)
]


def patch(tree, sim):
    done = set()
    for dp, _, files in os.walk(tree):
        for f in files:
            p = os.path.join(dp, f)
            text = open(p, errors="replace").read()
            new = text
            for only, rx, rep, what in PATCHES:
                if only in (None, sim) and rx.search(new) and (rep != "vt_" or re.search(r"^\.param.*\bvt=", new, re.M)):
                    new, done = rx.sub(rep, new), done | {what}
            if new != text:
                os.chmod(p, 0o644)
                open(p, "w").write(new)
    return sorted(done)


def crossing(rows, level):
    for (x0, y0), (x1, y1) in zip(rows, rows[1:]):
        if (y0 - level) * (y1 - level) <= 0 and y0 != y1:
            return x0 + (level - y0) * (x1 - x0) / (y1 - y0)
    return None


def run(sim, text, tag):
    deck = os.path.join(work, f"{tag}.{sim}.cir")
    open(deck, "w").write(text)
    if sim == "ngspice":
        p = subprocess.run(["ngspice", "-b", "-n", deck], capture_output=True, text=True, timeout=300, cwd=work)
        out = p.stdout
        rows = [(float(m[1]), float(m[2])) for m in re.finditer(r"^\d+\s+(\S+)\s+(\S+)\s*$", out, re.M)]
        if not rows:
            sys.stderr.write((p.stdout + p.stderr)[-2000:])
    else:
        p = subprocess.run(["Xyce", deck], capture_output=True, text=True, timeout=300, cwd=work)
        prn = deck + ".prn"
        rows = []
        if os.path.exists(prn):  # Index V(IN) V(OUT); the sweep variable is the source, printed as a column only for .print dc v(in)
            for line in open(prn).read().splitlines()[1:]:
                f = line.split()
                if len(f) >= 3 and f[0].isdigit():
                    rows.append((float(f[1]), float(f[2])))
        if not rows:
            sys.stderr.write(p.stdout[-2000:])
    return rows


def main():
    cases = [
        ("sky130A", "sky130_fd_pr", 1.8, ("nfet_01v8", dict(w=0.65, l=0.15)), ("pfet_01v8", dict(w=1.3, l=0.15)), "ngspice"),
        ("FreePDK45", "freepdk45", 1.0, ("NMOS_VTL", dict(w="90n", l="50n")), ("PMOS_VTL", dict(w="180n", l="50n")), "ngspice"),
        ("ASAP7", "asap7", 0.7, ("nmos_rvt", dict(nfin=3)), ("pmos_rvt", dict(nfin=3)), None),
    ]
    failed = []
    for name, sub, vdd, n, p, native in cases:
        c, pdk = inverter(name, sub, vdd, n, p)
        res = {}
        for sim in ([native] if native else []) + ["xyce"]:
            nl = c.netlist(sim, strict=False)
            errs = [f"{e.code}: {e.message}" for e in nl.report.errors]
            # Xyce needs the sweep source printed to know the x axis.
            text = str(nl).replace(".print dc v(out)", ".print dc v(in) v(out)") if sim == "xyce" else str(nl)
            if sim == pdk.dialect:
                text = text.replace(pdk.root, pdk.translate(sim, strict=False))
            for tree in {pdk.translate(sim, strict=False)} if sim != pdk.dialect or name == "sky130A" else ():
                for what in patch(tree, sim):
                    print(f"{name:<10} {sim:<8} patched by hand: {what}")
            rows = run(sim, text, name)
            res[sim] = crossing(rows, vdd / 2)
            # A run with no points, or no crossing, is a failure, not a pass
            # with nothing to compare (issue 67).
            if res[sim] is None:
                failed.append(f"{name} {sim}")
            print(f"{name:<10} {sim:<8} {len(rows):>4} points  switching point {res[sim]}  ({len(errs)} report errors{': ' + errs[0][:120] if errs else ''})")
        if native and None not in res.values():
            print(f"{name:<10} ngspice vs xyce: {abs(res[native] - res['xyce']) * 1e3:.2f} mV apart")
    if failed:
        sys.exit("no switching point: " + ", ".join(failed))


if __name__ == "__main__":
    main()
