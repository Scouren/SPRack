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
150 files, 2 errors, 79 warnings
```

Status 1: two lines of the library have no form in Xyce. Each error names
its file and line, and says what is wrong:

```text
pdks/sky130_fd_pr/cells/nfet_05v0_nvt/sky130_fd_pr__nfet_05v0_nvt.pm3.spice:16: error[untranslated]: no ngspice rule understood this line; it is in the output only as a comment: include "sky130_fd_pr__esd_nfet_05v0_nvt.pm3"
pdks/sky130_fd_pr/models/r+c.mrp1monte.spice:33: error[untranslated]: no ngspice rule understood this line; it is in the output only as a comment: sky130_fd_pr__res_generic_po r0 r1 sky130_fd_pr__res_generic_po__monte r = {r_tot} tc1r = {tc1} tc2r = {tc2}
```

Both are lines of the library that are not ngspice syntax. The rest of the
tree is translated (a parameter named `vt`, which Xyce refuses, is written
as `vt__p` with a note), and whether those two matter depends on the
devices you use.

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
236 devices
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
sky130_fd_pr__nfet_01v8 has no parameter 'fingers'; it has: l, w, ad, as, pd, ps, nrd, nrs, sa, sb, sd, mult, nf
'nfet_01v9' is neither a statement kind nor a device of sky130A. Did you mean: nfet_01v8, pfet_01v8, nfet_01v8_lvt, esd_nfet_01v8, pfet_01v8_mvt?
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
    c.netlist("spectre")
except sprack.Unsupported as err:
    print(len(err.report.errors), "errors")
    print(err.report.errors[0])
```

```text
2 errors
error[untranslated]: pdks/sky130_fd_pr/cells/nfet_05v0_nvt/sky130_fd_pr__nfet_05v0_nvt.pm3.spice:line 16: no ngspice rule understood this line; it is in the output only as a comment: include "sky130_fd_pr__esd_nfet_05v0_nvt.pm3"
```

`strict=False` accepts the copy as it is and puts those errors in the
netlist's report. Use it when the lines in question are not in the devices
you instantiate:

```python
out = c.netlist("spectre", strict=False)
print(out)
print(len(out.report.errors), "errors in the report")
```

```text
// inverter
simulator lang=spectre
global 0
include "…/cache/sky130A/spectre-tt-67114f2025387e38/models/sky130.lib.spice" section=tt
Vdd (vdd 0) vsource dc=1.8
Vin (in 0) vsource type=pulse val0=0 val1=1.8 delay=1n rise=50p fall=50p width=2n period=4n
Mp (out in vdd vdd) sky130_fd_pr__pfet_01v8 w=1 l=0.15
Mn (out in 0 0) sky130_fd_pr__nfet_01v8 w=0.5 l=0.15
tran1 tran step=10p stop=8n

2 errors in the report
```

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
