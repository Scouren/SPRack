# SPRack

SPRack reads a netlist in one SPICE dialect and writes it in another, and lets
a Python program describe a circuit once and get it in any of them. It
translates; it does not simulate.

Eight dialects are built in: ngspice, HSPICE, Xyce, Spectre, VACASK, ESPice,
LTspice and CDL. Each is described by one `grammars/<name>.spgrammar` file.
The readers and writers are generated from those files, so there is no
hand-written parser per dialect and no converter per pair of dialects: every
reader produces the same canonical statements and every writer consumes them.
A simulator SPRack does not know is [one more grammar file](adding-a-simulator.md),
and a PDK it does not know needs [at most a small manifest](adding-a-pdk.md).

## What it guarantees

**Nothing is dropped without a report entry.** If something in the input has
no form in the target, the report carries an error for it and the exit status
is 1. There is no option to turn that off. The output is still written, with
the line that could not be translated left in it as a comment.

**Errors say why, and who can.**

```text
error[unsupported]: line 2: analysis 'pz' cannot be written for xyce: Xyce has no pole-zero analysis. Dialects that define it: espice, hspice, ngspice, spectre
```

**Numbers are exact.** `1.5p` is stored as the digits `1.5` and the exponent
-12, never as a float. `1M` read as ngspice is milli and is written to Spectre
as `1m`.

**Source spelling is kept.** Names keep the capitals the author gave them.
Where the source ignores case, a name written two ways gets one spelling
among the names of its kind (nodes, devices, models and subcircuits,
parameters): the node `vdd` of a source `Vdd` stays `vdd`.
Comments, blank lines and trailing comments are carried over.

**A translation can be checked against itself.** `sprack audit` translates,
reads its own output back with the target's reader and compares. A difference
that the report does not explain is a bug.

## Build and install

SPRack is built with Zig (the version is pinned in `flake.lock`; `nix develop`
gives a shell with it).

```sh
zig build            # the command: zig-out/bin/sprack
zig build py         # the Python extension: python/sprack/_core.abi3.so (_core.pyd on Windows)
zig build test       # the tests
pip wheel .          # a wheel of the Python package (Zig on PATH)
```

After `zig build py` the Python package runs from the checkout with
`PYTHONPATH=python`. The package is one compiled extension module (CPython
3.10 or later) and a thin Python layer; it has no other dependency. The
wheel is built and tested on Linux, macOS and Windows.

## One minute with the command

[`rc.sp`](examples/rc.sp) is an ngspice netlist:

```spice
RC low-pass
* a divider with a capacitor
V1 in 0 DC 1 AC 1
R1 in out 1k
C1 out 0 100n $ load
.tran 1u 1m
.end
```

```console
$ sprack translate --from ngspice --to spectre rc.sp
// RC low-pass
simulator lang=spectre insensitive=yes
global 0
// a divider with a capacitor
V1 (in 0) vsource dc=1 mag=1
R1 (in out) resistor r=1k
C1 (out 0) capacitor c=100n // load
tran1 tran step=1u stop=1m
```

The result goes to standard output (or `-o file`), the report to standard
error. VACASK needs a value ngspice leaves out, so one is written and the
report says so:

```console
$ sprack translate --from ngspice --to vacask rc.sp
RC low-pass
ground 0
load "spice/resistor.osdi"
model resistor sp_resistor
load "spice/capacitor.osdi"
model capacitor sp_capacitor
model vsource vsource
// a divider with a capacitor
V1 (in 0) vsource dc=1 mag=1
R1 (in out) resistor r=1k
C1 (out 0) capacitor c=100n // load
control
analysis tran1 tran step=1u stop=1m maxstep=1u
endc
warning[synthesized]: line 6: tran: vacask needs 'maxstep' to behave as ngspice does without it; wrote 1u
```

The [command line](cli.md) page has every subcommand.

## One minute with Python

```python
import sprack

c = sprack.Circuit("RC low-pass")
c.V("1", "in", 0, 1, ac=1)
c.R("1", "in", "out", "1k")
c.C("1", "out", 0, "100n")
c.tran("1u", "1m")
print(c.netlist("ngspice"))
print(c.netlist("spectre"))
```

```text
RC low-pass
V1 in 0 dc 1 ac 1
R1 in out 1k
C1 out 0 100n
.tran 1u 1m
.end

// RC low-pass
simulator lang=spectre
global 0
V1 (in 0) vsource dc=1 mag=1
R1 (in out) resistor r=1k
C1 (out 0) capacitor c=100n
tran1 tran step=1u stop=1m
```

`netlist()` raises `sprack.Unsupported` when the dialect cannot say something
in the circuit. The [Python](python.md) page covers the builder, and
[PDKs](pdks.md) covers model libraries.
