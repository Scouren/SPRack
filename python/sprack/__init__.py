"""SPRack: describe a circuit once, write it in any SPICE dialect.

    import sprack

    pdk = sprack.PDK("sky130A")                 # $PDK_ROOT, corner tt
    c = sprack.Circuit("inverter", pdk=pdk)
    c.V("dd", "vdd", 0, 1.8)
    c.V("in", "in", 0, pulse=(0, 1.8, "1n", "50p", "50p", "2n", "4n"))
    c.pfet_01v8("p", "out", "in", "vdd", "vdd", w=1, l=0.15)   # a PDK device
    c.nfet_01v8("n", "out", "in", 0, 0, w=0.5, l=0.15)
    c.tran("10p", "8n")
    print(c.netlist("spectre"))

Nothing here knows a SPICE dialect. Every method builds statements of the
canonical vocabulary the compiled core defines (`sprack.KINDS`), and the core
writes them with readers and writers generated from the `.spgrammar` files.
A statement the chosen dialect cannot express raises `Unsupported`, with the
reason and the dialects that can.

Numbers are Python numbers or strings with an SI suffix: "10n", "4.7k",
"1meg". A bare "M" is refused, because it is milli in SPICE and mega
elsewhere. Any other string is an expression: "2*wmin", "ln(a)**2".
"""

from __future__ import annotations

import hashlib
import json
import os
from typing import Any, Iterable, NamedTuple

from . import _core

__all__ = [
    "Circuit", "PDK", "Report", "Entry", "Netlist", "SprackError", "Unsupported",
    "DIALECTS", "KINDS", "dialects", "translate", "read", "can_write", "why_not", "v", "i",
]

_INFO = json.loads(_core.info())
#: The dialects compiled into the core.
DIALECTS: tuple[str, ...] = tuple(_INFO["dialects"])
#: The canonical vocabulary: statement kind -> class, slots, who can write it.
KINDS: dict[str, dict] = _INFO["kinds"]
#: Functions an expression may call, by canonical name.
FUNCTIONS: tuple[str, ...] = tuple(_INFO["functions"])


# --------------------------------------------------------------------- reports

class Entry(NamedTuple):
    severity: str   # "error", "warning" or "info"
    code: str       # unsupported, loss, untranslated, synthesized, caveat, rename, ...
    line: int       # line in the source netlist, or statement number for a Circuit
    message: str
    file: str = ""

    def __str__(self) -> str:
        where = f"{self.file}:" if self.file else ""
        where += f"line {self.line}: " if self.line else (" " if where else "")
        return f"{self.severity}[{self.code}]: {where}{self.message}"


class Report(list):
    """Everything the translator has to say about one translation."""

    @property
    def errors(self) -> list[Entry]:
        return [e for e in self if e.severity == "error"]

    @property
    def warnings(self) -> list[Entry]:
        return [e for e in self if e.severity == "warning"]

    def __str__(self) -> str:
        return "\n".join(str(e) for e in self)

    @classmethod
    def _from_json(cls, text: str) -> "Report":
        return cls(Entry(d["severity"], d["code"], d["line"], d["message"]) for d in json.loads(text))

    @classmethod
    def _from_log(cls, log: str) -> "Report":
        out = cls()
        for line in log.splitlines():
            head, sep, rest = line.partition(": ")
            sev, _, tail = rest.partition("[")
            code, _, msg = tail.partition("]: ")
            if not sep or sev not in ("error", "warning", "info"):
                continue
            path, _, num = head.rpartition(":")
            if num.isdigit():
                out.append(Entry(sev, code, int(num), msg, path))
            else:
                out.append(Entry(sev, code, 0, msg, head))
        return out


class SprackError(Exception):
    pass


