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
import keyword
import os
import re
import shutil
import tempfile
import time
from typing import Any, Iterable, NamedTuple

from . import _core

__all__ = [
    "Circuit", "PDK", "Report", "Entry", "Netlist", "SprackError", "Unsupported",
    "DIALECTS", "KINDS", "dialects", "translate", "read", "to_python", "can_write", "why_not", "v", "i",
    "word", "quoted", "expr",
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


def word(text: str) -> dict:
    """A word to be written exactly as it is where a value stands, neither a
    number nor an expression: `c.model("n", "bsim3", "n", flavour=sprack.word("a.b"))`."""
    return _Typed(raw=str(text))


def quoted(text: str) -> dict:
    """A quoted string as a value: `simulation=sprack.quoted("dinv.vvp")`."""
    return _Typed(str=str(text))


def expr(text: str) -> dict:
    """An expression, where a plain string would be read as something else:
    a number (`sprack.expr("13")` is written `{13}`) or a signal's name."""
    return _Typed(expr=str(text))


class _Typed(dict):
    """A value that says its type, in the JSON form the core reads."""


class _Stmt(dict):
    """A statement, as the builder returns it: the dict the core reads.

    One that holds other statements (a subcircuit, a library section, a
    conditional, a sweep, a Monte Carlo run, an alter) is filled in a `with`
    block: `with c.step("rv", "1k", "3k", "1k") as s: s.tran("1n", "1u")`.
    """
    _scope: "_Scope"

    def tail(self, text: str) -> "_Stmt":
        """Give the statement a trailing comment."""
        self["tail"] = str(text)
        return self

    def __enter__(self) -> "_Scope":
        body = _Scope(self._scope._pdk)
        body.statements = self.setdefault("body", [])
        body._report = self._scope._report
        body._grammars = self._scope._grammars
        return body

    def __exit__(self, *exc: Any) -> None:
        return None


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
    # b3: analyses
    "pac": ["sweep", "points", "fstart", "fstop"],
    "pnoise": ["out", "src", "sweep", "points", "fstart", "fstop"],
    "pxf": ["out", "sweep", "points", "fstart", "fstop"], "psp": ["sweep", "points", "fstart", "fstop"],
    "xf": ["out", "sweep", "points", "fstart", "fstop"], "dcmatch": ["out"], "trannoise": ["out"],
    "phasenoise": ["out", "sweep", "points", "fstart", "fstop"], "envelope": ["clock", "stop"],
    "qpss": ["funds", "harms"],
    # b4: devices, sources, outputs
    "lossyline": "*", "ctlsrc": ["pos", "neg", "form"], "relay": ["pos", "neg", "cpos", "cneg"], "simctl": ["cmd", "args"],
    # b1: sweeps
    "step": ["param", "start", "stop", "step"], "data": ["name", "cols", "values"],
    # b2: statistics and structure
    "statistics": [], "statgroup": ["scope"], "vary": ["param", "dist", "std"], "correlate": ["names", "cc"],
    "montecarlo": ["runs"], "library": ["name"],
    # c2: alter
    "alter": ["name"],
}

