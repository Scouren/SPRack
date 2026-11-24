# Adding a PDK

**Do I need to write a `.json` file for a new PDK?**

* To use its library **by path**: no. Name the library in the circuit or
  give it to `sprack project`, as in
  [Without a manifest](pdks.md#without-a-manifest). SPRack needs to know
  only which dialect the files are in.
* To use **`sprack.PDK`**, with the PDK's devices as checked methods and its
  corners by name: yes, a manifest. It is about ten lines, and it can be
  given in three ways:
  * a JSON file anywhere, passed as `manifest="path.json"`;
  * a Python dict, passed as `manifest={...}`;
  * a JSON file added to `python/sprack/pdks/`, which makes the PDK known by
    name like the five that ship.

Nothing else about a PDK is written down anywhere. The list of devices,
their terminals and their parameters come from reading the library.

## A minimal manifest

The made-up PDK of the last page is one file, `mine/models.lib`, in
ngspice's dialect, with the corners `tt` and `ff` as library sections. Its
manifest, [`mine.json`](examples/mine.json):

```json
{
  "name": "mine",
  "dialect": "ngspice",
  "layouts": [{"probe": "models.lib"}],
  "corners": {
    "tt": [["models.lib", "tt"]],
    "ff": [["models.lib", "ff"]]
  }
}
```

Those four fields are the required ones. Load it and look:

```python
import sprack

pdk = sprack.PDK("mine", root="mine", manifest="mine.json")
print(pdk)
print(pdk.corners, pdk.corner)
for name, dev in pdk.devices.items():
    print(name, dev["kind"], dev.get("ports") or dev["family"] + " " + dev["polarity"])
```

```text
PDK('mine', root='…/mine', corner='tt', dialect='ngspice')
('tt', 'ff') tt
nch model mos1 n
pch model mos1 p
mine_nfet subckt ['d', 'g', 's', 'b']
mine_pfet subckt ['d', 'g', 's', 'b']
```

(`…` stands for the directory the examples were run in.) SPRack found the
two model cards and the two subcircuits by reading the file. Build an
inverter with them and write it for the PDK's own dialect and for another:

```python
c = sprack.Circuit("inverter", pdk=pdk)
c.V("dd", "vdd", 0, 1.8)
c.V("in", "in", 0, pulse=(0, 1.8, "1n", "50p", "50p", "2n", "4n"))
c.mine_pfet("Xp", "out", "in", "vdd", "vdd", w="2u", l="0.18u")
c.mine_nfet("Xn", "out", "in", 0, 0, w="1u", l="0.18u")
c.tran("10p", "8n")
print(c.netlist("ngspice"))
print(c.netlist("spectre"))
```

```text
inverter
.lib "…/mine/models.lib" tt
Vdd vdd 0 dc 1.8
Vin in 0 pulse(0 1.8 1n 50p 50p 2n 4n)
Xp out in vdd vdd mine_pfet w=2u l=0.18u
Xn out in 0 0 mine_nfet w=1u l=0.18u
.tran 10p 8n
.end

// inverter
simulator lang=spectre
global 0
include "…/cache/mine/spectre-tt-6dc9e293adcfcaad/models.lib" section=tt
Vdd (vdd 0) vsource dc=1.8
Vin (in 0) vsource type=pulse val0=0 val1=1.8 delay=1n rise=50p fall=50p width=2n period=4n
Xp (out in vdd vdd) mine_pfet w=2u l=0.18u
Xn (out in 0 0) mine_nfet w=1u l=0.18u
tran1 tran step=10p stop=8n
```

For ngspice the netlist references the PDK's file. For Spectre the library
was translated into the cache and the netlist references the copy.

## The manifest, field by field

| field | required | meaning |
|---|---|---|
| `name` | yes | the PDK's name; also the name of its directory in the cache |
| `dialect` | yes | the dialect the PDK's files are written in: a built-in name (in any case), or the path of a `.spgrammar` file; in a manifest file, a path relative to that file |
| `layouts` | yes | a list of the directory layouts the PDK is found in; see below |
| `corners` | yes | each corner's name and the files that make it up; see below |
| `default_corner` | no | the corner used when none is asked for; without it, the first one of `corners` |
| `aliases` | no | other names the PDK is found by, for a manifest in `python/sprack/pdks/` |
| `about` | no | a line of description, for people |
| `env` | no | environment variables tried in order for the root when `root=` is not given; `["PDK_ROOT"]` when left out |
| `prefix` | no | a prefix every device name starts with; a device method may leave it out |
| `define` | no | values for `$NAME` in the library's include paths |
| `load` | no | Verilog-A or OSDI files loaded at the top of a netlist |

**`layouts`** is a list because one PDK comes in several shapes (installed,
or as its source repository). Each entry has a `probe`, a file path relative
to the root, and optionally `vars`. The first layout whose probe file exists
under the root is the one used, and its `vars` may then be used as `{name}`
in the paths of `corners`, `define` and `load`; `{root}` is always there.
From the manifest of ASAP7, shortened:

```text
"layouts": [
  {"probe": "models/hspice/7nm_TT.pm", "vars": {"m": "models/hspice"}},
  {"probe": "asap7PDK_r1p7/models/hspice/7nm_TT.pm", "vars": {"m": "asap7PDK_r1p7/models/hspice"}}
],
"corners": {
  "tt": [["{m}/7nm_TT.pm", null]],
  "ff": [["{m}/7nm_FF.pm", null]]
}
```

**`corners`** maps a corner's name to a list of `[file, section]` pairs. The
file is relative to the root. The section is the library section to take
from it (`.lib "file" section`), or `null` to include the whole file
(`.include "file"`). A corner may name several pairs; the GF180MCU manifest
takes eight per corner, a design file and one section each for the MOSFETs,
the bipolars, the diodes and so on.

**`env`** lists the variables read for the root, in order. A manifest
without `env` reads `$PDK_ROOT`.

**`prefix`**: with `"prefix": "mine_"`, `c.nfet(...)` finds `mine_nfet`. The
dict form of a manifest is convenient for trying a field:

```python
import json

manifest = {**json.load(open("mine.json")), "prefix": "mine_", "default_corner": "ff"}
ff = sprack.PDK("mine", root="mine", manifest=manifest)
d = sprack.Circuit("one device", pdk=ff)
d.nfet("Xn", "out", "in", 0, 0, w="1u")
print(d.netlist("ngspice"))
```

```text
one device
.lib "…/mine/models.lib" ff
Xn out in 0 0 mine_nfet w=1u
.end
```

**`define`** is for a library whose include lines use a variable. FreePDK45's
files include `$PDK_DIR/...`, so its manifest says
`"define": {"PDK_DIR": "{root}/{top}"}`.

**`load`** lists files a netlist in the PDK's own dialect must load before
the models. IHP SG13G2 lists its compiled OSDI models there; only those that
exist are loaded.

## Making it built in

Put the JSON file in `python/sprack/pdks/`. It is then found by its `name`
and `aliases`, in any case, with no `manifest=`:
`sprack.PDK("mine", root=...)`. `sprack.PDK.known()` lists the names. The
five files there are the examples to copy from.

## Checking a new manifest

SPRack checks the corner you ask for against the files. A corner that names
a file that is not there is refused when the PDK is created, and a section
no file defines is refused when the libraries are first read (`pdk.devices`,
or writing a netlist):

```text
SprackError: mine: corner 'tt' names …/mine/nothere.lib, which is not there
SprackError: mine: corner 'tt' names section 'typ' of …/mine/models.lib, which defines: tt, ff, devices
```

Only the chosen corner is checked, so load each one once:

```python
for corner in pdk.corners:
    one = sprack.PDK("mine", root="mine", corner=corner, manifest="mine.json")
    print(corner, len(one.devices), "devices")
```

```text
tt 4 devices
ff 4 devices
```

The device list and the translated copies are cached under the PDK's name
(see [The cache](pdks.md#the-cache)). The cache follows the manifest: a
change to its `dialect`, `corners` or `define`, or to any file the libraries
read, makes a new entry. So does another value of an environment variable
that an include path of the libraries names.

Then:

1. Print `sorted(pdk.devices)` and see that the devices you expect are
   there, with the terminals you expect.
2. Build one instance of each device you will use and write the netlist in
   the PDK's own dialect. Run it in the simulator.
3. Write it for the other dialect you need. Read the report: every line of
   the library the target cannot say is listed with file and line
   (`strict=False` if those lines are not in the devices you use).

## What the errors mean

```text
SprackError: no manifest for PDK 'mine'; known: ASAP7, FreePDK45, gf180mcuD, ihp-sg13g2, sky130A. Pass manifest= for another PDK.
```

The name is not one of the built-in manifests and no `manifest=` was given.

```text
SprackError: mine: no model library found. Looked for:
  /nowhere/models.lib
```

No layout's `probe` file exists under the root. The root is wrong, or the
probe path is.

```text
SprackError: mine: give root=, or set $PDK_ROOT
```

No `root=` and no variable of the manifest's `env` is set. A manifest with
no `env` reads `$PDK_ROOT`.

```text
SprackError: mine has no corner 'ss'; it has: tt, ff
```

The `corner=` asked for is not in `corners`.

```text
SprackError: the manifest for PDK 'mine' lacks dialect; a manifest needs: name, dialect, layouts, corners, and each layout a probe
```

A required field is missing from the manifest.

```text
TypeError: mine_nfet has 4 terminals (d, g, s, b), got 3
TypeError: mine_nfet has no parameter 'nf'; it has: w, l
AttributeError: 'nfte' is neither a statement kind nor a device of mine. Did you mean: nfet, pfet?
```

The manifest is fine; the call does not match the device the library
defines.

## Lines the PDK's own simulator refuses: errata

A PDK can ship a line its own simulator refuses; sprack then cannot read
it either, and it is an `untranslated` error into every other dialect. A
manifest's `errata` list says what to read instead, as an installer such
as open_pdks does:

```json
"errata": [
  {"file": "models/r+c.mrp1monte.spice",
   "was": "sky130_fd_pr__res_generic_po r0 r1 ... tc1r = {tc1} tc2r = {tc2}",
   "read": "Rsky130_fd_pr__res_generic_po r0 r1 ... tc1 = {tc1} tc2 = {tc2}",
   "why": "ngspice reads a line starting with s as a switch", "issue": 25}
]
```

`file` is matched against the end of each path read; `was` and `read` are
whole lines (several, joined by newlines, for a statement with
continuations). Each one read is a `caveat` warning with its line; one
whose file is read but whose `was` is not in it is an info that the
erratum no longer applies, and can go. `sprack.PDK` passes the list to the
core; `sprack project --errata manifest.json` reads it from a file. A PDK
used in its own dialect is referenced in place and not changed.