class Unsupported(SprackError):
    """The target dialect cannot say everything that was asked of it.

    `report` holds every entry, `text` the netlist as far as it could be
    written (the lines that could not are comments in it).
    """

    def __init__(self, dialect: str, report: Report, text: str = ""):
        self.dialect, self.report, self.text = dialect, report, text
        errs = report.errors
        shown = "\n".join(f"  - {e.file + ':' if e.file else ''}{'line ' + str(e.line) + ': ' if e.line else ''}{e.message}" for e in errs[:12])
        more = f"\n  ... and {len(errs) - 12} more" if len(errs) > 12 else ""
        super().__init__(f"{len(errs)} thing{'s' if len(errs) != 1 else ''} cannot be written for {dialect}:\n{shown}{more}")


class Netlist(str):
    """A netlist as text, with the report of how it was produced."""
    report: Report

    def __new__(cls, text: str, report: Report):
        self = super().__new__(cls, text)
        self.report = report
        return self


def dialects() -> tuple[str, ...]:
    return DIALECTS


def _dialect(name: str | os.PathLike) -> str:
    """A built-in dialect's name, or the absolute path of a `.spgrammar` file
    (compiled by the core on each call; a mistake in it raises ValueError
    with `path:line: message`)."""
    name = os.fspath(name)
    if name.endswith(".spgrammar"):
        return os.path.abspath(name)
    low = name.lower()
    if low not in DIALECTS:
        raise ValueError(f"unknown dialect {name!r}; built in: {', '.join(DIALECTS)}; or a path to a .spgrammar file")
    return low


def _dialect_tag(d: str) -> str:
    """A directory-name-safe key for a resolved dialect: its name, or for a
    grammar file its base name and a hash of its contents."""
    if not d.endswith(".spgrammar"):
        return d
    with open(d, "rb") as f:
        digest = hashlib.sha1(f.read()).hexdigest()[:8]
    return f"{os.path.basename(d)[:-len('.spgrammar')]}-{digest}"


def can_write(kind: str, dialect: str) -> bool:
    """Whether `dialect` has a statement for this kind (see `KINDS`)."""
    return _dialect(dialect) in KINDS[kind]["writers"]


def why_not(kind: str, dialect: str) -> str | None:
    """Why `dialect` cannot write this kind, or None if it can."""
    d = _dialect(dialect)
    info = KINDS[kind]
    if d in info["writers"]:
        return None
    who = ", ".join(info["writers"]) or "none"
    return f"{info['absent'].get(d, f'{d}.spgrammar defines no rule for it')}. Dialects that define it: {who}"


def translate(source: str, *, frm: str, to: str, strict: bool = True) -> Netlist:
    """Translate netlist text. Raises `Unsupported` unless `strict` is False."""
    text, rep = _core.translate(_dialect(frm), _dialect(to), source)
    report = Report._from_json(rep)
    if strict and report.errors:
        raise Unsupported(to, report, text)
    return Netlist(text, report)


def v(node: Any, ref: Any = None) -> str:
    """The voltage of a node, or between two nodes, as a signal to save or print."""
    return f"v({node})" if ref is None else f"v({node},{ref})"


def i(device: str) -> str:
    """The current through a source, as a signal to save or print."""
    return f"i({device})"


# --------------------------------------------------------------------- builder

_LETTERS = {
    "R": "resistor", "C": "capacitor", "L": "inductor", "K": "mutual", "V": "vsource", "I": "isource",
    "B": "bsource", "E": "vcvs", "G": "vccs", "F": "cccs", "H": "ccvs", "D": "diode", "Q": "bjt",
    "M": "mosfet", "J": "jfet", "Z": "mesfet", "S": "vswitch", "W": "cswitch", "T": "tline",
    "N": "device", "X": "instance",
}

