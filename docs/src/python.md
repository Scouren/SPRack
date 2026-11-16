# Python

The package is a compiled extension module (`sprack._core`) and a thin Python
layer on top. The Python layer knows no dialect: every method builds
statements of the canonical vocabulary, and the core writes them with the
writers generated from the `.spgrammar` files.

## Building a circuit

```python
import sprack

c = sprack.Circuit("inverter")
c.param(vdd=1.8, wn="1u")
c.model("nch", "bsim4", "n", vth0=0.42)
c.model("pch", "bsim4", "p", vth0=-0.41)
with c.subckt("inv", "in", "out", "vdd", "vss", wp="2u") as s:
    s.M("1", "out", "in", "vss", "vss", "nch", w="wn", l="0.18u")
    s.M("2", "out", "in", "vdd", "vdd", "pch", w="wp", l="0.18u")
c.V("dd", "vdd", 0, "vdd")
c.V("in", "in", 0, pulse=(0, "vdd", "1n", "50p", "50p", "2n", "4n"))
c.X("1", "in", "out", "vdd", 0, "inv", wp="3u")
c.capacitor("Cload", "out", 0, "20f")
c.options(reltol=1e-4, method="gear")
c.save(sprack.v("out"), sprack.i("Vdd"))
c.tran("5p", "12n", uic=True)
print(c.netlist("ngspice"))
```

```text
inverter
.param vdd=1.8 wn=1u
.model nch nmos level=14 vth0=0.42
.model pch pmos level=14 vth0=-0.41
.subckt inv in out vdd vss wp=2u
M1 out in vss vss nch w={wn} l=0.18u
M2 out in vdd vdd pch w={wp} l=0.18u
.ends inv
Vdd vdd 0 dc {vdd}
Vin in 0 pulse(0 {vdd} 1n 50p 50p 2n 4n)
X1 in out vdd 0 inv wp=3u
Cload out 0 20f
.options reltol=0.0001 method=gear
.save v(out) i(Vdd)
.tran 5p 12n uic
.end
```

What the calls are:

* **Devices by letter.** `R`, `C`, `L`, `K`, `V`, `I`, `B`, `E`, `G`, `F`,
  `H`, `D`, `Q`, `M`, `J`, `Z`, `S`, `W`, `T`, `N`, `X`. The letter is put in
  front of the name: `c.R("1", ...)` is `R1`. The arguments are the name, the
  terminals, then the value, or for a device with a model the model's name
  last. Anything else is a keyword: `c.R("1", "a", "b", "1k", tc1="1m")`.
* **Devices by kind.** `c.capacitor("Cload", ...)`, `c.resistor(...)`,
  `c.mosfet(...)`: the same statement, with the name as you give it.
* **Sources.** `c.V(name, pos, neg, dc)` and `c.I(...)`, with `ac=1` or
  `ac=(mag, phase)` and one waveform: `pulse=(v0, v1, delay, rise, fall,
  width, period)`, `sin=(offset, ampl, freq, delay, damp, phase)`,
  `exp=(...)`, `sffm=(...)`, `am=(...)`, `pwl=[(t, v), ...]`.
* **Analyses.** `op`, `dc`, `ac`, `tran`, `noise`, `tf`, `pz`, `sens`,
  `four`, `hb`, `sp`, `pss`, `stb` and the rest of the vocabulary, each a
  method. `uic=True` on `tran` is the alias of its `skip_dc` slot.
* **Everything else.** `param`, `model`, `subckt`, `options`, `temp`, `save`,
  `ic`, `nodeset`, `measure`, `func`, `include`, `lib`, `hdl`, `comment`.
  `print_` and `global_` end in an underscore because Python keeps the words.
  `sprack.v("out")` and `sprack.i("Vdd")` name signals to save or print.
* **Any kind.** Every statement kind in `sprack.KINDS` is a method of its own
  name, and `c.add(kind, ...)` is the one way in they all end up at.

`c.model(name, family, polarity, **params)` takes a canonical family
(`"bsim4"`, `"diode"`, `"bjt"`, ...) and a polarity (`"n"`, `"p"`, `"npn"`,
`"pnp"`); each dialect writes its own type and level for it. For a Verilog-A
module give `type=` instead.

## Values

```python
v = sprack.Circuit("values")
v.R("1", "a", 0, 1000)                  # a Python number
v.R("2", "a", 0, "4.7k")                # a number with an SI suffix
v.R("3", "a", 0, "2*rv")                # anything else: an expression
v.R("4", "a", 0, sprack.expr("13"))     # an expression that looks like a number
v.param(rv="1k", label=sprack.quoted("some text"))
v.model("n1", "bsim3", "n", flavour=sprack.word("a.b"))
print(v.netlist("ngspice", strict=False))
```

```text
values
R1 a 0 1000
R2 a 0 4.7k
R3 a 0 {2*rv}
R4 a 0 {13}
.param rv=1k label="some text"
.model n1 nmos level=8 flavour=a.b
.end
```

