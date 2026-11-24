"""The model-card parameters each simulator takes, for the grammars' modelparams tables.

Usage:
    python3 tools/param_lists.py xyce <Xyce checkout>      # from the source, as Xyce -param lists them
    python3 tools/param_lists.py ngspice                   # from ngspice's devhelp (ngspice on PATH)
    python3 tools/param_lists.py check <Xyce checkout>     # the grammars' tables against both

`xyce` prints, for each family the grammars map to a Xyce device, every model
parameter its ParametricData declares (Traits::loadModelParameters), one group
per member: a parameter and its synonyms. `ngspice` prints devhelp's groups
(one id, several names). `check` reports a name a grammar's table lists that
the simulator does not, and a family whose Xyce table is not `only` or lists
fewer names than Xyce has: what docs/verification.md 4.23 records.
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GRAMMARS = os.path.join(HERE, "..", "grammars")

# family -> the Xyce sources whose model parameters it is written as (every
# version Xyce selects by a card's version= is one of them).
XYCE = {
    "resistor": ["OpenModels/N_DEV_Resistor.C"],
    "capacitor": ["OpenModels/N_DEV_Capacitor.C"],
    "diode": ["OpenModels/N_DEV_Diode.C"],
    "bjt": ["OpenModels/N_DEV_BJT.C"],
    "vbic": ["ADMS/N_DEV_ADMSvbic13.C", "ADMS/N_DEV_ADMSvbic13_4t.C"],
    "bsim3": ["OpenModels/N_DEV_MOSFET_B3.C"],
    "bsim4": ["OpenModels/N_DEV_MOSFET_B4.C", "OpenModels/N_DEV_MOSFET_B4p61.C", "OpenModels/N_DEV_MOSFET_B4p70.C"],
    "psp103": ["ADMS/N_DEV_ADMSPSP103VA.C"],
}

# ngspice 45's names that 42's devhelp does not give (issue #33).
NGSPICE_EXTRA = {"diode": [["tbv1", "tcv"], ["php", "vjsw"], ["jsw", "isw"]]}

# family -> the ngspice device devhelp names.
NGSPICE = {
    "resistor": "resistor", "capacitor": "capacitor", "diode": "diode", "bjt": "bjt",
    "vbic": "vbic", "bsim3": "bsim3", "bsim4": "bsim4",
}

ADDPAR = re.compile(r'\.\s*addPar\s*\(\s*"([A-Za-z0-9_$]+)"(.*?)\)\s*[\n;.]', re.S)
MEMBER = re.compile(r"&\s*[\w:]+::Model::(\w+)")


def xyce_groups(src, files):
    """Each model parameter, grouped with its synonyms (the same member)."""
    groups, order = {}, []
    for f in files:
        text = open(os.path.join(src, "src", "DeviceModelPKG", f), errors="replace").read()
        start = text.find("loadModelParameters(ParametricData<")
        if start < 0:
            continue
        # The function body: from its first brace to the matching one.
        i = text.index("{", start)
        depth, j = 0, i
        while True:
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = text[i:j]
        for m in ADDPAR.finditer(body):
            name = m.group(1).lower()
            mem = MEMBER.search(m.group(2))
            key = (mem.group(1) if mem else name).lower()
            if key not in groups:
                groups[key] = []
                order.append(key)
            if name not in groups[key]:
                groups[key].append(name)
    return [groups[k] for k in order]


def ngspice_groups(device):
    deck = f"t\n.control\ndevhelp {device}\n.endc\n.end\n"
    with tempfile.NamedTemporaryFile("w", suffix=".sp", delete=False) as f:
        f.write(deck)
    out = subprocess.run(["ngspice", "-b", f.name], capture_output=True, text=True).stdout
    os.unlink(f.name)
    groups, order, model = {}, [], False
    for line in out.splitlines():
        if line.startswith("Model Parameters"):
            model = True
            continue
        if line.startswith("Instance Parameters"):
            model = False
        m = re.match(r"\s*(\d+)\s+(\S+)\s+(in|out|inout)\b", line)
        if model and m:
            if m.group(3) == "out":
                continue
            groups.setdefault(m.group(1), []).append(m.group(2).lower())
            if m.group(1) not in order:
                order.append(m.group(1))
    return [groups[k] for k in order]


def ngspice_aliases(fam):
    groups = [g for g in ngspice_groups(NGSPICE[fam])] if fam in NGSPICE else []
    for extra in NGSPICE_EXTRA.get(fam, []):
        for g in groups:
            if extra[0] in g:
                g.extend(n for n in extra[1:] if n not in g)
                break
        else:
            groups.append(list(extra))
    return groups


def xyce_tables(src):
    """Xyce's tables by canonical (ngspice) name: each Xyce group under the
    first name of the ngspice group that shares a name with it."""
    out = {}
    for fam, files in XYCE.items():
        ng = ngspice_aliases(fam)
        rows, seen = [], set()
        groups = xyce_groups(src, files)
        # A group that holds ngspice's canonical name itself takes it first.
        owner = {g[0]: grp[0] for grp in groups for g in ng if g[0] in grp}
        for grp in groups:
            canon = next((g[0] for g in ng for n in grp if n in g), grp[0])
            if owner.get(canon, grp[0]) != grp[0]:
                canon = grp[0]
            if canon in seen:
                print(f"# xyce {fam}: two Xyce groups are ngspice's '{canon}': {grp}", file=sys.stderr)
                continue
            seen.add(canon)
            rows.append((canon, grp))
        out[fam] = rows
    return out


def table(g, family):
    """A grammar's modelparams table for the family: canonical -> spellings, and `only`."""
    text = open(os.path.join(GRAMMARS, f"{g}.spgrammar")).read()
    m = re.search(rf"^modelparams {family}( only)?\n(.*?)^end", text, re.S | re.M)
    if not m:
        return None, False
    rows = {}
    for line in m.group(2).splitlines():
        line = line.split("#")[0].strip()
        if not line:
            continue
        w = line.split()
        if w[0] == "same":
            for n in w[1:]:
                rows[n] = [n]
        else:
            rows[w[0]] = [x for x in w[2:] if x not in ("/", "2")]
    return rows, bool(m.group(1))


