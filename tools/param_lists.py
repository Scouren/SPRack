"""The model-card parameters each simulator takes, for the grammars' modelparams tables.

Usage:
    python3 tools/param_lists.py xyce <Xyce checkout>      # from the source, as Xyce -param lists them
    python3 tools/param_lists.py ngspice                   # from ngspice's devhelp (ngspice on PATH)
    python3 tools/param_lists.py vacask <lib/vacask/mod>   # from the OSDI descriptors VACASK loads
    python3 tools/param_lists.py check <Xyce checkout> [<lib/vacask/mod>]   # the grammars' tables against them

`xyce` prints, for each family the grammars map to a Xyce device, every model
parameter its ParametricData declares (Traits::loadModelParameters), one group
per member: a parameter and its synonyms. `ngspice` prints devhelp's groups
(one id, several names). `vacask` prints, for each family, every parameter a
model card of the module VACASK writes it as takes: the OSDI descriptor's
model and instance parameters with their aliases, as lib/osdifile.cpp reads
them (both kinds are valid on a model, include/osdifile.h
modelParameterIndex). `check` reports a name a grammar's table lists that
the simulator does not, and a family whose Xyce table is not `only` or lists
fewer names than Xyce has: what docs/verification.md 4.23 records.
"""
import ctypes, os, re, subprocess, sys, tempfile

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

# family -> the OSDI file and module grammars/vacask.spgrammar writes it as
# (its `needs` and `models` sections), under VACASK's lib/vacask/mod.
VACASK = {
    "diode": "spice/diode.osdi",
    "bjt": "spice/bjt.osdi",
    "vbic": "vbic_1p3_4t.osdi",
    "bsim3": "spice/bsim3v3.osdi",
    "bsim4": "spice/bsim4v8.osdi",
    "psp103": "psp103v4.osdi",
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


class _Param(ctypes.Structure):  # include/osdi.h OsdiParamOpvar
    _fields_ = [("name", ctypes.POINTER(ctypes.c_char_p)), ("num_alias", ctypes.c_uint32),
                ("description", ctypes.c_char_p), ("units", ctypes.c_char_p),
                ("flags", ctypes.c_uint32), ("len", ctypes.c_uint32)]


class _Descriptor(ctypes.Structure):  # include/osdi.h OsdiDescriptor, up to param_opvar
    _fields_ = [("name", ctypes.c_char_p), ("num_nodes", ctypes.c_uint32), ("num_terminals", ctypes.c_uint32),
                ("nodes", ctypes.c_void_p), ("num_jacobian_entries", ctypes.c_uint32),
                ("jacobian_entries", ctypes.c_void_p), ("num_collapsible", ctypes.c_uint32),
                ("collapsible", ctypes.c_void_p), ("collapsed_offset", ctypes.c_uint32),
                ("noise_sources", ctypes.c_void_p), ("num_noise_src", ctypes.c_uint32),
                ("num_params", ctypes.c_uint32), ("num_instance_params", ctypes.c_uint32),
                ("num_opvars", ctypes.c_uint32), ("param_opvar", ctypes.POINTER(_Param))]


PARA_KIND_OPVAR = 2 << 30


def vacask_groups(moddir, file):
    """A model card's parameters of the file's (first) module, each with its
    aliases, lower case, as VACASK reads them; $mfactor is not a card's."""
    lib = ctypes.CDLL(os.path.join(moddir, file))
    base = ctypes.addressof(ctypes.c_char.in_dll(lib, "OSDI_DESCRIPTORS"))
    d = _Descriptor.from_address(base)
    groups = []
    for j in range(d.num_params + d.num_opvars):
        p = d.param_opvar[j]
        if p.flags & (3 << 30) == PARA_KIND_OPVAR:
            continue
        names = [p.name[k].decode().lower() for k in range(p.num_alias + 1)]
        if names[0] != "$mfactor":
            groups.append(names)
    return groups


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


def canonical_tables(groups_of, what):
    """A simulator's tables by canonical name: each of its groups under the
    name of grammars/ngspice.spgrammar's row that shares a name with it (the
    names the IR reads a card in; ngspice 45's devhelp orders some of them
    otherwise, `tcv` before `tbv1`), else under its own first name."""
    out = {}
    for fam, groups in groups_of.items():
        ng = [[c] + sp for c, sp in (table("ngspice", fam)[0] or {}).items()]
        rows, seen = [], set()
        # A group that holds ngspice's canonical name itself takes it first.
        owner = {g[0]: grp[0] for grp in groups for g in ng if g[0] in grp}
        for grp in groups:
            canon = next((g[0] for g in ng for n in grp if n in g), grp[0])
            if owner.get(canon, grp[0]) != grp[0]:
                canon = grp[0]
            if canon in seen:
                print(f"# {what} {fam}: two groups are ngspice's '{canon}': {grp}", file=sys.stderr)
                continue
            seen.add(canon)
            rows.append((canon, grp))
        out[fam] = rows
    return out


def xyce_tables(src):
    return canonical_tables({f: xyce_groups(src, files) for f, files in XYCE.items()}, "xyce")


def vacask_tables(moddir):
    return canonical_tables({f: vacask_groups(moddir, file) for f, file in VACASK.items()}, "vacask")


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


def check_one(g, fam, have):
    rows, only = table(g, fam)
    if rows is None or not only:
        print(f"{g} {fam}: no `only` table ({len(have)} names in {g})")
        return 1
    bad = 0
    listed = {s for sp in rows.values() for s in sp}
    for n in sorted(listed - have):
        print(f"{g} {fam}: '{n}' is in the table and not a {g} parameter")
        bad += 1
    missing = sorted(have - listed)
    if missing:
        print(f"{g} {fam}: {g} takes {len(missing)} names the table does not list: {' '.join(missing[:12])}{' ...' if len(missing) > 12 else ''}")
        bad += 1
    return bad


def check(src, moddir=None):
    bad = sum(check_one("xyce", f, {n for grp in xyce_groups(src, files) for n in grp}) for f, files in XYCE.items())
    if moddir:
        bad += sum(check_one("vacask", f, {n for grp in vacask_groups(moddir, file) for n in grp}) for f, file in VACASK.items())
    return bad


def print_tables(tables):
    for fam, rows in tables.items():
        print(f"modelparams {fam} only")
        same = [c for c, grp in rows if grp == [c]]
        for i in range(0, len(same), 12):
            print("  same " + " ".join(same[i:i + 12]))
        for canon, grp in rows:
            if grp != [canon]:
                print(f"  {canon} = {' '.join(grp)}")
        print("end")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1] == "xyce":
        print_tables(xyce_tables(sys.argv[2]))
    elif sys.argv[1] == "vacask":
        print_tables(vacask_tables(sys.argv[2]))
    elif sys.argv[1] == "ngspice":
        for fam in NGSPICE:
            print(f"modelparams {fam}")
            for grp in ngspice_aliases(fam):
                if len(grp) > 1:
                    print(f"  {grp[0]} = {' '.join(grp)}")
            print("end")
    elif sys.argv[1] == "check":
        sys.exit(1 if check(*sys.argv[2:4]) else 0)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