# Positional arguments after the name. "*" stands for "the terminals, then the model".
_POSITIONAL = {
    "resistor": ["pos", "neg", "r"], "capacitor": ["pos", "neg", "c"], "inductor": ["pos", "neg", "l"],
    "mutual": ["l1", "l2", "k"], "vsource": ["pos", "neg", "dc"], "isource": ["pos", "neg", "dc"],
    "bsource": ["pos", "neg"], "vcvs": ["pos", "neg", "cpos", "cneg", "gain"],
    "vccs": ["pos", "neg", "cpos", "cneg", "gm"], "cccs": ["pos", "neg", "vsrc", "gain"],
    "ccvs": ["pos", "neg", "vsrc", "gain"], "tline": ["p1", "n1", "p2", "n2"],
    "diode": "*", "bjt": "*", "mosfet": "*", "jfet": "*", "mesfet": "*", "vswitch": "*", "cswitch": "*",
    "device": "*", "instance": "*",
    # analyses and the rest
    "op": [], "dc": ["src", "start", "stop", "step"], "ac": ["sweep", "points", "fstart", "fstop"],
    "tran": ["step", "stop", "start", "maxstep"], "noise": ["out", "src", "sweep", "points", "fstart", "fstop"],
    "tf": ["out", "src"], "pz": ["in_pos", "in_neg", "out_pos", "out_neg", "transfer", "find"],
    "sens": ["out"], "disto": ["sweep", "points", "fstart", "fstop"], "four": ["freq", "signals"],
    "hb": ["freqs", "harms"], "sp": ["sweep", "points", "fstart", "fstop"], "pss": ["fund", "harms", "tstab"],
    "stb": ["probe", "sweep", "points", "fstart", "fstop"],
    "include": ["path"], "lib": ["path", "section"], "hdl": ["path"], "measure": ["analysis", "name", "spec"],
    "func": ["name", "args", "expr"], "print": ["analysis", "signals"], "save": ["signals"], "global": ["nodes"],
}

_WAVES = {
    "pulse": ["val0", "val1", "delay", "rise", "fall", "width", "period"],
    "sin": ["sinedc", "ampl", "freq", "delay", "damp", "sphase"],
    "exp": ["val0", "val1", "td1", "tau1", "td2", "tau2"],
    "sffm": ["sinedc", "ampl", "freq", "mdi", "fsig"],
    "am": ["ampl", "sinedc", "fsig", "freq", "delay"],
}
_ALIASES = {"model": "master", "uic": "skip_dc", "label": "name"}


def _val(x: Any) -> Any:
    """A Python value in the JSON form the core reads."""
    if x is None:
        return None
    if isinstance(x, bool):
        return "yes" if x else "no"
    if isinstance(x, int):
        return str(x)
    if isinstance(x, float):
        return repr(x)
    if isinstance(x, (list, tuple)):
        return [_val(y) for y in x]
    if isinstance(x, dict):
        return {str(k): _val(y) for k, y in x.items()}
    return str(x)


def _slots(kind: str) -> dict[str, dict]:
    return {s["name"]: s for s in KINDS[kind]["slots"]}


