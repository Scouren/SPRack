# SPRack

SPRack translates SPICE netlists between simulators: it reads a netlist in one
dialect and writes it in another, and it gives Python one way to describe a
circuit for all of them. Seven dialects are built in: ngspice, HSPICE, Xyce,
Spectre, VACASK, LTspice and CDL.

[![Tests](https://github.com/Scouren/SPRack/actions/workflows/test.yaml/badge.svg)](https://github.com/Scouren/SPRack/actions/workflows/test.yaml)
[![Nightly corpus audit](https://github.com/Scouren/SPRack/actions/workflows/nightly.yaml/badge.svg)](https://github.com/Scouren/SPRack/actions/workflows/nightly.yaml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

It translates; it does not simulate. Each dialect is one
`grammars/<name>.spgrammar` file, from which the reader and the writer for
that dialect are generated at compile time. There is no hand-written parser
per dialect and no converter per pair: every reader produces the same
canonical statements and every writer consumes them. What the target cannot
say is never dropped in silence: it is an error in the report, with the
reason and the dialects that can.

## Quick start

    nix develop                    # Zig 0.18.0-dev.349, pinned in flake.lock
    zig build                      # the command: zig-out/bin/sprack
    zig build py                   # the Python extension: python/sprack/_core.abi3.so

A netlist from ngspice to Spectre:

    $ cat amp.sp
    RC low-pass
    V1 in 0 DC 1 AC 1
    R1 in out 1k
    C1 out 0 1M
    .ac dec 10 1 1MEG
    .pz in 0 out 0 vol pz
    .end

    $ sprack translate --from ngspice --to spectre amp.sp
    // RC low-pass
    simulator lang=spectre insensitive=yes
    global 0
    V1 (in 0) vsource dc=1 mag=1
    R1 (in out) resistor r=1k
    C1 (out 0) capacitor c=1m
    ac1 ac start=1 stop=1M dec=10
    pz1 (out 0) pz iprobe=V1
    info[oneway]: line 6: pz: the input nodes in 0 are source V1, as spectre names it

`1M` is milli in SPICE and is written `1m` for Spectre, where `M` is mega.
The same file for Xyce, which has no pole-zero analysis, exits with status 1:

    $ sprack translate --from ngspice --to xyce amp.sp
    ...
    * [sprack] not written: analysis 'pz' has no xyce form
    .end
    error[unsupported]: line 6: analysis 'pz' cannot be written for xyce: Xyce has no pole-zero analysis. Dialects that define it: hspice, ngspice, spectre

The same from Python (`PYTHONPATH=python`):

    import sprack

    c = sprack.Circuit("inverter")
    c.model("nch", "bsim4", "n", vth0=0.4)
    c.model("pch", "bsim4", "p", vth0=-0.4)
    c.V("dd", "vdd", 0, 1.8)
    c.V("in", "in", 0, pulse=(0, 1.8, "1n", "50p", "50p", "2n", "4n"))
    c.M("p", "out", "in", "vdd", "vdd", "pch", w="2u", l="180n")
    c.M("n", "out", "in", 0, 0, "nch", w="1u", l="180n")
    c.tran("10p", "8n")
    print(c.netlist("ngspice"))    # Mp out in vdd vdd pch w=2u l=180n ...
    print(c.netlist("spectre"))    # Mp (out in vdd vdd) pch w=2u l=180n ...

## What it guarantees

- **Nothing is dropped.** Something in the input with no form in the target is
  an error in the report and exit status 1. There is no option to turn that
  off. The output is still written, with the line that could not be
  translated left in it as a comment.
- **Errors say why, and who can.** `analysis 'pz' cannot be written for xyce:
  Xyce has no pole-zero analysis. Dialects that define it: ...`
- **Numbers are exact.** `1.5p` is stored as the digits `1.5` and the exponent
  -12, never as a float; `1mil` is exactly 25.4e-6.
- **Source spelling is kept.** Names keep their capitals; where the source
  ignores case, a name written two ways gets one spelling, so the result is
  also right for a target that tells them apart. Comments, blank lines and
  trailing comments are carried over.
- **A translation can be checked against itself.** `sprack audit` translates,
  reads its own output back with the target's reader and compares. A
  difference the report does not explain is a bug.

## Dialects

| name | simulator | checked against |
|---|---|---|
| `ngspice` | ngspice 45 | ngspice itself: load and results (`tools/parse_check.py`, `tools/sim_check.py`) |
| `xyce` | Xyce 7.10 | Xyce itself: load and results |
| `vacask` | VACASK | VACASK built from source: load and results; its manual and parser |
| `spectre` | Spectre's own language | Spectre 25.10: every error-free translation of the corpus loaded (`tools/licensed_check.py`) |
| `hspice` | HSPICE | HSPICE Y-2026.03: the same |
| `ltspice` | LTspice | LTspice 26.0.2, run in batch mode on decks written for the check (`nix develop .#ltspice`): the tables, the `no` lines, source waveforms and topologies. Not checked: instance parameters, and MOS levels other than 1, 2, 3, 8/49 and 14/54. It runs one analysis a deck |
| `cdl` | CDL, the connectivity netlist of LVS: no sources, analyses or controls | no tool; a few lines marked `assumed` |

`sprack caps` prints which dialect can write which statement. Each grammar
file's header says what it was written from; `docs/verification.md` records
what was measured on each simulator, claim by claim.

## Command line

    sprack translate --from ngspice --to spectre amp.sp -o amp.scs
    sprack project   --from ngspice --to xyce --lib --out sky130-xyce $PDK/libs.tech/ngspice/sky130.lib.spice
    sprack catalog   --from hspice 7nm_TT.pm         # the subcircuits and models, as JSON
    sprack read      --from spectre amp.scs          # the netlist as JSON
    sprack write     --to vacask amp.json            # a netlist from that JSON
    sprack audit     --from ngspice --to spectre amp.sp
    sprack dialects | caps | info

Exit status: 0 when nothing was lost, 1 when the report has an error, 2 for a
wrong command line. Wherever a dialect is named, a path ending in
`.spgrammar` may stand instead and is compiled on the spot.
`project` follows every `.include` and `.lib` and writes a translated copy of
the whole tree: this is how a PDK is translated. More in
[docs/src/cli.md](docs/src/cli.md).

## Python

The package is a compiled extension (`sprack._core`, CPython's limited API:
one binary for Python 3.10 and later) and a thin layer on top that knows no
dialect: it builds statements of the canonical vocabulary and the core writes
them.

- **Everything is a function.** Devices by SPICE letter (`c.R`, `c.M`, `c.X`,
  ...) or by kind (`c.resistor`), every analysis and control statement by
  name, and a `with` block for a statement that holds others (a subcircuit, a
  sweep, an alter, a conditional, a library section). A test builds every
  kind with every slot through the builder: no netlist text is needed for
  anything a reader understands.
- **The vocabulary is closed.** `c.tran("1n", "1u", errpreset="moderate")`
  raises `TypeError: tran has no 'errpreset'; it has: name, step, stop, ...`.
- **`netlist(dialect)`** raises `sprack.Unsupported` when the dialect cannot
  say something, with the reason and the dialects that can; `strict=False`
  returns the netlist with the report attached as `.report`.
- **Numbers** are Python numbers or strings with an SI suffix (`"10n"`,
  `"1meg"`); `"1M"` is refused as ambiguous. Any other string is an
  expression.
- **Existing netlists**: `sprack.translate(text, frm=, to=)`,
  `sprack.read(text, dialect)`, and `c.code(text, dialect)` to add statements
  written in a dialect to a circuit.

### A netlist as a Python script

Any netlist, in any dialect, becomes a flat script of builder calls:

    $ python -m sprack --from ngspice deck.sp
    import sprack

    c = sprack.Circuit("t", dialect="ngspice")
    c.R("1", "a", 0, "1k")
    c.tran("1n", "1u", uic=True)

(`sprack.to_python(text, dialect)` and `Circuit.python()` do the same.) The
script rebuilds the circuit: every dialect is written from it exactly as from
the netlist. A line no rule of the dialect understood is the one thing with
no call; it is kept as a `c.code(...)` block of that dialect's text.

### PDKs

    pdk = sprack.PDK("sky130A")                  # from $PDK_ROOT, corner tt
    c = sprack.Circuit("inverter", pdk=pdk)
    c.pfet_01v8("Mp", "out", "in", "vdd", "vdd", w=1, l=0.15)

`sprack.PDK` finds a PDK's model libraries, lists the devices they define and
makes each one a method of the circuit, with terminals counted and parameter
names checked. For a target of another dialect the whole library is
translated once into `~/.cache/sprack` and referenced from there. A PDK is
described by a small JSON manifest; five ship (sky130A, IHP SG13G2, ASAP7,
FreePDK45, GF180MCU), and `manifest=` takes your own. Without a manifest,
name the library in its own dialect, `c.code('.lib "models.lib" tt',
"ngspice")`: for a target of another dialect the file and everything it
includes are translated the same way. See
[docs/src/pdks.md](docs/src/pdks.md) and
[docs/src/adding-a-pdk.md](docs/src/adding-a-pdk.md).

### Shipping it inside another program

The package to ship is a self-contained directory:

    python/sprack/__init__.py
    python/sprack/_core.abi3.so     # _core.pyd on Windows; CPython 3.10+
    python/sprack/pdks/*.json       # the PDK manifests

Put the directory holding `sprack/` on `PYTHONPATH`; nothing is installed and
nothing else is needed. The flake builds it for five platforms from any one,
offline, in the Nix sandbox:

    nix build .#python                       # this system's
    nix build .#python-x86_64-linux-gnu      # glibc 2.28 or later, baseline x86-64
    nix build .#python-aarch64-linux-gnu     # glibc 2.28 or later
    nix build .#python-x86_64-macos
    nix build .#python-aarch64-macos
    nix build .#python-x86_64-windows-gnu    # _core.pyd, imports python3.dll

each giving `result/python/sprack/`. Without Nix, the same is
`zig build bundle -Doptimize=ReleaseSafe -Dtarget=<target> --prefix <dir>`
(targets as in `flake.nix`'s `bundleTargets`); `zig build py` also writes the
host's bundle into `zig-out/python/`. A Windows build links an import library
for `python3.dll` that `zig dlltool` makes from `src/python3.def`, so no
Python is needed to build it. Checked: the x86_64 Linux bundle imports and
runs under CPython 3.11 and 3.13; the macOS ones leave the Python symbols to
flat-namespace lookup and the Windows one imports them from `python3.dll`.
CI installs the wheel on Linux, macOS and Windows and runs the package's
tests with it, under CPython 3.10 and 3.13.

The only file written outside the package is the translation cache,
`~/.cache/sprack` unless `SPRACK_CACHE` or `cache_dir=` says otherwise.
`pip wheel .` (or `python -m build`, which also writes the sdist) packages
the same files as a wheel, tagged by the libc Zig built against rather than
the build host: `cp310-abi3-manylinux_2_28_x86_64` (or `_aarch64`) on Linux,
`cp310-abi3-macosx_11_0_arm64` (or `_x86_64`) on macOS, where
`MACOSX_DEPLOYMENT_TARGET` overrides the 11.0, and `cp310-abi3-win_amd64` on
Windows. `auditwheel show` agrees with both Linux tags; the extension needs
only glibc 2.28 and nothing to repair. `pip wheel . --config-settings
target=x86_64-windows` builds the Windows wheel on another host.
The sdist ships what `zig build py` needs: `build.zig`, `build.zig.zon`,
`src`, `grammars`, `python`, `tools/wheel_backend.py`, `pyproject.toml`,
`LICENSE` and this file.

## Status

Version 0.1.0 (`build.zig.zon`, the one place it is written); not yet
published to a package index. CI builds and tests with Zig 0.18.0-dev.349
(`flake.lock`, and setup-zig in the workflows); 0.17.1, the minimum
`build.zig.zon` declares, builds it and passes the same tests, but no
workflow runs it.
A release is one run of the Publish workflow (`.github/workflows/publish.yaml`):
it moves the version, tests, tags, and uploads the sdist and wheels to PyPI.

| | |
|---|---|
| Statement kinds | every kind has a rule, another statement that carries it, or a stated reason in every dialect (`sprack caps` shows no gap; a test keeps it so) |
| Corpus | VAMS Conformance Suite, 969 decks, 9,670 translations: no crash, no difference the report does not explain |
| Simulators | output loaded and compared in ngspice, Xyce and VACASK; loaded in Spectre and HSPICE; the LTspice grammar measured on LTspice 26.0.2 |
| PDKs | five open PDKs translated whole (table below); inverters simulated in ngspice; every catalogue device of sky130, IHP and GF180 compared between ngspice and its Xyce translation nightly (`tools/pdk_devices.py`, the verdicts in `tools/pdk-devices-baseline.tsv` once the first run writes it; see docs/src/pdks.md) |
| Python | every statement kind and slot reachable through the builder |
| CI | tests on every push (Linux), wheels on Linux, macOS and Windows for CPython 3.10 and 3.13, corpus audit nightly |

Whole model libraries, all corners, errors per target:

| PDK (written in) | files | to ngspice | to HSPICE | to Xyce | to Spectre | to VACASK |
|---|---|---|---|---|---|---|
| sky130 (ngspice) | 281 | 0 | 0 | 47 | 0 | 0 |
| IHP SG13G2 (ngspice) | 31 | 0 | 0 | 71 | 0 | 0 |
| ASAP7 (HSPICE) | 3 | 24 | 0 | 0 | 0 | 24 |
| FreePDK45 (HSPICE) | 27 | 0 | 0 | 0 | 0 | 0 |
| GF180MCU (ngspice) | 4 | 0 | 0 | 181 | 0 | 0 |

LTspice and CDL have no column. CDL is the netlist of LVS, with no model
cards to write, so a model library has nothing for it. LTspice has no
resistor or capacitor model family and few of the functions PDKs use, so a
whole library has errors by the hundred (87 for sky130, 241 for IHP and 250
for GF180 when last counted, against 0 for FreePDK45), which says more about
the target than about the translation; the corpus audit writes and gates
both targets like the others.

Every error names a file and a line. What is left, and whose it is:

- sky130: two lines of the PDK that are not ngspice syntax, which ngspice itself refuses ([issue 25](https://github.com/Scouren/SPRack/issues/25)), are read through the errata of its manifest (`python/sprack/pdks/sky130A.json`, `sprack project --errata`), each a caveat: the include of the ESD transistor with its real path, and the Monte Carlo resistor as a resistor with `tc1` and `tc2`. A third, in the installed sky130A, puts an instance's subcircuit after its parameters.
- sky130 to Xyce 3, IHP to Xyce 22, GF180 to Xyce 88: diode, BJT and VBIC card parameters that ngspice's models have and Xyce's devices do not (`tlev`, `tlevc`, `cta` on diodes; BJT temperature coefficients such as `tnf1`, `tbf1`, `tikf1`, `trc1`): every name Xyce 7.10 declares for each family is now listed (`tools/param_lists.py`), and any other is an error where Xyce would ignore it. At ngspice's default value they are warnings.
- sky130 to Xyce 12, IHP to Xyce 13, GF180 to Xyce 29: diode cards of ngspice's level 3, which most of the three PDKs' junction diodes are, and with them the transistors with a drain diode and the diffusion and well resistors that hold one. The target has no such thing: Xyce 7.10's diode has levels 1, 2, 200 and 2002 and refuses a device of a level 3 card, and its level 2 is another model ([issue 30](https://github.com/Scouren/SPRack/issues/30)).
- sky130 to Xyce 20, GF180 to Xyce 64: resistor and capacitor cards with a parameter Xyce's card does not take, which Xyce would drop with a warning and simulate without (`modelparams resistor only`, from `Xyce -param`): a card's own value (sky130's `res` on 9 resistor cards; GF180's `cap` on 15 MIM capacitors, whose devices Xyce then refuses), noise parameters (`kf`, `af`, `noise`) and names Xyce has no parameter for. ngspice's other names for a parameter Xyce has (`tc1r`, `tc2r`, `w`, `cox`, `capsw`) are written in Xyce's spelling.
- sky130 to Xyce, 12: resistor models with a width reduction (`dw`) and no length reduction. Xyce's resistor model takes one number off both; not yet translated.
- ASAP7 to ngspice and to VACASK, 24 each: BSIM-CMG, which neither has built in. Upstream: [issue 27](https://github.com/Scouren/SPRack/issues/27).
- IHP to Xyce, 16: the Verilog-A modules `r3_cmc`, `mosvar`, `cap_cmomi` and `cap_cmomf` (7 model cards) and their 9 instances. Xyce takes a Verilog-A module only as a plugin built with buildxyceplugin and named on its command line; with `--xyce-plugin MODULE=FILE` for each, the instances are written as Xyce's `Y<module>` lines with a caveat to run Xyce with `-plugin`, and the 16 are gone ([issue 52](https://github.com/Scouren/SPRack/issues/52); whether IHP's modules build and agree with ngspice is not yet measured).
- IHP to Xyce, 17: the NQS module of PSP103 (`pspnqs103va`), 5 model cards and their 12 instances, one in the `rfmode` branch of each transistor subcircuit. The target has no such thing: Xyce's PSP103 has no NQS.
- IHP to Xyce, 3: the PSP103 parameter `thecso` on three model cards. The target has no such thing: Xyce's PSP103 ignores it, and the drain current of a transistor measured with it is 12 % off.

## Tests

    zig build test                                # everything below marked "zig"
    cd python && python3 test_sprack.py           # after zig build py

| what | where | count |
|---|---|---|
| End-to-end and unit tests (zig) | `src/tests.zig` and each module | 236 tests |
| The command: output and exit status of every subcommand (zig) | `build.zig`, `zig build test-cli` | 35 runs |
| The Python package | `python/test_sprack.py` | 40 tests, 11 of them on real PDK libraries |
| Corpus audit, nightly | `tools/corpus_audit.py`, `tools/corpus_compare.py` | 9,670 translations |
| Load and result checks in the simulators | `tools/parse_check.py`, `tools/sim_check.py`, `tools/licensed_check.py`, `tools/vacask-loadcheck/` | by hand, where the tools are |

What the tests hold the translator to:

- **Every example is also checked for what must always hold.** Each of the
  about 300 translations in `src/tests.zig` goes through one helper that also
  requires: twice gives the same bytes; the JSON form reads back as the same
  statements and writes the same output; the grammar file compiled at run
  time behaves as the one compiled in; the target reads the output as the
  same circuit or the report says why not; and what the target read, it
  writes again without an error.
- **The whole vocabulary.** Every statement kind, with all its slots and with
  each alone, is written by every dialect (about 4,300 cases); every `no`
  line of every grammar gives its reason; all 49 pairs of dialects translate
  one circuit and read it back.
- **Damaged input.** 20,000 randomly damaged netlists and a fuzz target go
  through every reader and writer without a crash, one in eight through the
  byte-for-byte checks above; truncated input, deeply nested and oversized
  grammars are refused with a message.
- **Both compilers of a grammar agree.** Each of the seven grammar files
  compiled at run time equals, field for field, the one compiled into the
  binary.

The PDK tests need the model libraries: `nix build .#test-pdks` and
`.#test-pdks-installed`, named by `SPRACK_TEST_PDKS` and
`SPRACK_TEST_PDKS_INSTALLED`; without them those tests are skipped and say
so. More in [docs/src/testing.md](docs/src/testing.md).

## Documentation

- [Command line](docs/src/cli.md) and [Python](docs/src/python.md)
- [Using it with any simulator](docs/src/simulators.md), and
  [adding one](docs/src/adding-a-simulator.md): a `.spgrammar` file, used by
  path at once or dropped into `grammars/` to become built in
- [The `.spgrammar` reference](docs/src/grammar-reference.md), with the
  report codes
- [Using it with any PDK](docs/src/pdks.md), and
  [adding one](docs/src/adding-a-pdk.md)
- [What was measured on each simulator](docs/verification.md)

The pages are an mdBook (`mdbook build docs`), published as a website by
`.github/workflows/web.yaml`.

## Layout

    grammars/*.spgrammar   the seven dialects
    src/schema.zig         canonical kinds, slots, model families, functions
    src/grammar.zig        the .spgrammar compiler (at compile time and at run time)
    src/lexer.zig          lines, tokens, exact numbers
    src/reader.zig         pattern matcher: text to statements
    src/writer.zig         patterns in reverse: statements to text
    src/expr.zig           expressions
    src/topology.zig       circuits a target cannot solve (`requires`)
    src/ir.zig             statements, values, reports, circuit comparison
    src/json.zig           the statements as JSON
    src/project.zig        include following, shared declarations, catalogue
    src/stream.zig         translation a statement at a time, after a survey
    src/main.zig           the command
    src/pyext.zig          the CPython extension
    src/capi.zig           a C ABI for other hosts
    python/sprack/         the Python package and the PDK manifests
    tools/                 corpus audit and simulator check scripts
    docs/                  the documentation site (mdBook) and the verification log

## Known limits

* `sprack caps` shows every kind per dialect. A `-` there is a statement the
  simulator has but its grammar here has no rule for; it is an error when
  used. Most are in VACASK (controlled sources, coupling, transmission lines,
  libraries, initial conditions), where the syntax could not be confirmed.
  Spectre and HSPICE have none.
* HSPICE noise is written as `.AC` plus `.NOISE`. A `.NOISE` read takes its
  sweep from the `.AC` before it, as `.LIN` does for `sp` and `.LSTB` for
  `stb`. Spectre's `xf` at 0 Hz stands for `.tf` one way only: it names no
  source; read back, an `xf` is an AC transfer function. Spectre's and
  HSPICE's `pac`, `pnoise` and `pxf` follow a separate `pss` or `hb`, while
  VACASK's take the period on the same statement, so between them they are
  an error.
* Sweeps: `.dc` of a source, a resistor, a parameter or the temperature,
  stepped, by points per decade or octave, or listed (`dc`); `.step`,
  HSPICE's `.temp` with several values and Spectre's `sweep` blocks (`step`,
  whose body is the analyses it repeats); `.data` tables and `data=` sweeps
  over them (`data`). A `.step` line sweeps every analysis of its netlist, so
  a Spectre sweep around only some of them has no SPICE form except
  HSPICE's, where `SWEEP` at the end of an analysis line repeats that
  analysis alone; VACASK, whose sweep belongs to the one analysis after it,
  has no `step`. Not in the vocabulary: Spectre's `paramset`, and `.data`
  read from files (`MER`, `LAM`).
* Alters (`alter`, whose body is its edits): HSPICE `.alter`, Spectre
  `altergroup` and one-change `alter` statements, each a rerun of every
  analysis on top of the alters before it. Spectre gets the analyses again
  after each altergroup, and an altergroup cannot add an instance. VACASK
  (`alter instance(...)`, `options temp=` in the control block), ngspice (a
  `.control` block per run with `alterparam`, `reset`, `run`; ngspice then
  runs the analyses once more, as the last run left them) and Xyce (a
  `.step` over a `.data` table, a row per run) take only alters that change
  parameters and the temperature; anything else in an alter is an error
  there. Read back, those three are not alters.
* Parameters of model cards are copied by name, with one warning per file:
  the simulators ship different versions of the same model. Into Xyce, the
  names of resistor, capacitor, diode, BJT, VBIC, BSIM3, BSIM4 and PSP103
  cards are checked against every parameter Xyce declares for the device
  (BSIM-CMG and VACASK not yet); whether they mean the same was measured
  for PSP103 only (docs/verification.md 4.23). Instance
  parameters are checked (`params` tables) for resistors, capacitors,
  inductors, current sources, diodes, BJTs and JFETs, and HSPICE MOSFETs.
* The topology check (`requires`) runs when translating between two
  dialects, not on a deck written back in its own (read in it, or built in
  Python from `code` blocks all of it). A deck with no analysis, a cell
  netlisted on its own, gets no report; a rule that lists analyses fires
  only where one of them is present. An island fed by a current source
  follows the grammar's `cutset` rule, or, with none, is reported with any
  analysis. A deck whose every analysis is a UIC transient needs no DC
  path, and only a loop of voltage sources is reported in it. It does not flatten:
  each subcircuit is summarised by which ports its body joins at DC, and
  by which it joins through voltage sources only, inductors only, or both;
  an instance stands for those paths in its parent, so a loop through
  instances (`V1, X1(a,b), V2`) is found at any depth. A device whose DC behaviour
  depends on its model (behavioural sources, Verilog-A, transmission lines,
  cells defined in other files) is taken to join all its terminals, and the
  branches of a conditional all count, so it errs towards no alarm.
* Two limits keep damaged input from taking the process down. An input or
  included file must be a regular file (or a pipe) of at most 1 GiB: an
  include of `/dev/zero` is refused with an error naming it. Blocks nest at
  most 100 deep (subcircuits, conditional blocks, a JSON `body` or list):
  deeper, an `invalid` error, and the rest is read as statements or text.
* Memory: `sprack translate` surveys the netlist, then reads and writes one
  top-level statement at a time. Measured peak: 1.5 times the input on a
  111 MiB RC mesh and 1.6 times on 45 MiB of sky130 cells (2.1 times into
  Spectre, whose report alone is a third of the input). A netlist with a
  sweep, an alter, a pole-zero analysis, a model of an unlisted type, a
  statistics block to fold or a change of language is still read whole, at
  7 times its size or more; so are `read`, `write`, and the Python
  package's `Circuit.read` and `to_python` (its `translate` streams as the
  command does: 44 MiB at peak on a 4 MiB deck, the interpreter included).

## License

MIT. See [LICENSE](LICENSE).