_WAVES = {
    "pulse": ["val0", "val1", "delay", "rise", "fall", "width", "period", "count"],
    "sin": ["sinedc", "ampl", "freq", "delay", "damp", "sphase"],
    "exp": ["val0", "val1", "td1", "tau1", "td2", "tau2"],
    "sffm": ["sinedc", "ampl", "freq", "mdi", "fsig"],
    # offset, modulation offset and amplitude, modulating and carrier frequency
    "am": ["sinedc", "val0", "ampl", "fsig", "freq", "delay", "mphase", "sphase"],
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


def _params(pairs: Iterable[tuple[Any, Any]]) -> Any:
    """Parameters in the JSON form the core reads: an object, or `[name,
    value]` pairs when a name comes twice (`toxref=1.26n ... toxref=1.3n`)."""
    out = [[str(k), _val(v)] for k, v in pairs]
    return dict(out) if len({k for k, _ in out}) == len(out) else out


def _slots(kind: str) -> dict[str, dict]:
    return {s["name"]: s for s in KINDS[kind]["slots"]}


class _Scope:
    """Something statements can be added to: a circuit or a subcircuit body."""

    def __init__(self, pdk: "PDK | None"):
        self.statements: list[dict] = []
        self._pdk = pdk
        # What `code` could not read; shared by a circuit and its subcircuits.
        self._report = Report()
        # The grammar file of each dialect read here that is not built in,
        # by the name the dialect calls itself; shared likewise.
        self._grammars: dict[str, str] = {}

    def _push(self, st: dict) -> _Stmt:
        out = _Stmt(st)
        out._scope = self
        self.statements.append(out)
        return out

    # -- the one way in ---------------------------------------------------
    def add(self, kind: str, *args: Any, **kw: Any) -> _Stmt:
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
        params: list[tuple[str, Any]] = []
        for key, value in kw.items():
            # An alias gives way to a slot of the name (`model` of a `vary`).
            key = key if key in slots else _ALIASES.get(key, key)
            if value is None:
                continue
            if key == "params" and "params" in slots:
                # A dict, or (name, value) pairs where a name comes twice.
                params.extend(value.items() if isinstance(value, dict) else value)
            elif key in slots:
                st[key] = _val(value)
            elif "params" in slots and KINDS[kind]["class"] == "device":
                params.append((key, value))
            else:
                valid = ", ".join(n for n in slots if n != "params")
                raise TypeError(f"{kind} has no {key!r}; it has: {valid}")
        if params:
            st["params"] = _params(params)
        if kind == "print":
            st.setdefault("style", "print")
        return self._push(st)

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
        if attr in KINDS and attr not in ("opaque", "comment", "subckt"):
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
        # A model card: the instance parameters its device takes in the
        # PDK's dialect, where that grammar lists them.
        table = KINDS.get(kind, {}).get("params", {}).get(self._pdk.dialect)
        if table:
            for key in params:
                if key.lower() not in table:
                    raise TypeError(f"{dev['name']} is a {kind} of a {self._pdk.dialect} model card, which takes no parameter {key!r}; it takes: {', '.join(table)}")
        if "master" not in _slots(kind):
            # A source's kind alone has no model slot: only VACASK lets a source
            # name a model, and that model takes no parameter (docs/verification.md, 9.4).
            raise TypeError(f"{dev['name']} is a model card for kind {kind!r}, which takes no model: such a model holds no parameter, so add the device itself, c.{kind}(...)")
        # By keyword: positionally a resistor, capacitor or inductor takes its value there.
        return self.add(kind, str(name), *nodes, master=dev["name"], **params)

    # -- structure --------------------------------------------------------
    def param(self, **values: Any) -> dict:
        """Netlist parameters: `c.param(vdd=1.8, wn="2*wmin")`."""
        return self._push({"kind": "param", "params": _val(values)})

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
        return self._push(st)

    def subckt(self, name: str, *ports: Any, inline: Any = None, **params: Any) -> _Stmt:
        """Define a subcircuit. Use as `with c.subckt("inv", "in", "out") as s: s.R(...)`.
        `inline=True`: an inline subcircuit (Spectre), whose devices are named
        as if they stood where its instance does."""
        st: dict[str, Any] = {"kind": "subckt", "name": name, "ports": [str(p) for p in ports], "body": []}
        if params:
            st["params"] = _val(params)
        if inline is not None:
            st["inline"] = _val(inline)
        return self._push(st)

    def options(self, **values: Any) -> dict:
        """Simulator options from the shared vocabulary: reltol, abstol, vntol,
        gmin, temp, tnom, scale, method ("trap", "gear", "euler"), maxord, chgtol, trtol."""
        return self.add("options", **values)

    def temp(self, value: Any) -> dict:
        return self.add("options", temp=value)

    def ic(self, values: dict | None = None, **more: Any) -> dict:
        """Initial node voltages: `c.ic(out=0.9)` or `c.ic({"out": 0.9})`."""
        return self._push({"kind": "ic", "values": _val({**(values or {}), **more})})

    def nodeset(self, values: dict | None = None, **more: Any) -> dict:
        return self._push({"kind": "nodeset", "values": _val({**(values or {}), **more})})

    def code(self, text: str, dialect: str = "ngspice") -> list[dict]:
        """Add statements written as `dialect` text (a built-in name or a
        `.spgrammar` path), read as `sprack.read` would but with no title line.

        They are statements like any other and are written in whatever
        dialect the netlist is for: `c.code(".tran 1n 1u\\n.save v(out)")`
        works for a Spectre target too. Returns the statements added. For a
        target of the same dialect, the block's own options and parameters,
        and lines no rule understands, are written as they are; for any other
        target such a line is an error in `netlist()`'s report, as is
        anything the reader reports (file `code`).
        """
        # With a PDK, its libraries' names are known to the reader too: a
        # Spectre instance of one of their models is the device it models.
        env = () if self._pdk is None else (json.dumps({"env": self._pdk._env}),)
        d = _dialect(dialect)
        out, rep = _core.read(d, text, True, *env)
        data = json.loads(out)
        if d != data["dialect"]:
            self._grammars[data["dialect"]] = d
        stmts = data["stmts"]
        # Each statement remembers its dialect, so a target of the same
        # dialect writes its own options and parameters as they were.
        def tag(sts: list[dict]) -> None:
            for st in sts:
                st["dialect"] = data["dialect"]
                tag(st.get("body", []))
        tag(stmts)
        self._report.extend(e._replace(file="code") for e in Report._from_json(rep))
        self.statements.extend(stmts)
        return stmts

    def comment(self, text: str) -> dict:
        return self._push({"kind": "comment", "raw": text})


class Circuit(_Scope):
    """A circuit, its analyses and what to record, independent of any simulator."""

    def __init__(self, title: str = "untitled", pdk: "PDK | None" = None, dialect: str | None = None):
        """`dialect`: the dialect whose terms the statements are in, as for a
        netlist read from it. What that dialect assumes where a statement
        says nothing (HSPICE's TNOM of 25) then holds here too, and its own
        options and analysis parameters are written back to it as they are."""
        super().__init__(pdk)
        self.title = title
        self.pdk = pdk
        self._source_dialect = dialect or ""
        #: Names that differ only by case are one name (a Spectre netlist
        #: that says `insensitive=yes`).
        self.folds_case = False

    @classmethod
    def read(cls, source: str, dialect: str) -> "Circuit":
        """A circuit from an existing netlist in any dialect."""
        d = _dialect(dialect)
        text, rep = _core.read(d, source)
        data = json.loads(text)
        c = cls(data.get("title") or "untitled", dialect=data.get("dialect", ""))
        if d != c._source_dialect:
            c._grammars[c._source_dialect] = d
        c.statements = data["stmts"]
        c.folds_case = bool(data.get("folds_case"))
        c.read_report = Report._from_json(rep)
        return c

    def _doc(self, dialect: str | None, strict: bool) -> dict:
        """What `to_json` encodes. The statements are the circuit's own."""
        doc = {"title": self.title, "dialect": self._source_dialect or "sprack", "folds_case": self.folds_case, "stmts": list(self.statements)}
        if self.pdk is not None and dialect is not None:
            doc["stmts"] = self.pdk.statements(dialect, strict=strict) + doc["stmts"]
            # What the PDK's libraries declare: the writer sees their names
            # only, and a model or a function of theirs is one it knows.
            doc["env"] = self.pdk._env
        return doc

    def to_json(self, dialect: str | None = None, *, strict: bool = True) -> str:
        """The circuit in the core's JSON form. With a dialect, the PDK's
        libraries are referenced the way that dialect needs them."""
        return json.dumps(self._doc(dialect, strict))

    def python(self, name: str = "c") -> str:
        """The circuit as a flat Python script that builds it again with this
        package: one call per statement on a `Circuit` named `name`, and a
        `with` block for a statement that holds others. No functions, no
        classes, no netlist text.

        Netlists written from the script are those written from this
        circuit, comments included; only blank lines are not rebuilt (they
        are blank lines of the script). The one thing the builder has no
        call for is a line no rule of its dialect understood: that is a
        `code` block of that dialect's text.
        """
        d = self._source_dialect
        out = ["import sprack", "", f"{name} = sprack.Circuit({_show(self.title)}" + (f", dialect={_show(d)}" if d else "") + ")"]
        if self.folds_case:
            out.append(f"{name}.folds_case = True")
        _script(self.statements, name, "b" if name.startswith("s") else "s", d, 0, out)
        return "\n".join(out) + "\n"

    def netlist(self, dialect: str, *, strict: bool = True) -> Netlist:
        """The circuit as a netlist for `dialect`.

        Raises `Unsupported` if anything in it has no form there, naming the
        reason and the dialects that can; `strict=False` returns the netlist
        anyway, with the report attached as `.report`.
        """
        d = _dialect(dialect)
        data = self._doc(d, strict)
        renames: dict[str, str] = dict(self.pdk._roots[d][3]) if d in getattr(self.pdk, "_roots", {}) else {}
        lib_report = Report()
        # Both give back the statements, those they change as copies: the
        # circuit's own stay as they are, and the rest is not copied at all.
        data["stmts"] = _translate_libraries(data["stmts"], data["dialect"], d, lib_report, renames, self._grammars)
        data["stmts"] = _rename_masters(data["stmts"], renames)
        text, rep = _core.write(d, json.dumps(data))
        report = Report(self._report + lib_report + Report._from_json(rep))
        if strict and report.errors:
            raise Unsupported(d, report, text)
        if self.pdk is not None:
            # What translating the PDK's own libraries could not say belongs
            # to this netlist's report too.
            report.extend(self.pdk.library_errors(d))
        return Netlist(text, report)

    def write(self, path: str, dialect: str, *, strict: bool = True) -> Netlist:
        out = self.netlist(dialect, strict=strict)
        # The same bytes on every platform, as the sprack command writes them.
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(out)
        return out

    def check(self, dialect: str) -> Report:
        """What writing this circuit for `dialect` would report, without raising."""
        return self.netlist(dialect, strict=False).report


# ------------------------------------------------------------------- as Python

_SI = {12: "T", 9: "G", 6: "meg", 3: "k", -3: "m", -6: "u", -9: "n", -12: "p", -15: "f", -18: "a"}
_SI_EXP = {s: e for e, s in _SI.items()}
_EXPONENT = re.compile(r"(-?\d+(?:\.\d+)?)e(-?\d+)")
_SUFFIXED = re.compile(r"(-?\d+(?:\.\d+)?)(T|G|meg|k|m|u|n|p|f|a)")
_PLAIN = re.compile(r"-?\d+(?:\.\d+)?(?:e-?\d+)?")
_TYPED = {"raw": "word", "str": "quoted", "expr": "expr"}
#: Keywords of `V` and `I` that are not statement slots.
_SOURCE_SUGAR = ("ac", "pwl", *_WAVES)


def _pv(v: Any, ty: str) -> Any:
    """The Python value to pass for the JSON value `v` of a slot of type
    `ty`: a number where its text is one (`"1.8"` is 1.8, a node `"0"` is 0),
    and `"1e3"` as `"1k"`. The digits never change."""
    if ty == "params":
        if isinstance(v, dict):
            return {k: _pv(x, "value") for k, x in v.items()}
        return [(k, _pv(x, "value")) for k, x in v]  # pairs: a name comes twice
    if isinstance(v, list):
        return [_pv(x, ty) for x in v]
    if isinstance(v, dict):
        if ty == "path" and list(v) == ["str"]:
            return v["str"]
        return _Typed(v) if len(v) == 1 and next(iter(v)) in _TYPED else v
    if not isinstance(v, str) or ty not in ("node", "value", "atom"):
        return v
    if ty == "atom" and v in ("yes", "no"):
        return v == "yes"
    m = _EXPONENT.fullmatch(v) if ty == "value" else None
    if m and int(m.group(2)) in _SI:
        return m.group(1) + _SI[int(m.group(2))]
    if _PLAIN.fullmatch(v):
        for num in (int, float):
            try:
                if _val(num(v)) == v:
                    return num(v)
            except ValueError:
                pass
    return v


def _show(v: Any) -> str:
    """A Python literal for a value `_pv` made."""
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, _Typed):
        (tag, text), = v.items()
        return f"sprack.{_TYPED[tag]}({json.dumps(text)})"
    if isinstance(v, tuple):
        return "(" + ", ".join(_show(x) for x in v) + ("," if len(v) == 1 else "") + ")"
    if isinstance(v, list):
        return "[" + ", ".join(_show(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{_show(k)}: {_show(x)}" for k, x in v.items()) + "}"
    return repr(v)


def _show_call(method: str, args: list, kw: dict) -> str:
    # From the first name Python cannot spell as a keyword (`from` of a
    # measure, a diode's `is`) the rest go in `**{...}`: the order is kept.
    keys = list(kw)
    n = next((i for i, k in enumerate(keys) if not k.isidentifier() or keyword.iskeyword(k)), len(keys))
    parts = [_show(a) for a in args] + [f"{k}={_show(kw[k])}" for k in keys[:n]]
    if n < len(keys):
        parts.append("**" + _show({k: kw[k] for k in keys[n:]}))
    return f"{method}({', '.join(parts)})"


def _canon(v: Any) -> Any:
    """A value as the core reads it: `1k` is `1e3`, and parameters keep their order."""
    if isinstance(v, str):
        m = _SUFFIXED.fullmatch(v)
        return f"{m.group(1)}e{_SI_EXP[m.group(2)]}" if m else v
    if isinstance(v, (list, tuple)):
        return [_canon(x) for x in v]
    if isinstance(v, dict):
        return [[k, _canon(x)] for k, x in v.items()]
    return v


def _norm(st: dict, drop: tuple = ()) -> dict:
    """What of a statement a call has to rebuild: not its line number, its
    trailing comment or its body, and a path is a path quoted or not."""
    types = {sl["name"]: sl["type"] for sl in KINDS.get(st.get("kind"), {}).get("slots", [])}
    out = {}
    for k, v in st.items():
        if k in ("line", "tail", "body") or k in drop or v is None or v == []:
            continue
        if types.get(k) == "path" and isinstance(v, dict) and list(v) == ["str"]:
            v = v["str"]
        out[k] = _canon(v)
    return out


def _deep(st: dict, drop: tuple = ()) -> tuple:
    return _norm(st, drop), st.get("tail"), [_deep(b, drop) for b in st.get("body", [])]


def _plain_params(params: Any, taken: Iterable[str], flags: bool = True) -> bool:
    """Can these parameters be keyword arguments, each under its own name?
    `flags`: also one without a value (`add` takes None as not given)."""
    return isinstance(params, dict) and all(k not in taken and (flags or v is not None) for k, v in params.items())


def _calls(st: dict) -> Iterable[tuple[str, list, dict]]:
    """The builder calls that may add statement `st`, the most readable first."""
    kind = st.get("kind")
    if kind == "comment":
        yield "comment", [st.get("raw", "")], {}
        return
    if kind not in KINDS or kind == "opaque":
        return
    slots = _slots(kind)
    given = {k: v for k, v in st.items() if k in slots and v is not None}
    params = given.pop("params", None)
    pv = None if params is None else _pv(params, "params")
    everything = {k: _pv(v, slots[k]["type"]) for k, v in given.items()}
    if params is not None:
        everything["params"] = pv
    device = KINDS[kind]["class"] == "device"
    if kind == "subckt":
        kw = {} if "inline" not in given else {"inline": True if given["inline"] == "yes" else given["inline"]}
        if isinstance(given.get("name"), str) and _plain_params(pv or {}, ("self", "name", "ports", "inline")):
            yield "subckt", [given["name"], *given.get("ports", [])], {**kw, **(pv or {})}
    elif kind == "param" and _plain_params(pv, ("self",)):
        yield "param", [], pv
    elif kind == "model" and isinstance(given.get("name"), str):
        args = [given["name"]] + [given[k] for k in ("family", "polarity") if k in given and "family" in given]
        kw = {k: given[k] for k in ("polarity", "type") if k in given and given[k] not in args[1:]}
        if _plain_params(pv or {}, ("self", "name", "family", "polarity", "type")):
            yield "model", args, {**kw, **(pv or {})}
    elif kind in ("ic", "nodeset") and list(given) == ["values"]:
        yield kind, [everything["values"]], {}
    elif kind == "options":
        yield "options", [], everything
    elif isinstance(given.get("name"), str) or not device:
        method = kind + "_" if keyword.iskeyword(kind) or kind == "print" else kind
        args: list = []
        kw = {}
        if device:
            name = given.pop("name")
            # `c.R("1", ...)` is R1: the letter method when the name starts with it.
            if len(name) > 1 and _LETTERS.get(name[0]) == kind:
                method, name = name[0], name[1:]
            args.append(name)
        order = _POSITIONAL.get(kind, [n for n in slots if n not in ("name", "params")])
        if order == "*":
            if "nodes" in slots:
                args += [_pv(n, "node") for n in given.pop("nodes", [])]
            else:
                for n, sl in slots.items():
                    if sl["type"] in ("node", "ref") and n != "master":
                        if n not in given:
                            break
                        args.append(_pv(given.pop(n), "node"))
            # The model comes after the terminals; with none it is named.
            if "master" in given and len(args) > 1:
                args.append(given.pop("master"))
            elif "master" in given:
                kw["model"] = given.pop("master")
        else:
            for n in order:
                if n not in given:
                    break
                v = _pv(given.pop(n), slots[n]["type"])
                # A list in the last place is the rest of the arguments.
                if n == order[-1] and isinstance(v, list) and v and not (len(v) == 1 and isinstance(v[0], (list, tuple))):
                    args += v
                else:
                    args.append(v)
            if kind == "print" and given.get("style") == "print":
                del given["style"]
        if method in ("V", "I"):
            if "acmag" in given:
                mag = _pv(given.pop("acmag"), "value")
                kw["ac"] = (mag, _pv(given.pop("acphase"), "value")) if "acphase" in given else mag
            wave = given.get("wave")
            sugar = "sin" if wave == "sine" else wave
            fields = _WAVES.get(sugar, []) if isinstance(wave, str) else []
            n = 0
            while n < len(fields) and fields[n] in given:
                n += 1
            if n > 0 and not any(f in given for f in fields[n:]):
                kw[sugar] = tuple(_pv(given.pop(f), "value") for f in fields[:n])
                del given["wave"]
            elif wave == "pwl" and isinstance(given.get("pwl"), list):
                pts = _pv(given.pop("pwl"), "value")
                kw["pwl"] = list(zip(pts[0::2], pts[1::2])) if len(pts) % 2 == 0 else pts
                del given["wave"]
        for k, v in given.items():
            kw["uic" if k == "skip_dc" else k] = _pv(v, slots[k]["type"])
        if device and _plain_params(pv, ("self", "name", "kind", *slots, *_ALIASES, *_SOURCE_SUGAR, *kw), flags=False):
            kw.update(pv)
        elif params is not None:
            kw["params"] = pv
        yield method, args, kw
    # Every slot by name: what `add` takes when the short form does not fit.
    if not device:
        yield "add", [kind], everything


def _built(st: dict) -> str | None:
    """The first call of `_calls` that adds exactly this statement (its
    body aside)."""
    want = _norm(st)
    for method, args, kw in _calls(st):
        try:
            scratch = Circuit()
            getattr(scratch, method)(*args, **kw)
            if len(scratch.statements) == 1 and _norm(scratch.statements[0]) == want:
                return _show_call(method, args, kw)
        except Exception:  # not a call the builder takes: try the next form
            continue
    return None


def _as_code(st: dict, dialect: str) -> str | None:
    """The statement as text of its own dialect in a `code` block, if that
    text reads back as the statement."""
    d = st.get("dialect") or dialect
    if not d:
        return None
    try:
        text, _rep = _core.write(_dialect(d), json.dumps({"title": "", "dialect": d, "stmts": [st]}), True)
        got = Circuit().code(text, d)
    except Exception:  # no such dialect, or it cannot say the statement
        return None
    if [_deep(g, ("dialect",)) for g in got] != [_deep(st, ("dialect",))]:
        return None
    return f"code({_show(text)}" + (f", {_show(d)}" if d != "ngspice" else "") + ")"


def _unlined(st: dict) -> dict:
    return {k: [_unlined(b) for b in v] if k == "body" else v for k, v in st.items() if k != "line"}


def _script(stmts: list[dict], var: str, sub: str, dialect: str, depth: int, out: list[str]) -> None:
    pad = "    " * depth
    for st in stmts:
        if st.get("kind") == "comment" and st.get("blank"):
            out.append("")
            continue
        call = _built(st)
        if call is None:
            # Nothing the builder says: a line no rule of its dialect
            # understood, kept as that dialect's text. Failing that too,
            # the statement as it is.
            out.append(f"{pad}{var}.{_as_code(st, dialect) or f'statements.append({_show(_unlined(st))})'}")
            continue
        if st.get("tail"):
            call += f".tail({_show(st['tail'])})"
        if not isinstance(st.get("body"), list):
            out.append(f"{pad}{var}.{call}")
            continue
        inner = f"{sub}{depth + 1 if depth else ''}"
        out.append(f"{pad}with {var}.{call} as {inner}:")
        n = len(out)
        _script(st["body"], inner, sub, dialect, depth + 1, out)
        if not any(line.strip() for line in out[n:]):
            out.append(f"{pad}    pass")


def to_python(source: str, dialect: str, name: str = "c") -> Netlist:
    """A netlist in any dialect as a Python script that builds it with this
    package (`Circuit.python`). `.report` is what reading the netlist said."""
    c = Circuit.read(source, dialect)
    return Netlist(c.python(name), c.read_report)


# ------------------------------------------------------------------- libraries

def _grammar_name(d: str) -> str:
    """The name a resolved dialect calls itself: a built-in's name, or the
    `dialect` line of a grammar file."""
    if not d.endswith(".spgrammar"):
        return d
    try:
        with open(d, encoding="utf-8") as f:
            for line in f:
                words = line.split("#", 1)[0].split()
                if len(words) == 2 and words[0] == "dialect":
                    return words[1]
    except OSError:
        pass  # the core says why when it reads the file
    return d


def _cache_root() -> str:
    return os.path.normpath(os.path.expanduser(os.environ.get("SPRACK_CACHE") or "~/.cache/sprack"))


def _sha1(path: str) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _fresh(files: list[dict]) -> bool:
    """Every file the translation read is unchanged: same size and mtime, or
    failing that, same content."""
    for f in files:
        try:
            st = os.stat(f["path"])
        except OSError:
            return False
        if (st.st_size, st.st_mtime_ns) != (f["size"], f["mtime_ns"]) and _sha1(f["path"]) != f["sha1"]:
            return False
    return True


def _stats(paths: Iterable[str]) -> list[dict]:
    """What `_fresh` compares, for each of `paths` that is a file."""
    out = []
    for path in paths:
        if os.path.isfile(path):
            st = os.stat(path)
            out.append({"path": path, "size": st.st_size, "mtime_ns": st.st_mtime_ns, "sha1": _sha1(path)})
    return out


def _sources(tree: str, root: str) -> list[dict]:
    """The files under `root` that the translated `tree` was made from."""
    return _stats(os.path.join(root, os.path.relpath(os.path.join(at, n), tree)) for at, _dirs, names in os.walk(tree) for n in names)


def _errors(log: str) -> Report:
    return Report(e for e in Report._from_log(log) if e.severity == "error")


_RENAMED = re.compile(r"^'(.+?)' names both a model and a subcircuit: the model is written as '(.+?)'")


def _renames(log: str) -> dict[str, str]:
    """The models a translated library renamed (Spectre: a subcircuit has
    the name too), lower-cased old name to new."""
    out = {}
    for e in Report._from_log(log):
        m = e.code == "rename" and _RENAMED.match(e.message)
        if m:
            out[m.group(1).lower()] = m.group(2)
    return out


def _changed(stmts: list[dict], change) -> list[dict]:
    """`stmts` with `change(st)` in place of each statement it does not
    return as it is; the list itself where it changes none. Nothing given
    is modified: a caller's statements stay its own."""
    out = stmts
    for idx, st in enumerate(stmts):
        new = change(st)
        if new is not st:
            if out is stmts:
                out = list(stmts)
            out[idx] = new
    return out


def _rename_masters(stmts: list[dict], renames: dict[str, str]) -> list[dict]:
    """Devices that use a renamed model by their SPICE letter follow it;
    subcircuit instances keep the subcircuit. Returns the statements, those
    it changed as copies."""
    def change(st: dict) -> dict:
        body = st.get("body")
        if body and (new := _rename_masters(body, renames)) is not body:
            st = {**st, "body": new}
        m = st.get("master")
        if isinstance(m, str) and st.get("kind") != "instance" and m.lower() in renames:
            st = {**st, "master": renames[m.lower()]}
        return st
    return _changed(stmts, change) if renames else stmts


def _rmtree(path: str, tries: int = 3) -> bool:
    """Remove a directory tree, retrying a few times (a file can be busy
    for a moment under load). False if it is still there: the next sweep
    tries again."""
    for i in range(tries):
        shutil.rmtree(path, ignore_errors=True)
        if not os.path.lexists(path):
            return True
        time.sleep(0.05 * (i + 1))
    return False


def _pid_alive(pid: int) -> bool:
    if os.name == "nt":
        # os.kill asks nothing on Windows: 0 is CTRL_C_EVENT there, and any
        # other number ends the process. Open it and see if it has exited.
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.OpenProcess.restype = wintypes.HANDLE
        k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        k32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        k32.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = k32.OpenProcess(0x100000, False, pid)  # SYNCHRONIZE
        if not handle:
            return ctypes.get_last_error() == 5  # access denied: exists, owned by someone else
        try:
            return k32.WaitForSingleObject(handle, 0) == 0x102  # WAIT_TIMEOUT: still running
        finally:
            k32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True  # exists, owned by someone else
    return True


#: A leftover older than this is removed even if its pid is alive again:
#: pids are reused, and a translation takes seconds, not an hour.
_STALE_AGE = 3600.0


def _sweep(base: str, name: str) -> None:
    """Remove what earlier writers of cache entry `name` left behind: the
    copies they replaced (`name.old-<pid>-*`) and their unfinished temporary
    directories (`.name-<pid>-*`). A leftover is removed when the process
    that made it is gone, or when it is older than `_STALE_AGE`.
    """
    # ponytail: pid liveness is checked on this host only; a cache shared
    # over NFS by several hosts relies on the age threshold alone.
    try:
        entries = os.listdir(base)
    except OSError:
        return
    for n in entries:
        if n.startswith(f"{name}.old-"):
            tag = n[len(name) + 5:]
        elif n.startswith(f".{name}-"):
            tag = n[len(name) + 2:]
        else:
            continue
        path = os.path.join(base, n)
        try:
            age = time.time() - os.lstat(path).st_mtime
            pid = int(tag.split("-", 1)[0])
        except (OSError, ValueError):
            continue
        if age > _STALE_AGE or not _pid_alive(pid):
            _rmtree(path)


def _variables(defs: dict[str, str] = {}) -> dict[str, str]:
    """What `$NAME` in an include path stands for: the environment, and
    over it `defs`."""
    return {k: v for k, v in {**os.environ, **defs}.items() if "\n" not in v}


def _build() -> str:
    """What tells one build of the core from another, for what is kept in
    the cache: its schema and the file it is. Another build may read the
    same files another way, or list more of what they declare."""
    st = os.stat(_core.__file__)
    return f"{_core.info()}\0{_core.__file__}:{st.st_mtime_ns}:{st.st_size}"


def _lines(variables: dict[str, str]) -> str:
    return "\n".join(f"{k}={v}" for k, v in variables.items())


def _cached(final: str, marker: str = "sprack.json", variables: dict[str, str] | None = None) -> dict | None:
    """The metadata of a cache entry that is complete and still valid: every
    file read is unchanged, and every `$NAME` an include path named (the
    entry's `vars`) still has the value it had."""
    try:
        with open(os.path.join(final, marker)) as f:
            meta = json.load(f)
        now = _variables() if variables is None else variables
        return meta if all(now.get(k) == v for k, v in meta["vars"].items()) and _fresh(meta["files"]) else None
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def _library_copy(src: str, frm: str, to: str) -> tuple[str, str]:
    """`src` and every file it includes, translated from `frm` to `to` into
    the cache; returns the translated `src` and the translation's log.

    Keyed by the source path, both grammars and the core; valid while
    every file read is unchanged and every `$NAME` in their include paths
    has the value it had. A copy is built in a temporary directory
    and renamed into place, so parallel writers never see half of one; a
    stale copy is renamed aside before it is replaced, and what a writer
    leaves behind is swept by the next one (`_sweep`).
    """
    key = hashlib.sha1(f"{src}\0{_dialect_tag(frm)}\0{_dialect_tag(to)}\0{_build()}".encode()).hexdigest()[:16]
    base = os.path.join(_cache_root(), "libs")
    name = f"{os.path.basename(src)}-{key}"
    final = os.path.join(base, name)
    _sweep(base, name)
    meta = _cached(final)
    if meta is not None:
        return os.path.join(final, "tree", meta["top"]), meta["log"]
    os.makedirs(base, exist_ok=True)
    tmp: str | None = tempfile.mkdtemp(prefix=f".{name}-{os.getpid()}-", dir=base)
    try:
        tree = os.path.join(tmp, "tree")
        text, log = _core.project(frm, to, src, tree, _lines(_variables()), True)
        summary = json.loads(text)
        root = summary["root"]
        meta = {"top": os.path.relpath(src, root), "files": _sources(tree, root), "vars": summary["vars"], "summary": summary, "log": log}
        with open(os.path.join(tmp, "sprack.json"), "w") as f:
            json.dump(meta, f)
        try:
            os.rename(tmp, final)
            tmp = None
        except OSError:
            # The entry exists. Another writer's valid copy is as good as
            # ours; a stale one is renamed aside and replaced.
            if _cached(final) is None:
                old = os.path.join(base, f"{name}.old-{os.getpid()}-{os.urandom(4).hex()}")
                try:
                    os.rename(final, old)
                except OSError:
                    old = None  # gone already: another writer is replacing it
                try:
                    os.rename(tmp, final)
                    tmp = None
                except OSError:
                    pass  # another writer got in between; theirs is as good
                if old is not None:
                    _rmtree(old)
    finally:
        if tmp is not None:
            _rmtree(tmp)
    return os.path.join(final, "tree", meta["top"]), log


def _translate_libraries(stmts: list[dict], default: str, target: str, report: Report, renames: dict[str, str], grammars: dict[str, str]) -> list[dict]:
    """Point every `lib` and `include` written in another dialect than
    `target` at a translated copy of the file tree it reaches (see
    `_library_copy`). Returns the statements, those it changed as copies;
    adds what the libraries could not say to `report` and the models they
    renamed to `renames`. `grammars`: the grammar file of each dialect
    that is not built in, by its name."""
    name = _grammar_name(target)

    def change(st: dict) -> dict:
        frm = st.get("dialect", default)
        body = st.get("body")
        if body and (new := _translate_libraries(body, frm, target, report, renames, grammars)) is not body:
            st = {**st, "body": new}
        if st.get("kind") not in ("lib", "include") or frm == name or not (frm in DIALECTS or frm in grammars):
            return st
        path = st.get("path")
        path = path.get("str") if isinstance(path, dict) else path
        if not isinstance(path, str):
            return st
        src = os.path.abspath(os.path.expandvars(path))
        if not os.path.isfile(src):
            report.append(Entry("error", "invalid", st.get("line", 0), f"{st['kind']}: cannot open {src}"))
            return st
        copy, log = _library_copy(src, grammars.get(frm, frm), target)
        report.extend(_errors(log))
        renames.update(_renames(log))
        return {**st, "path": {"str": copy}, "dialect": name}
    return _changed(stmts, change)


# ------------------------------------------------------------------------ PDKs

_PDK_DIR = os.path.join(os.path.dirname(__file__), "pdks")


def _manifests() -> dict[str, dict]:
    out = {}
    for fn in sorted(os.listdir(_PDK_DIR)):
        if fn.endswith(".json"):
            with open(os.path.join(_PDK_DIR, fn), encoding="utf-8") as f:
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
            at = os.path.dirname(os.path.abspath(manifest))
            with open(manifest, encoding="utf-8") as f:
                manifest = json.load(f)
            # A grammar file it names is beside it, unless it says where.
            if str(manifest.get("dialect", "")).endswith(".spgrammar"):
                manifest["dialect"] = os.path.join(at, manifest["dialect"])
        need = ("name", "dialect", "layouts", "corners")
        missing = [k for k in need if not manifest.get(k)]
        if any("probe" not in layout for layout in manifest.get("layouts") or []):
            missing.append("probe (of a layout)")
        if missing:
            raise SprackError(f"the manifest for PDK {name!r} lacks {', '.join(missing)}; a manifest needs: {', '.join(need)}, and each layout a probe")
        self.manifest: dict = manifest
        self.name: str = manifest["name"]
        self.dialect: str = _dialect(manifest["dialect"])
        self.prefix: str = manifest.get("prefix", "")
        self.cache_dir = os.path.normpath(os.path.expanduser(cache_dir)) if cache_dir else _cache_root()
        self.root, self._vars = self._locate(root)
        self.corners: tuple[str, ...] = tuple(manifest["corners"])
        self.corner = corner or manifest.get("default_corner") or self.corners[0]
        if self.corner not in manifest["corners"]:
            raise SprackError(f"{self.name} has no corner {self.corner!r}; it has: {', '.join(self.corners)}")
        for path, _section in self.entries():
            if not os.path.isfile(path):
                raise SprackError(f"{self.name}: corner {self.corner!r} names {path}, which is not there")
        self._devices: dict[str, dict] | None = None

    @staticmethod
    def known() -> list[str]:
        return sorted({m["name"] for m in _manifests().values()})

    def _locate(self, root: str | None) -> tuple[str, dict]:
        m = self.manifest
        env = m.get("env", ["PDK_ROOT"])
        candidates = [root] if root else [os.environ[v] for v in env if os.environ.get(v)]
        if not candidates:
            raise SprackError(f"{self.name}: give root=, or set ${' or $'.join(env)}")
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

    def _defines(self) -> dict[str, str]:
        return _variables({k: os.path.normpath(self._fmt(val)) for k, val in self.manifest.get("define", {}).items()})

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
        # What of the manifest decides which files are read, and how.
        m = self.manifest
        h.update(json.dumps([_dialect_tag(self.dialect), m["corners"], m.get("define", {}), self._vars], sort_keys=True).encode())
        for path in self._tops():
            st = os.stat(path)
            h.update(f"{path}:{st.st_mtime_ns}:{st.st_size}".encode())
        h.update(_build().encode())
        return h.hexdigest()[:16]

    # -- devices ----------------------------------------------------------
    @property
    def devices(self) -> dict[str, dict]:
        """Every subcircuit and model the PDK's libraries define, by name.

        A subcircuit entry has `ports` and `params` (with defaults); a model
        entry has `device` (mosfet, bjt, diode, ...), `family` and `polarity`.
        """
        if self._devices is None:
            base, cache = os.path.join(self.cache_dir, self.name), f"catalog-{self._stamp()}.json"
            data = _cached(base, cache, self._defines())
            if data is None:
                text, _log = _core.project(self.dialect, "", "\n".join(self._tops()), "", _lines(self._defines()), True)
                data = json.loads(text)
                # Kept while every file read, through includes too, is unchanged.
                data["files"] = _stats(data["files"])
                os.makedirs(base, exist_ok=True)
                with open(os.path.join(base, cache), "w") as f:
                    json.dump(data, f)
            for path, section in self.entries():
                has = [sec["name"] for sec in data["sections"] if os.path.normpath(sec["file"]) == path]
                if section and section.lower() not in map(str.lower, has):
                    raise SprackError(f"{self.name}: corner {self.corner!r} names section {section!r} of {path}, which defines: {', '.join(has) or 'no sections'}")
            self._declared: dict = data["env"]
            devs: dict[str, dict] = {}
            for d in data["devices"]:
                # Binned model cards (nch.1, nch.2, ...) are one device.
                base, dot, tail = d["name"].rpartition(".")
                name = base if dot and tail.isdigit() else d["name"]
                devs.setdefault(name, {**d, "name": name})
            self._devices = devs
        return self._devices

    @property
    def _env(self) -> dict:
        """What the libraries declare, as the core lists it and takes it back
        (the `env` of a netlist's JSON form)."""
        self.devices
        return self._declared

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

        Done once per PDK, dialect and corner and kept in the cache. Only the
        library sections of this corner are followed (where the corner is
        made of sections); `sprack.log` says which were not. Raises
        `Unsupported` if anything in the libraries has no form in the target
        (the full list is in `sprack.log` in that directory); `strict=False`
        accepts the copy as it is.
        """
        d = _dialect(dialect)
        pairs = self.entries()
        sections = [sec for _, sec in pairs if sec] if all(sec for _, sec in pairs) else []
        tag = f"{_dialect_tag(d)}-{self.corner}" if sections else _dialect_tag(d)
        out = out or os.path.join(self.cache_dir, self.name, f"{tag}-{self._stamp()}")
        summary = _cached(out, variables=self._defines())
        if summary is not None:
            with open(os.path.join(out, "sprack.log"), encoding="utf-8") as f:
                log = f.read()
        else:
            os.makedirs(out, exist_ok=True)
            text, log = _core.project(self.dialect, d, "\n".join(self._tops()), out, _lines(self._defines()), True, "\n".join(sections))
            summary = json.loads(text)
            # Kept while every file translated is unchanged.
            summary["files"] = _sources(out, summary["root"])
            with open(os.path.join(out, "sprack.log"), "w", encoding="utf-8") as f:
                f.write(log)
            with open(os.path.join(out, "sprack.json"), "w") as f:
                json.dump(summary, f)
        self._roots = getattr(self, "_roots", {})
        self._roots[d] = (out, summary["root"], Report(e for e in Report._from_log(log) if e.severity == "error"), _renames(log))
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
        self.devices  # reading the catalogue checks that the corner's sections are there
        # Each statement says the file it names is in the target's dialect
        # already (the PDK's own, or the translated copy): a statement that
        # says nothing is taken to be in the circuit's.
        name = _grammar_name(d)
        out: list[dict] = []
        if d == self.dialect:
            mapped = self.entries()
            for item in self.manifest.get("load", []):
                path = os.path.normpath(os.path.join(self.root, self._fmt(item)))
                if os.path.isfile(path):
                    out.append({"kind": "hdl", "path": path, "dialect": name})
        else:
            tree = self.translate(d, strict=strict)
            src_root = self._roots[d][1]
            mapped = [(os.path.join(tree, os.path.relpath(p, src_root)), sec) for p, sec in self.entries()]
        for path, section in mapped:
            out.append({"kind": "lib", "path": path, "section": section, "dialect": name} if section else {"kind": "include", "path": path, "dialect": name})
        return out

    def __repr__(self) -> str:
        return f"PDK({self.name!r}, root={self.root!r}, corner={self.corner!r}, dialect={self.dialect!r})"


def read(source: str, dialect: str) -> Circuit:
    """Shorthand for `Circuit.read`."""
    return Circuit.read(source, dialect)