class _Scope:
    """Something statements can be added to: a circuit or a subcircuit body."""

    def __init__(self, pdk: "PDK | None"):
        self.statements: list[dict] = []
        self._pdk = pdk

    # -- the one way in ---------------------------------------------------
    def add(self, kind: str, *args: Any, **kw: Any) -> dict:
        """Add a statement of any kind in `sprack.KINDS`.

        The named methods (`R`, `tran`, `options`, ...) all end up here.
        """
        if kind not in KINDS:
            raise TypeError(f"unknown statement kind {kind!r}; known: {', '.join(sorted(KINDS))}")
        slots = _slots(kind)
        st: dict[str, Any] = {"kind": kind}
        order = _POSITIONAL.get(kind, [n for n in slots if n not in ("name", "params")])
        rest = list(args)
        if "name" in slots and KINDS[kind]["class"] == "device":
            if not rest:
                raise TypeError(f"{kind} needs a name")
            st["name"] = str(rest.pop(0))
        if order == "*":
            # Terminals, then the model or subcircuit.
            if "master" in kw or "model" in kw:
                nodes = rest
            else:
                if len(rest) < 2:
                    raise TypeError(f"{kind} needs its terminals and then its model: {kind}(name, node, ..., model)")
                nodes, st["master"] = rest[:-1], str(rest[-1])
            if "nodes" in slots:
                st["nodes"] = [str(n) for n in nodes]
            else:
                terminals = [n for n, s in slots.items() if s["type"] in ("node", "ref") and n != "master"]
                if len(nodes) > len(terminals):
                    raise TypeError(f"{kind} has at most {len(terminals)} terminals ({', '.join(terminals)}), got {len(nodes)}")
                for name, node in zip(terminals, nodes):
                    st[name] = str(node)
        else:
            if len(rest) > len(order) and not (order and slots[order[-1]]["list"]):
                raise TypeError(f"{kind} takes at most {len(order)} positional values ({', '.join(order)}), got {len(rest)}")
            for idx, name in enumerate(order):
                if not rest:
                    break
                if slots[name]["list"] and idx == len(order) - 1:
                    st[name] = _val(rest if not (len(rest) == 1 and isinstance(rest[0], (list, tuple))) else rest[0])
                    rest = []
                else:
                    st[name] = _val(rest.pop(0))
        params: dict[str, Any] = {}
        for key, value in kw.items():
            key = _ALIASES.get(key, key)
            if value is None:
                continue
            if key in slots and slots[key]["type"] != "params":
                st[key] = _val(value)
            elif key == "params" and "params" in slots:
                params.update(value)
            elif "params" in slots and KINDS[kind]["class"] == "device":
                params[key] = value
            else:
                valid = ", ".join(n for n in slots if n != "params")
                raise TypeError(f"{kind} has no {key!r}; it has: {valid}")
        if params:
            st["params"] = _val(params)
        if kind == "print":
            st.setdefault("style", "print")
        self.statements.append(st)
        return st

    # -- devices ----------------------------------------------------------
    def _source(self, kind: str, letter: str, name: Any, pos: Any, neg: Any, dc: Any, kw: dict) -> dict:
        extra: dict[str, Any] = {}
        ac = kw.pop("ac", None)
        if ac is not None:
            mag, *phase = ac if isinstance(ac, (list, tuple)) else (ac,)
            extra["acmag"] = mag
            if phase:
                extra["acphase"] = phase[0]
        for wave, fields in _WAVES.items():
            given = kw.pop(wave, None)
            if given is None:
                continue
            if "wave" in extra:
                raise TypeError("a source has one waveform")
            given = list(given) if isinstance(given, (list, tuple)) else [given]
            if len(given) > len(fields):
                raise TypeError(f"{wave} takes at most {len(fields)} values: {', '.join(fields)}")
            extra["wave"] = "sine" if wave == "sin" else wave
            extra.update(zip(fields, given))
        pwl = kw.pop("pwl", None)
        if pwl is not None:
            if "wave" in extra:
                raise TypeError("a source has one waveform")
            flat: list[Any] = []
            for point in pwl:
                flat.extend(point) if isinstance(point, (list, tuple)) else flat.append(point)
            extra["wave"], extra["pwl"] = "pwl", flat
        return self.add(kind, f"{letter}{name}", pos, neg, dc, **extra, **kw)

    def V(self, name: Any, pos: Any, neg: Any, dc: Any = None, **kw: Any) -> dict:
        """Voltage source. `ac=1`, `pulse=(v0, v1, delay, rise, fall, width, period)`,
        `sin=(offset, ampl, freq, delay, damp, phase)`, `exp=(...)`, `pwl=[(t, v), ...]`."""
        return self._source("vsource", "V", name, pos, neg, dc, kw)

    def I(self, name: Any, pos: Any, neg: Any, dc: Any = None, **kw: Any) -> dict:
        """Current source; same waveforms as `V`."""
        return self._source("isource", "I", name, pos, neg, dc, kw)

    def __getattr__(self, attr: str):
        if attr.startswith("__"):
            raise AttributeError(attr)
        # `global_`, `print_`: for names Python keeps to itself.
        if attr.endswith("_") and attr[:-1] in KINDS:
            attr = attr[:-1]
        # R, C, L, ... : the SPICE letter is put in front of the name.
        if attr in _LETTERS:
            kind = _LETTERS[attr]
            return lambda name, *a, **k: self.add(kind, f"{attr}{name}", *a, **k)
        # resistor, tran, options, ... : any kind, by its own name.
        if attr in KINDS and attr not in ("opaque", "comment", "subckt", "libsection"):
            return lambda *a, **k: self.add(attr, *a, **k)
        # A device of the PDK.
        pdk = self.__dict__.get("_pdk")
        if pdk is not None:
            dev = pdk.device(attr)
            if dev is not None:
                return lambda name, *nodes, **params: self._pdk_device(dev, name, nodes, params)
            raise AttributeError(f"{attr!r} is neither a statement kind nor a device of {pdk.name}. {pdk._suggest(attr)}")
        raise AttributeError(f"{attr!r} is not a statement kind; known: {', '.join(sorted(k for k in KINDS if k not in ('opaque', 'comment')))}")

    def _pdk_device(self, dev: dict, name: Any, nodes: tuple, params: dict) -> dict:
        if dev["kind"] == "subckt":
            ports = dev["ports"]
            if len(nodes) != len(ports):
                raise TypeError(f"{dev['name']} has {len(ports)} terminals ({', '.join(ports)}), got {len(nodes)}")
            known = {k.lower(): k for k in dev["params"]}
            for key in params:
                if known and key.lower() not in known:
                    raise TypeError(f"{dev['name']} has no parameter {key!r}; it has: {', '.join(dev['params'])}")
            return self.add("instance", str(name), *nodes, dev["name"], **params)
        kind = dev["device"] if dev["device"] in KINDS else "device"
        return self.add(kind, str(name), *nodes, dev["name"], **params)

    # -- structure --------------------------------------------------------
    def param(self, **values: Any) -> dict:
        """Netlist parameters: `c.param(vdd=1.8, wn="2*wmin")`."""
        st = {"kind": "param", "params": _val(values)}
        self.statements.append(st)
        return st

    def model(self, name: str, family: str | None = None, polarity: str | None = None, *, type: str | None = None, **params: Any) -> dict:
        """A model card. `family` is canonical ("bsim4", "diode", "bjt", ...) with
        `polarity` "n", "p", "npn" or "pnp"; or give `type` for a Verilog-A module."""
        st: dict[str, Any] = {"kind": "model", "name": name}
        if family:
            st["family"] = family
        if polarity:
            st["polarity"] = polarity
        if type:
            st["type"] = type
        if params:
            st["params"] = _val(params)
        self.statements.append(st)
        return st

    def subckt(self, name: str, *ports: Any, **params: Any) -> "Subckt":
        """Define a subcircuit. Use as `with c.subckt("inv", "in", "out") as s: s.R(...)`."""
        sub = Subckt(name, ports, params, self._pdk)
        self.statements.append(sub._stmt)
        return sub

    def options(self, **values: Any) -> dict:
        """Simulator options from the shared vocabulary: reltol, abstol, vntol,
        gmin, temp, tnom, scale, method ("trap", "gear", "euler"), maxord, chgtol, trtol."""
        return self.add("options", **values)

    def temp(self, value: Any) -> dict:
        return self.add("options", temp=value)

    def ic(self, values: dict | None = None, **more: Any) -> dict:
        """Initial node voltages: `c.ic(out=0.9)` or `c.ic({"out": 0.9})`."""
        st = {"kind": "ic", "values": _val({**(values or {}), **more})}
        self.statements.append(st)
        return st

    def nodeset(self, values: dict | None = None, **more: Any) -> dict:
        st = {"kind": "nodeset", "values": _val({**(values or {}), **more})}
        self.statements.append(st)
        return st

    def comment(self, text: str) -> dict:
        st = {"kind": "comment", "raw": text}
        self.statements.append(st)
        return st