The suffixes are `T`, `G`, `meg`, `k`, `m`, `u`, `n`, `p`, `f` and `a`, and
case matters: `"1g"` is refused as not a number. Expressions are written in
the canonical spelling (`ln(a)**2`) and each dialect gets its own.
`sprack.word` is a word written exactly as it is, `sprack.quoted` a quoted
string, `sprack.expr` an expression where a plain string would be read as
something else.

`"1M"` is refused, because M is milli in SPICE and mega elsewhere:

```python
m = sprack.Circuit("ambiguous")
m.R("1", "a", 0, "1M")
try:
    m.netlist("ngspice")
except sprack.Unsupported as e:
    print(e)
```

```text
1 thing cannot be written for ngspice:
  - line 1: '1M' is ambiguous: M is milli in SPICE and mega in SI. Write 1m or 1meg
```

## The vocabulary is closed

A keyword a statement does not have is a `TypeError` that lists the ones it
has. There is no way to pass raw text through a method; text in a dialect
goes in a [`code` block](#existing-netlists).

```python
try:
    c.tran("1n", "1u", errpreset="moderate")
except TypeError as e:
    print(e)
```

```text
tran has no 'errpreset'; it has: name, step, stop, start, maxstep, skip_dc, method, ic, nodeset, segments
```

## Statements that hold others

A subcircuit, a library section, a conditional, a sweep, a Monte Carlo run
and an alter hold other statements. Each is filled in a `with` block, whose
variable takes the same methods as the circuit:

```python
w = sprack.Circuit("sweep")
w.param(rv="1k")
w.V("1", "a", 0, 1)
w.R("1", "a", 0, "rv")
with w.step("rv", "1k", "3k", "1k") as s:
    s.op()
print(w.netlist("spectre"))
print(w.netlist("hspice"))
```

```text
// sweep
simulator lang=spectre
global 0
parameters rv=1k
V1 (a 0) vsource dc=1
R1 (a 0) resistor r=rv
swp1 sweep param=rv start=1k stop=3k step=1k {
op1 dc
}

sweep
.param rv=1k
V1 a 0 dc 1
R1 a 0 'rv'
.op sweep rv 1k 3k 1k
.end
```

## Writing, and the report

`c.netlist(dialect)` returns the netlist as a `str` with a `.report`
attribute. `c.write(path, dialect)` also writes it to a file.

```python
out = c.netlist("spectre")
print(out.report)
```

```text
warning[caveat]: line 11: tran.skip_dc: skipdc=yes skips the DC solve and takes initial conditions from ic statements; SPICE UIC also honours ic= on devices
warning[caveat]: line 11: tran.method: the integration methods are near equivalents, not the same algorithm
warning[caveat]: line 2: model 'nch' (bsim4) and 1 more model cards: sprack and spectre ship different implementations and versions of these models; parameters were copied as written, check them against spectre
```

A report is a list of entries with `severity` (`error`, `warning`, `info`),
`code`, `line`, `message` and `file`; `.errors` and `.warnings` filter it.
For a circuit built in Python, `line` is the number of the statement. The
codes are explained under [Reading the report](simulators.md#reading-the-report).

When the dialect cannot say something, `netlist` raises `sprack.Unsupported`:

```python
try:
    c.netlist("xyce")
except sprack.Unsupported as e:
    print(e)
```

```text
1 thing cannot be written for xyce:
  - line 10: statement 'save' cannot be written for xyce: Xyce records only what .PRINT lists, and .PRINT needs an analysis type that a bare save does not give. Dialects that define it: espice, hspice, ltspice, ngspice, spectre, vacask
```

The exception has `.report` (every entry), `.text` (the netlist as far as it
could be written, the lines that could not as comments) and `.dialect`.
`strict=False` returns the netlist anyway, with the errors in its report, and
`c.check(dialect)` returns only the report:

```python
lax = c.netlist("xyce", strict=False)
for e in lax.report.errors:
    print(e.severity, e.code, e.line)
print(len(c.check("vacask").errors), "errors for vacask")
```

```text
error unsupported 10
0 errors for vacask
```

To ask before writing:

```python
print(sprack.can_write("pz", "xyce"))
print(sprack.why_not("pz", "xyce"))
```

```text
False
Xyce has no pole-zero analysis. Dialects that define it: espice, hspice, ngspice, spectre
```

## Existing netlists

`sprack.translate` is the command's `translate`:

```python
out = sprack.translate("t\nR1 a 0 1M\n.tran 1n 1u\n.end\n", frm="ngspice", to="spectre")
print(out)
```

```text
// t
simulator lang=spectre insensitive=yes
global 0
R1 (a 0) resistor r=1m
tran1 tran step=1n stop=1u
```

`sprack.read(text, dialect)` gives a `Circuit` that can be added to and
written for any dialect. `.read_report` is what reading it said.

```python
r = sprack.read("t\nR1 a 0 1k\n.tran 1n 1u\n.end\n", "ngspice")
r.C("1", "a", 0, "1p")
print(r.netlist("hspice"))
```

```text
t
.option tnom=27
R1 a 0 1k
.tran 1n 1u
C1 a 0 1p
.end
```

`c.code(text, dialect="ngspice")`, on a circuit or inside a `with` block,
reads `text` with that dialect's reader (with no title line) and adds the
statements. They are statements like any other and are written for whatever
dialect the netlist is for:

```python
k = sprack.Circuit("code blocks")
k.R("1", "in", "out", "1k")
k.C("1", "out", 0, "1p")
k.V("in", "in", 0, 1)
k.code(".tran 1n 1u\n.ac dec 10 1 1G\n.save v(out)\n")
with k.subckt("buf", "a", "b") as s:
    s.code("rb (a b) resistor r=10\n", "spectre")
print(k.netlist("spectre"))
```

```text
// code blocks
simulator lang=spectre
global 0
R1 (in out) resistor r=1k
C1 (out 0) capacitor c=1p
Vin (in 0) vsource dc=1
tran1 tran step=1n stop=1u
ac1 ac start=1 stop=1G dec=10
save out
subckt buf (a b)
rb (a b) resistor r=10
ends buf
```

Each statement of a code block remembers its dialect. For a target of that
dialect, the block's own options and the lines no rule understands are
written as they are. For any other target they are errors:

```python
k.code(".options plotwinsize=0\n", "ltspice")
# Not strict: the two analyses above are errors for LTspice, which loads one a deck.
print(".options plotwinsize=0" in k.netlist("ltspice", strict=False))
try:
    k.netlist("ngspice")
except sprack.Unsupported as e:
    print(e)
```

```text
True
1 thing cannot be written for ngspice:
  - line 1: options: 'plotwinsize=0' has no spelling in ngspice
```

A `.lib` or `.include` line in a code block names a library in that dialect;
see [PDKs](pdks.md#without-a-manifest) for what happens to it.

## A netlist as a builder script

`sprack.to_python(text, dialect)` turns a netlist into a flat Python script
that builds it again: one call per statement, a `with` block for a statement
that holds others. `Circuit.python()` does the same for a circuit you
already have. With [`inv.sp`](examples/inv.sp):

```python
src = open("inv.sp").read()
script = sprack.to_python(src, "ngspice")
print(script)
```

```python
import sprack

c = sprack.Circuit("inverter", dialect="ngspice")
c.param(vdd=1.8, wn="1u")
c.model("nch", "bsim4", "n", vth0=0.42)
c.model("pch", "bsim4", "p", vth0=-0.41)
with c.subckt("inv", "in", "out", "vdd", "vss", wp="2u") as s:
    s.M("1", "out", "in", "vss", "vss", "nch", w="wn", l="0.18u")
    s.M("2", "out", "in", "vdd", "vdd", "pch", w="wp", l="0.18u")
c.V("1", "vdd", 0, "vdd")
c.X("1", "in", "out", "vdd", 0, "inv", wp="3u")
c.C("1", "out", 0, "20f")
c.R("1", "out", 0, "sqrt(wn)*1e9")
c.tran("5p", "12n", uic=True)
```

`script.report` is what reading the netlist said. From the shell:

```console
$ python -m sprack --from ngspice inv.sp > inv.py
```

The one thing the builder has no call for is a line no rule of the dialect
understood. It becomes a `code` block of that dialect's text:

```python
print(sprack.to_python("t\nR1 a 0 1k\n.bogus 1 2\n.end\n", "ngspice"))
```

```python
import sprack

c = sprack.Circuit("t", dialect="ngspice")
c.R("1", "a", 0, "1k")
c.code(".bogus 1 2\n")
```

`Circuit(title, dialect="ngspice")` says whose terms the statements are in,
as for a netlist read from that dialect: what the dialect assumes where a
statement says nothing (HSPICE's TNOM of 25) holds, and its own options are
written back to it as they are.

## A dialect by its grammar file

Every `dialect` argument (`netlist`, `write`, `check`, `translate`, `read`,
`code`, `to_python`) may be a path to a `.spgrammar` file instead of a
built-in name. With the [`mini.spgrammar`](examples/mini.spgrammar) of
[Adding a simulator](adding-a-simulator.md):

```python
g = sprack.Circuit("t")
g.R("1", "a", 0, "1k")
g.op()
print(g.netlist("mini.spgrammar"))
```

```text
t
R1 a 0 1k
.dcop
.end
```

A mistake in the file raises `ValueError` with `path:line: message`.

`sprack.DIALECTS` is the tuple of built-in names, `sprack.KINDS` the
vocabulary (per kind: its class, its slots, the dialects that can write it).
