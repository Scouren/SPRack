# Using SPRack with any PDK

To SPRack a PDK's model library is a tree of netlist files in one dialect:
a top file, the files it includes, and often library sections, one per
corner. Using the PDK with a simulator of another dialect means translating
that whole tree and pointing the netlist at the copy. There are two ways to
have that done. Neither needs anything built in for the PDK.

| | you give | you get |
|---|---|---|
| [Without a manifest](#without-a-manifest) | the library's path, in the circuit or on the command line | the library translated for the target and referenced |
| [With a manifest](#with-a-manifest-sprackpdk) | a small description of where the PDK's files are | the same, and every device of the PDK as a checked method of the circuit |

The examples use a made-up PDK of one file,
[`mine/models.lib`](examples/mine/models.lib), written in ngspice's dialect,
and the SKY130 library. In the output, `…` stands for the directory the
examples were run in; the cache was put in `…/cache` with `SPRACK_CACHE`.

```spice
* mine: a made-up PDK in one file (ngspice dialect)
.lib tt
.param vth_n=0.42 vth_p=-0.41
.lib "models.lib" devices
.endl tt

.lib ff
.param vth_n=0.38 vth_p=-0.37
.lib "models.lib" devices
.endl ff

.lib devices
.model nch nmos level=1 vto={vth_n} kp=200u
.model pch pmos level=1 vto={vth_p} kp=80u
.subckt mine_nfet d g s b w=1u l=0.18u
M1 d g s b nch w={w} l={l}
.ends mine_nfet
.subckt mine_pfet d g s b w=2u l=0.18u
M1 d g s b pch w={w} l={l}
.ends mine_pfet
.endl devices
```

## Without a manifest

A netlist translated on its own, apart from its library, cannot know what
the library's subcircuits hold. Where the target has no conditional
blocks (Xyce, CDL), a subcircuit that holds one is written once for each
branch, and an instance names the one its parameters select; an instance
of a library translated separately keeps the subcircuit's own name, which
is the branch of the defaults. Such an instance with parameters is an
`ambiguous` warning: translate the netlist and the library together, with
`sprack project` or through `sprack.PDK`.

### In Python

Name the library in the circuit, in the dialect it is written in. The
simplest way is a `code` block holding the line the PDK's own documentation
gives:

```python
import sprack

c = sprack.Circuit("inverter")
c.code('.lib "mine/models.lib" tt', "ngspice")
c.V("dd", "vdd", 0, 1.8)
c.V("in", "in", 0, pulse=(0, 1.8, "1n", "50p", "50p", "2n", "4n"))
c.X("p", "out", "in", "vdd", "vdd", "mine_pfet", w="2u", l="0.18u")
c.X("n", "out", "in", 0, 0, "mine_nfet", w="1u", l="0.18u")
c.tran("10p", "8n")
print(c.netlist("ngspice"))
```

```text
inverter
.lib "mine/models.lib" tt
Vdd vdd 0 dc 1.8
Vin in 0 pulse(0 1.8 1n 50p 50p 2n 4n)
Xp out in vdd vdd mine_pfet w=2u l=0.18u
Xn out in 0 0 mine_nfet w=1u l=0.18u
.tran 10p 8n
.end
```

For the library's own dialect the line is written as it was. For any other
dialect, SPRack translates the file and everything it includes into its
cache and points the netlist at the copy:

```python
print(c.netlist("spectre"))
```

```text
// inverter
simulator lang=spectre
global 0
include "…/cache/libs/models.lib-d95e44e44ad9eac4/tree/models.lib" section=tt
Vdd (vdd 0) vsource dc=1.8
Vin (in 0) vsource type=pulse val0=0 val1=1.8 delay=1n rise=50p fall=50p width=2n period=4n
Xp (out in vdd vdd) mine_pfet w=2u l=0.18u
Xn (out in 0 0) mine_nfet w=1u l=0.18u
tran1 tran step=10p stop=8n
```

The copy is made as `sprack project --lib` makes one, and is reused while
every file it was made from is unchanged. `$VAR` in the path is expanded
from the environment, and so is one in an include path inside the library;
the copy is made again when such a variable has another value. A library
that is not there is an `invalid` error.
What the library cannot say in the target is in the netlist's report, with
file and line.

The methods `c.lib(path, section)` and `c.include(path)` do the same when the
circuit says which dialect its statements are in:

```python
d = sprack.Circuit("one device", dialect="ngspice")
d.lib("mine/models.lib", "tt")
d.X("n", "out", "in", 0, 0, "mine_nfet")
print(d.netlist("xyce"))
```

```text
one device
.lib "…/cache/libs/models.lib-947f848db23dcda4/tree/models.lib" tt
Xn out in 0 0 mine_nfet
.end
```

On a circuit made without `dialect=`, a path added by `c.lib` or
`c.include` is in no dialect. It is written as it stands for every target,
and the report has a caveat saying the file was not translated:

```python
e = sprack.Circuit("one device")
e.lib("mine/models.lib", "tt")
e.X("n", "out", "in", 0, 0, "mine_nfet")
out = e.netlist("xyce")
print(out)
print(out.report)
```

```text
one device
.lib "mine/models.lib" tt
Xn out in 0 0 mine_nfet
.end

warning[caveat]: line 1: "mine/models.lib" is still sprack syntax; translate that file too (`sprack project` follows includes)
```

The library's dialect may be one given by its
[grammar file](python.md#a-dialect-by-its-grammar-file) too. A library named
in a `code` block of such a dialect, or in a netlist read in it, is
translated by that grammar, and again when the grammar file changes.

This way the devices are ordinary instances (`c.X(...)` of a subcircuit,
`c.M(...)` with a model card's name). Nothing checks their terminals or
parameters against the library.

### On the command line

`sprack project` translates the tree into a directory you choose:

```console
$ sprack project --from ngspice --to spectre --lib --section tt --out mine-spectre mine/models.lib
mine/models.lib: info[cosmetic]: section 'ff' not followed: it is not among the sections asked for, so the files it includes are not translated
mine/models.lib:13: warning[caveat]: model 'nch' (mos1) and 1 more model cards: ngspice and spectre ship different implementations and versions of these models; parameters were copied as written, check them against spectre
1 file, 0 errors, 1 warning
```

`--lib` says the file is a library with no title line. `--section tt` follows
only that corner, which matters for a large PDK. `mine-spectre/models.lib`
is now the library in Spectre's language; include it from your netlist.

The same on a real library, SKY130 to Xyce:

```console
$ sprack project --from ngspice --to xyce --lib --section tt --out sky130-xyce pdks/sky130_fd_pr/models/sky130.lib.spice
...
170 files, 313 errors, 121 warnings
```

Status 1: one line and 312 model card parameters of the library have
no form in Xyce. Each error names its file and line, and says what is wrong:

```text
pdks/sky130_fd_pr/cells/special_pfet_latch/sky130_fd_pr__special_pfet_latch.pm3.spice:350: error[untranslated]: no ngspice rule understood this line; it is in the output only as a comment: xsky130_fd_pr__special_pfet_pass d g s b  l = {l} w = {w} ad = {ad} as = {as} pd = {pd} ps = {ps}  nrd = {nrd} nrs = {nrs} mult = {mult} sa = {sa} sb = {sb} sd = {sd}  sky130_fd_pr__special_pfet_latch
```

It is a line of the library that ngspice itself refuses (issue 25): the
`special_pfet_pass` alias names its subcircuit after its parameters. The
sky130A manifest's errata say what to read instead; `--errata` takes them (the
manifests are in the Python package's `pdks` directory):

```console
$ sprack project --from ngspice --to xyce --lib --section tt --errata "$(python -c 'import os, sprack; print(os.path.dirname(sprack.__file__))')/pdks/sky130A.json" --out sky130-xyce pdks/sky130_fd_pr/models/sky130.lib.spice
pdks/sky130_fd_pr/cells/special_pfet_latch/sky130_fd_pr__special_pfet_latch.pm3.spice:350: warning[caveat]: read through an erratum of the PDK: 'xsky130_fd_pr__special_pfet_pass d g s b': the subcircuit's name comes after its parameters, and ngspice refuses the instance (unknown subckt); read as 'xsky130_fd_pr__special_pfet_pass d g s b sky130_fd_pr__special_pfet_latch'
...
```

`sprack.PDK` reads them from its manifest by itself. Thirteen of the
errors are the resistor models that narrow the width by `dw`, one entry each:

```text
pdks/sky130_fd_pr/models/sky130_fd_pr__model__r+c.model.spice:130: error[loss]: model 'sky130_fd_pr__res_generic_nd': dw="-tol_nfom/2-nfom_dw/2" not written: xyce has the one parameter 'narrow' for narrow and short, and they are not equal here (one left out is 0): xyce computes R = RSH (L - NARROW) / (W - NARROW), with no SHORT (a warning, and it is ignored); ngspice computes R = RSH (L - 2 SHORT) / (W - 2 NARROW)
```

Eighteen are diode cards of ngspice's level 3, which Xyce's diode
does not have:

```text
pdks/sky130_fd_pr/models/parasitics/sky130_fd_pr__model__parasitic__diode_ps2nw.model.spice:16: error[loss]: model 'sky130_fd_pr__model__parasitic__diode_ps2nw': level not written: Xyce 7.10's diode has levels 1, 2, 200 and 2002 and refuses a device of a level 3 card; ngspice's level 3 has no counterpart there (level 2 on a sky130 card is 38.5 % off and ignores 27 of its parameters)
```

And twenty are resistor cards with a parameter Xyce's resistor card does not
take: the card's own value, which Xyce gives no device, and names it has no
parameter for:

```text
pdks/sky130_fd_pr/models/sky130_fd_pr__model__r+c.model.spice:143: error[loss]: model 'mrcn': r not written: Xyce lists R among its resistor card's parameters, but not what a device without a value of its own takes from it; give the value on the instance
pdks/sky130_fd_pr/cells/res_high_po/sky130_fd_pr__res_high_po.model.spice:45: error[loss]: model 'rhead_model': sw_et=0 not written: the resistor card of xyce takes no such parameter; it takes narrow, defw, r, rsh, tc1, tc2, tce, tnom
```

The other 261 are parameters of the five npn and pnp cards (temperature
coefficients such as `tnf1` and `tikf1`, `dcap`, `subs`, `gap1`) that
Xyce's BJT does not have:

```text
pdks/sky130_fd_pr/cells/pnp_05v5/sky130_fd_pr__pnp_05v5_W0p68L0p68.model.spice:32: error[loss]: model 'sky130_fd_pr__pnp_05v5_W0p68L0p68__model': tikf1=-0.0037823 not written: the bjt card of xyce takes no such parameter; it takes tnom, is, nf, nr, nc, rb, rbm, re, rc, cje, tf, xtf, vtf, ptf, cjc, tr, eg, kf, af, fc, c2, c4, bf, va, ikf, ise, ne, br, var, ikr, isc, irb, vje, mje, itf, vjc, mjc, xcjc, cjs, vjs, mjs, xtb, xti, nk
```

Names Xyce's model lacks at the value that is ngspice's default (the BSIM3 cards' `rd=0` and `ldif=0`)
are warnings: they change nothing.

The rest of the tree is translated (a parameter named `vt`, which Xyce
refuses, is written as `vt__p` with a note), and whether these matter
depends on the devices you use.

## With a manifest: sprack.PDK

`sprack.PDK(name, root=None, corner=None, *, manifest=None, cache_dir=None)`
finds a PDK's model libraries from a manifest, lists the devices they
define, and makes each one a method of a circuit built with it.

```python
pdk = sprack.PDK("sky130A", root="pdks/sky130_fd_pr")
print(pdk)
print(pdk.corners)
print(len(pdk.devices), "devices")
print(pdk.device("nfet_01v8")["ports"])
```

```text
PDK('sky130A', root='…/pdks/sky130_fd_pr', corner='tt', dialect='ngspice')
('tt', 'ff', 'ss', 'sf', 'fs', 'll', 'hh', 'hl', 'lh')
258 devices
['d', 'g', 's', 'b']
```

The first use of `pdk.devices` reads the whole library, which takes a while
for a PDK of this size; the list is kept in the cache.

```python
c = sprack.Circuit("inverter", pdk=pdk)
c.V("dd", "vdd", 0, 1.8)
c.V("in", "in", 0, pulse=(0, 1.8, "1n", "50p", "50p", "2n", "4n"))
c.pfet_01v8("Mp", "out", "in", "vdd", "vdd", w=1, l=0.15)
c.nfet_01v8("Mn", "out", "in", 0, 0, w=0.5, l=0.15)
c.tran("10p", "8n")
print(c.netlist("ngspice"))
```

```text
inverter
.lib "…/pdks/sky130_fd_pr/models/sky130.lib.spice" tt
Vdd vdd 0 dc 1.8
Vin in 0 pulse(0 1.8 1n 50p 50p 2n 4n)
XMp out in vdd vdd sky130_fd_pr__pfet_01v8 w=1 l=0.15
XMn out in 0 0 sky130_fd_pr__nfet_01v8 w=0.5 l=0.15
.tran 10p 8n
.end
```

The netlist starts with the statements that bring in the PDK's corner. For
the dialect the PDK ships in, they reference the PDK's own files.

### Devices

`pdk.devices` is a dict of every subcircuit and model card the libraries
define. A subcircuit entry has `ports` and `params` (with defaults); a model
card has `device`, `family` and `polarity`. `pdk.device(name)` finds one with
or without the PDK's prefix (`sky130_fd_pr__`), in any case.

The catalogue is what the corner's library reaches, not every directory of
the checkout. In sky130_fd_pr, `sky130.lib.spice` section `tt` reaches files
in 76 of the 129 `cells/` directories; the other 53 (most `cap_vpp`
capacitors, the inductors, the RF test coils and aura cells, the RF and ESD
20 V transistors, the RF bipolars) are in no file the corner includes, so they are not
devices of `sky130A`. A cell outside the corner is still usable by including
its file in the circuit.

What the libraries define is known where the circuit is written and where a
`code` block is read. A model card or a function of the PDK is a declared
one, so a resistor that names a PDK model is not reported as naming a model
that is nowhere; and in a `code` block of another dialect, a device that
names a PDK model is the device that model describes.

On a circuit built with `pdk=`, each device is a method: the instance name,
the terminals, then parameters by keyword. The number of terminals and the
parameter names are checked against the library before anything is written:

```python
for call in (lambda: c.nfet_01v8("M3", "a", "b", 0),
             lambda: c.nfet_01v8("M3", "a", "b", 0, 0, fingers=2),
             lambda: c.nfet_01v9):
    try:
        call()
    except (TypeError, AttributeError) as err:
        print(err)
```

```text
sky130_fd_pr__nfet_01v8 has 4 terminals (d, g, s, b), got 3
sky130_fd_pr__nfet_01v8 has no parameter 'fingers'; it has: l, w, nf, ad, as, pd, ps, nrd, nrs, sa, sb, sd, mult
'nfet_01v9' is neither a statement kind nor a device of sky130A. Did you mean: nfet_01v8, pfet_01v8, nfet_20v0, nfet_01v8_lvt, esd_nfet_01v8?
```

The instance name is written as given. Where the target tells devices apart
by their first letter, the writer adds the letter and says so (`Mp` became
`XMp` above, an `info[rename]` in the report).

### Another dialect, and strict=False

For a dialect other than the PDK's own, the whole library of the corner is
translated once into the cache, and the netlist references the copy. If the
library has something the target cannot say, that is an error like any
other, and `netlist()` raises:

```python
try:
    c.netlist("xyce")
except sprack.Unsupported as err:
    print(len(err.report.errors), "errors")
    print(err.report.errors[0])
```

```text
312 errors
error[loss]: pdks/sky130_fd_pr/models/sky130_fd_pr__model__r+c.model.spice:line 130: model 'sky130_fd_pr__res_generic_nd': dw="-tol_nfom/2-nfom_dw/2" not written: xyce has the one parameter 'narrow' for narrow and short, and they are not equal here (one left out is 0): xyce computes R = RSH (L - NARROW) / (W - NARROW), with no SHORT (a warning, and it is ignored); ngspice computes R = RSH (L - 2 SHORT) / (W - 2 NARROW)
```

`strict=False` accepts the copy as it is and puts those errors in the
netlist's report. Use it when the lines in question are not in the devices
you instantiate:

```python
out = c.netlist("xyce", strict=False)
print(out)
print(len(out.report.errors), "errors in the report")
```

```text
inverter
.lib "…/cache/sky130A/xyce-tt-a44f9078963de0de/models/sky130.lib.spice" tt
Vdd vdd 0 dc 1.8
Vin in 0 pulse(0 1.8 1n 50p 50p 2n 4n)
XMp out in vdd vdd sky130_fd_pr__pfet_01v8 params: w=1 l=0.15
XMn out in 0 0 sky130_fd_pr__nfet_01v8 params: w=0.5 l=0.15
.tran 10p 8n
.end

312 errors in the report
```

A circuit on a PDK means the temperature of the PDK's own simulator: HSPICE
assumes 25 degrees (TEMP and TNOM), ngspice, Xyce, Spectre, VACASK and
LTspice 27. A circuit that sets none, written for a target that assumes
another, is an error, since the result then depends on the simulator that
runs it (ASAP7's `nmos_rvt` in Xyce: 113.55 uA at 25, 113.40 uA at 27).
Say it with `c.options(temp=25, tnom=25)`. A netlist translated from a
dialect gets that dialect's defaults written out instead, with a warning.

`pdk.translate(dialect, strict=False)` does the translation alone and
returns the directory; the full log is `sprack.log` in it.
`pdk.library_errors(dialect)` returns the errors as a report.


### The built-in manifests

```python
print(sprack.PDK.known())
```

```text
['ASAP7', 'FreePDK45', 'gf180mcuD', 'ihp-sg13g2', 'sky130A']
```

| name | also found as | written in | corners | root from |
|---|---|---|---|---|
| `sky130A` | `sky130`, `skywater130` | ngspice | `tt` `ff` `ss` `sf` `fs` `ll` `hh` `hl` `lh` | `$PDK_ROOT` |
| `ihp-sg13g2` | `ihp`, `sg13g2`, `ihp_sg13g2`, `ihp-open-pdk` | ngspice | `tt` `ss` `ff` `sf` `fs` | `$PDK_ROOT` |
| `gf180mcuD` | `gf180mcu`, `gf180` | ngspice | `tt` `ss` `ff` `sf` `fs` | `$PDK_ROOT` |
| `ASAP7` | `asap7`, `asap7pdk` | HSPICE | `tt` `ff` `ss` | `$ASAP7_ROOT`, `$PDK_ROOT` |
| `FreePDK45` | `freepdk45`, `freepdk-45`, `ncsu45` | HSPICE | `nom` `tt` `ff` `ss` | `$PDK_DIR`, `$FREEPDK45_ROOT`, `$PDK_ROOT` |

Names are matched without regard to case. `root=` is the directory the PDK
is in; without it the environment variables of the last column are tried in
order. Each manifest knows more than one layout of its PDK (the installed
form and the source repository), so `root` may be either. `corner=` picks a
corner; without it the manifest's default is used (`tt`, or `nom` for
FreePDK45).

A PDK that is not in this list needs a manifest of its own:
[Adding a PDK](adding-a-pdk.md).

## The cache

Translated libraries and device lists are kept in `~/.cache/sprack`. The
environment variable `SPRACK_CACHE` moves it, and `cache_dir=` moves it for
one `sprack.PDK`. It is the only thing SPRack writes outside the directories
you name.

| in the cache | what |
|---|---|
| `libs/<file>-<key>/tree/` | a library named in a circuit, translated on the fly; reused while every file it was made from is unchanged (size and time, then content) |
| `<pdk>/catalog-<stamp>.json` | the device list of a `sprack.PDK` |
| `<pdk>/<dialect>-<corner>-<stamp>/` | a `sprack.PDK`'s library translated for a dialect, with `sprack.log` |

The stamp of a `sprack.PDK` entry is made from the PDK's root, the
manifest's `dialect`, `corners` and `define`, the size and time of the files
its corners name, and the SPRack build. An entry is used only while every
file it was made from, the included ones too, is unchanged, and while every
`$NAME` an include path named has the value it had (from `define`, or else
from the environment); otherwise it is made again. A variable no include
path names does not matter. The same holds for a `libs/` entry, whose
variables are the environment's.

## Devices compared between simulators

`tools/pdk_devices.py` stimulates every device of a PDK's catalogue (a
MOSFET's drain current at two biases, a resistor's current at 1 V, a
capacitor's AC current at 1 MHz, a diode's forward current, a BJT's
collector current) in the PDK's own simulator and in each target's
translation, and writes one row per device, target and quantity with a
verdict: same (within 1e-4 relative), differs, refused, no model, no
reference or not run. sky130 and IHP are read from the installed trees
(`SPRACK_TEST_PDKS_INSTALLED`), which ngspice loads as they are. The two
HSPICE PDKs have no source run here: a translation that loads is "no
reference", with the target's value. The nightly workflow runs it for the
five PDKs into Xyce and VACASK against `tools/pdk-devices-baseline.tsv` and
fails when a verdict changes, either way. HSPICE and Spectre are measured
by hand (issues 56 and 57).

The baseline's rows (a device and a quantity) by verdict, from
`python3 -I tools/pdk_devices.py --table tools/pdk-devices-baseline.tsv`
(ngspice 45, Xyce 7.10, VACASK b2c1551; default corners):

| PDK | target | devices | same | differs | refused | no model | no reference | not run |
|---|---|---|---|---|---|---|---|---|
| sky130A | xyce | 258 | 137 | 152 | 2 | 0 | 88 | 0 |
| sky130A | vacask | 258 | 0 | 0 | 291 | 0 | 88 | 0 |
| ihp-sg13g2 | xyce | 60 | 19 | 27 | 0 | 12 | 11 | 0 |
| ihp-sg13g2 | vacask | 60 | 0 | 0 | 46 | 12 | 11 | 0 |
| gf180mcuD | xyce | 79 | 9 | 24 | 12 | 14 | 33 | 0 |
| gf180mcuD | vacask | 79 | 0 | 0 | 45 | 14 | 33 | 0 |
| ASAP7 | xyce | 8 | 0 | 0 | 0 | 0 | 16 | 0 |
| ASAP7 | vacask | 8 | 0 | 0 | 16 | 0 | 0 | 0 |
| FreePDK45 | xyce | 8 | 0 | 0 | 0 | 0 | 16 | 0 |
| FreePDK45 | vacask | 8 | 0 | 0 | 0 | 0 | 16 | 0 |

`tools/pdk_smoke.py` is the smaller check it grew from: one inverter per PDK,
its switching point (the input where the output crosses VDD/2) found in the
PDK's own simulator and in Xyce. A run with no points or no crossing fails.
Each inverter runs at its PDK simulator's temperature, said in the circuit
(25 degrees for the HSPICE PDKs, 27 for the ngspice one): a circuit that
sets none is an error where the target assumes another. Measured with
ngspice 45 and Xyce 7.10:

| PDK | temperature | ngspice | Xyce |
|---|---|---|---|
| sky130A | 27 | 0.8551763 V | 0.8551763 V |
| FreePDK45 | 25 | 0.5216142 V | 0.5216143 V |
| ASAP7 | 25 | (BSIM-CMG: OSDI only) | 0.3422805 V |