class Subckt(_Scope):
    def __init__(self, name: str, ports: Iterable[Any], params: dict, pdk: "PDK | None"):
        super().__init__(pdk)
        self._stmt: dict[str, Any] = {"kind": "subckt", "name": name, "ports": [str(p) for p in ports], "body": self.statements}
        if params:
            self._stmt["params"] = _val(params)

    def __enter__(self) -> "Subckt":
        return self

    def __exit__(self, *exc: Any) -> None:
        return None


class Circuit(_Scope):
    """A circuit, its analyses and what to record, independent of any simulator."""

    def __init__(self, title: str = "untitled", pdk: "PDK | None" = None):
        super().__init__(pdk)
        self.title = title
        self.pdk = pdk

    @classmethod
    def read(cls, source: str, dialect: str) -> "Circuit":
        """A circuit from an existing netlist in any dialect."""
        text, rep = _core.read(_dialect(dialect), source)
        data = json.loads(text)
        c = cls(data.get("title") or "untitled")
        c.statements = data["stmts"]
        c._source_dialect = data.get("dialect", "")
        c.read_report = Report._from_json(rep)
        return c

    def to_json(self, dialect: str | None = None, *, strict: bool = True) -> str:
        """The circuit in the core's JSON form. With a dialect, the PDK's
        libraries are referenced the way that dialect needs them."""
        stmts = list(self.statements)
        if self.pdk is not None and dialect is not None:
            stmts = self.pdk.statements(dialect, strict=strict) + stmts
        return json.dumps({"title": self.title, "dialect": getattr(self, "_source_dialect", "") or "sprack", "stmts": stmts})

    def netlist(self, dialect: str, *, strict: bool = True) -> Netlist:
        """The circuit as a netlist for `dialect`.

        Raises `Unsupported` if anything in it has no form there, naming the
        reason and the dialects that can; `strict=False` returns the netlist
        anyway, with the report attached as `.report`.
        """
        d = _dialect(dialect)
        text, rep = _core.write(d, self.to_json(d, strict=strict))
        report = Report._from_json(rep)
        if strict and report.errors:
            raise Unsupported(d, report, text)
        if self.pdk is not None:
            # What translating the PDK's own libraries could not say belongs
            # to this netlist's report too.
            report.extend(self.pdk.library_errors(d))
        return Netlist(text, report)

    def write(self, path: str, dialect: str, *, strict: bool = True) -> Netlist:
        out = self.netlist(dialect, strict=strict)
        with open(path, "w") as f:
            f.write(out)
        return out

    def check(self, dialect: str) -> Report:
        """What writing this circuit for `dialect` would report, without raising."""
        return self.netlist(dialect, strict=False).report