def check(src):
    bad = 0
    for fam, files in XYCE.items():
        have = {n for grp in xyce_groups(src, files) for n in grp}
        rows, only = table("xyce", fam)
        if rows is None or not only:
            print(f"xyce {fam}: no `only` table ({len(have)} names in Xyce)")
            bad += 1
            continue
        listed = {s for sp in rows.values() for s in sp}
        for n in sorted(listed - have):
            print(f"xyce {fam}: '{n}' is in the table and not a Xyce parameter")
            bad += 1
        missing = sorted(have - listed)
        if missing:
            print(f"xyce {fam}: Xyce takes {len(missing)} names the table does not list: {' '.join(missing[:12])}{' ...' if len(missing) > 12 else ''}")
            bad += 1
    return bad


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1] == "xyce":
        for fam, rows in xyce_tables(sys.argv[2]).items():
            print(f"modelparams {fam} only")
            same = [c for c, grp in rows if grp == [c]]
            for i in range(0, len(same), 12):
                print("  same " + " ".join(same[i:i + 12]))
            for canon, grp in rows:
                if grp != [canon]:
                    print(f"  {canon} = {' '.join(grp)}")
            print("end")
    elif sys.argv[1] == "ngspice":
        for fam in NGSPICE:
            print(f"modelparams {fam}")
            for grp in ngspice_aliases(fam):
                if len(grp) > 1:
                    print(f"  {grp[0]} = {' '.join(grp)}")
            print("end")
    elif sys.argv[1] == "check":
        sys.exit(1 if check(sys.argv[2]) else 0)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