# ------------------------------------------------------------------------ PDKs

_PDK_DIR = os.path.join(os.path.dirname(__file__), "pdks")


def _manifests() -> dict[str, dict]:
    out = {}
    for fn in sorted(os.listdir(_PDK_DIR)):
        if fn.endswith(".json"):
            with open(os.path.join(_PDK_DIR, fn)) as f:
                m = json.load(f)
            for key in [m["name"], *m.get("aliases", [])]:
                out[key.lower()] = m
    return out


class PDK:
    """A process design kit: where its models are, and what devices it has.

        pdk = sprack.PDK("sky130A")                         # from $PDK_ROOT
        pdk = sprack.PDK("ASAP7", root="~/asap7", corner="ff")
        sorted(pdk.devices)                                 # every device it defines

    The devices become methods of a `Circuit` built with this PDK. The models
    stay in the PDK's own files when the target dialect is the one the PDK
    ships; for any other dialect the whole library is translated once into a
    cache directory and referenced from there.

    A manifest (a small JSON file in `sprack/pdks/`) says which dialect a PDK
    is written in and which files make up each corner; nothing else about a
    PDK is built in. `PDK.known()` lists them; pass `manifest=` to use your own.
    """

    def __init__(self, name: str, root: str | None = None, corner: str | None = None, *,
                 manifest: dict | str | None = None, cache_dir: str | None = None):
        if manifest is None:
            known = _manifests()
            if name.lower() not in known:
                raise SprackError(f"no manifest for PDK {name!r}; known: {', '.join(PDK.known())}. Pass manifest= for another PDK.")
            manifest = known[name.lower()]
        elif isinstance(manifest, str):
            with open(manifest) as f:
                manifest = json.load(f)
        self.manifest: dict = manifest
        self.name: str = manifest["name"]
        self.dialect: str = manifest["dialect"]
        self.prefix: str = manifest.get("prefix", "")
        self.cache_dir = os.path.expanduser(cache_dir or os.environ.get("SPRACK_CACHE") or "~/.cache/sprack")
        self.root, self._vars = self._locate(root)
        self.corners: tuple[str, ...] = tuple(manifest["corners"])
        self.corner = corner or manifest.get("default_corner") or self.corners[0]
        if self.corner not in manifest["corners"]:
            raise SprackError(f"{self.name} has no corner {self.corner!r}; it has: {', '.join(self.corners)}")
        self._devices: dict[str, dict] | None = None

    @staticmethod
    def known() -> list[str]:
        return sorted({m["name"] for m in _manifests().values()})

    def _locate(self, root: str | None) -> tuple[str, dict]:
        m = self.manifest
        candidates = [root] if root else [os.environ[v] for v in m.get("env", []) if os.environ.get(v)]
        if not candidates:
            raise SprackError(f"{self.name}: give root=, or set ${' or $'.join(m.get('env', ['PDK_ROOT']))}")
        tried = []
        for cand in candidates:
            base = os.path.abspath(os.path.expanduser(cand))
            for layout in m["layouts"]:
                probe = os.path.join(base, layout["probe"])
                tried.append(probe)
                if os.path.isfile(probe):
                    return base, dict(layout.get("vars", {}))
        raise SprackError(f"{self.name}: no model library found. Looked for:\n  " + "\n  ".join(tried))

    def _fmt(self, text: str) -> str:
        return text.format(root=self.root, **self._vars)

    def entries(self, corner: str | None = None) -> list[tuple[str, str | None]]:
        """The (file, section) pairs that make up a corner, as absolute paths."""
        pairs = self.manifest["corners"][corner or self.corner]
        return [(os.path.normpath(os.path.join(self.root, self._fmt(f))), sec) for f, sec in pairs]

    def _defines(self) -> str:
        defs = {k: os.path.normpath(self._fmt(val)) for k, val in self.manifest.get("define", {}).items()}
        return "\n".join(f"{k}={val}" for k, val in {**os.environ, **defs}.items() if "\n" not in val)

    def _tops(self) -> list[str]:
        seen: list[str] = []
        for corner in self.manifest["corners"]:
            for path, _ in self.entries(corner):
                if path not in seen and os.path.isfile(path):
                    seen.append(path)
        return seen

    def _stamp(self) -> str:
        h = hashlib.sha1()
        h.update(self.root.encode())
        for path in self._tops():
            st = os.stat(path)
            h.update(f"{path}:{st.st_mtime_ns}:{st.st_size}".encode())
        h.update(_core.info().encode())
        return h.hexdigest()[:16]

    # -- devices ----------------------------------------------------------
    @property
    def devices(self) -> dict[str, dict]:
        """Every subcircuit and model the PDK's libraries define, by name.

        A subcircuit entry has `ports` and `params` (with defaults); a model
        entry has `device` (mosfet, bjt, diode, ...), `family` and `polarity`.
        """
        if self._devices is None:
            cache = os.path.join(self.cache_dir, self.name, f"catalog-{self._stamp()}.json")
            if os.path.isfile(cache):
                with open(cache) as f:
                    data = json.load(f)
            else:
                text, _log = _core.project(self.dialect, "", "\n".join(self._tops()), "", self._defines(), True)
                data = json.loads(text)
                os.makedirs(os.path.dirname(cache), exist_ok=True)
                with open(cache, "w") as f:
                    f.write(text)
            devs: dict[str, dict] = {}
            for d in data["devices"]:
                # Binned model cards (nch.1, nch.2, ...) are one device.
                base, dot, tail = d["name"].rpartition(".")
                name = base if dot and tail.isdigit() else d["name"]
                devs.setdefault(name, {**d, "name": name})
            self._devices = devs
        return self._devices

    def device(self, name: str) -> dict | None:
        """Look a device up by its name, with or without the PDK's prefix, in any case."""
        devs = self.devices
        for cand in (name, self.prefix + name):
            if cand in devs:
                return devs[cand]
        low = {k.lower(): k for k in devs}
        for cand in (name.lower(), (self.prefix + name).lower()):
            if cand in low:
                return devs[low[cand]]
        return None

    def _suggest(self, name: str) -> str:
        import difflib
        short = [k[len(self.prefix):] if self.prefix and k.startswith(self.prefix) else k for k in self.devices]
        near = difflib.get_close_matches(name, short, n=5, cutoff=0.5)
        return f"Did you mean: {', '.join(near)}?" if near else f"It has {len(short)} devices; see pdk.devices."

    def __dir__(self):
        short = [k[len(self.prefix):] if self.prefix and k.startswith(self.prefix) else k for k in self.devices]
        return sorted(set(super().__dir__()) | {s for s in short if s.isidentifier()})

    # -- the libraries, per dialect ------------------------------------
    def translate(self, dialect: str, out: str | None = None, *, strict: bool = True) -> str:
        """Translate the PDK's model libraries to `dialect`; returns the directory.

        Done once per PDK and dialect and kept in the cache. Raises
        `Unsupported` if anything in the libraries has no form in the target
        (the full list is in `sprack.log` in that directory); `strict=False`
        accepts the copy as it is.
        """
        d = _dialect(dialect)
        out = out or os.path.join(self.cache_dir, self.name, f"{_dialect_tag(d)}-{self._stamp()}")
        marker = os.path.join(out, "sprack.json")
        if os.path.isfile(marker):
            with open(marker) as f:
                summary = json.load(f)
            with open(os.path.join(out, "sprack.log")) as f:
                log = f.read()
        else:
            os.makedirs(out, exist_ok=True)
            text, log = _core.project(self.dialect, d, "\n".join(self._tops()), out, self._defines(), True)
            summary = json.loads(text)
            with open(os.path.join(out, "sprack.log"), "w") as f:
                f.write(log)
            with open(marker, "w") as f:
                json.dump(summary, f)
        self._roots = getattr(self, "_roots", {})
        self._roots[d] = (out, summary["root"], Report(e for e in Report._from_log(log) if e.severity == "error"))
        if strict and summary["errors"]:
            raise Unsupported(d, Report._from_log(log), "")
        return out

    def library_errors(self, dialect: str) -> Report:
        """What could not be said when the libraries were translated to `dialect`."""
        d = _dialect(dialect)
        if d == self.dialect:
            return Report()
        if d not in getattr(self, "_roots", {}):
            self.translate(d, strict=False)
        return self._roots[d][2]

    def statements(self, dialect: str, *, strict: bool = True) -> list[dict]:
        """The statements that bring this PDK's corner into a netlist for `dialect`."""
        d = _dialect(dialect)
        out: list[dict] = []
        if d == self.dialect:
            mapped = self.entries()
            for item in self.manifest.get("load", []):
                path = os.path.normpath(os.path.join(self.root, self._fmt(item)))
                if os.path.isfile(path):
                    out.append({"kind": "hdl", "path": path})
        else:
            tree = self.translate(d, strict=strict)
            src_root = self._roots[d][1]
            mapped = [(os.path.join(tree, os.path.relpath(p, src_root)), sec) for p, sec in self.entries()]
        for path, section in mapped:
            out.append({"kind": "lib", "path": path, "section": section} if section else {"kind": "include", "path": path})
        return out

    def __repr__(self) -> str:
        return f"PDK({self.name!r}, root={self.root!r}, corner={self.corner!r}, dialect={self.dialect!r})"


def read(source: str, dialect: str) -> Circuit:
    """Shorthand for `Circuit.read`."""
    return Circuit.read(source, dialect)
