# SPRack: SPICE dialect translator

SPRack reads a netlist in one SPICE dialect and writes it in another, and lets
a Python program describe a circuit once and get it in any of them. Eight
dialects are built in: ngspice, HSPICE, Xyce, Spectre, VACASK, ESPice,
LTspice and CDL (see [Dialects](#dialects)).

It translates; it does not simulate. Each dialect is described in one
`grammars/<name>.spgrammar` file. The Zig compiler reads those files at compile
time and generates the reader and the writer for each. There is no hand-written
parser per dialect and no converter per pair of dialects: every reader produces
the same canonical statements, and every writer consumes them.

    zig build                      # the sprack command, zig-out/bin/sprack
    zig build py                   # the Python extension, python/sprack/_core.abi3.so
    zig build test                 # 51 tests
    pip wheel . -w dist            # sprack-<ver>-cp310-abi3-<platform>.whl (Zig on PATH)

Built and tested with Zig 0.18.0-dev.349 (pinned in flake.lock; `nix develop`).

## Dialects

| name | what | `assumed` lines |
|---|---|---|
| `ngspice` | ngspice 45 | 0 |
| `hspice` | HSPICE | 0 |
| `xyce` | Xyce | 0 |
| `spectre` | Spectre's own language | 1 |
| `vacask` | VACASK, from its README, slides and upstream decks | 9 |
| `espice` | ESPice, from its docs: ngspice's dialect with `.hdl` for Verilog-A source, `.pss f0 [points]`, `.hb TONES= NHARMS=`, `.stb probe ...`, and its model levels (BSIM-CMG 72, BSIM-BULK 77, PSP 103 at 1040) | 0 |
| `ltspice` | LTspice, from knowledge of its syntax; no LTspice was available to check against | 13 |
| `cdl` | CDL for LVS (Cadence netlister, Calibre): subcircuits, `X ... / name` instances, devices, `.PARAM`, `.GLOBAL`, `$` comments. No sources, analyses or controls: each is a `no` line | 4 |

Each file's header says what it was written from. A line marked `assumed` is
syntax that source does not settle.

CDL's annotations (`$[model]`, `$X=`) and `*.PININFO` lines are comments to
SPRack: carried over as written, not understood.

## What it guarantees

**Nothing is dropped.** If something in the input has no form in the target,
the report carries an error for it and the exit status is 1. There is no option
to turn that off. The output is still written, with the line that could not be
translated left in it as a comment, so you can see what is missing.

**Errors say why, and who can.** `analysis 'pz' cannot be written for xyce:
Xyce has no pole-zero analysis. Dialects that define it: ngspice`.

**Numbers are exact.** `1.5p` is stored as the digits `1.5` and the exponent
-12, never as a float. `1M` read as ngspice is milli and is written to Spectre
as `1m`; `1mil` is exactly 25.4e-6.

**Source spelling is kept.** Names keep the capitals the author gave them.
Where the source ignores case, a name written `Vdd` in one place and `VDD` in
another gets one spelling (the first capitalised one), so the result is also
correct for a target that does distinguish case. Comments, blank lines and
trailing comments are carried over.

**A translation can be checked against itself.** `sprack audit` translates,
reads its own output back with the target's reader and compares. A difference
that the report does not explain is a bug.

## Command line

    sprack translate --from ngspice --to spectre amp.sp -o amp.scs
    sprack project   --from ngspice --to xyce --lib --out sky130-xyce $PDK/libs.tech/ngspice/sky130.lib.spice
    sprack catalog   --from hspice 7nm_TT.pm
    sprack read      --from spectre amp.scs          # the netlist as JSON
    sprack write     --to vacask amp.json            # a netlist from that JSON
    sprack caps                                      # which dialect can write what
    sprack info                                      # the schema, as JSON

Wherever a dialect is named (`--from`, `--to`), a path ending in
`.spgrammar` may stand instead: that grammar is compiled when the command
starts, by the same compiler that builds the built-in ones (a fraction of a
millisecond). A mistake in it is reported as `path:line: message`. Error
messages that list the "dialects that define" something name only the
built-in ones.

`project` follows every `.include` and `.lib` from the files it is given and
writes a translated copy of the whole tree, with the include lines rewritten as
relative paths. It reads the set twice: once to learn which models,
subcircuits and functions each file declares, once with that knowledge. That
is what lets a Spectre instance line be recognised as a MOSFET when its model
is declared three includes away. `$NAME` in include paths is expanded from the
environment or from `-D NAME=VALUE`. With `--lib` the named files are libraries
themselves, with no title line, as in a PDK.

## Python

    import sprack

    pdk = sprack.PDK("sky130A")                  # from $PDK_ROOT, corner tt
    c = sprack.Circuit("inverter", pdk=pdk)
    c.V("dd", "vdd", 0, 1.8)
    c.V("in", "in", 0, pulse=(0, 1.8, "1n", "50p", "50p", "2n", "4n"))
    c.pfet_01v8("Mp", "out", "in", "vdd", "vdd", w=1, l=0.15)
    c.nfet_01v8("Mn", "out", "in", 0, 0, w=0.5, l=0.15)
    c.tran("10p", "8n")
    print(c.netlist("ngspice"))
    print(c.netlist("spectre"))

The package is a compiled extension module (`sprack._core`, written in Zig
against CPython's limited API, so one binary serves Python 3.10 and later) and
a thin Python layer on top. The Python layer knows no dialect: it builds
statements of the canonical vocabulary and the core writes them.

* Devices are methods named by SPICE letter (`R`, `C`, `L`, `K`, `V`, `I`,
  `B`, `E`, `G`, `F`, `H`, `D`, `Q`, `M`, `J`, `Z`, `S`, `W`, `T`, `X`) or by
  kind (`c.resistor(...)`). Analyses and the rest are methods too: `op`, `dc`,
  `ac`, `tran`, `noise`, `tf`, `pz`, `sens`, `four`, `hb`, `sp`, `pss`, `stb`,
  `options`, `save`, `print_`, `ic`, `nodeset`, `measure`, `param`, `model`,
  `func`, `include`, `lib`, `hdl`, `global_`, `subckt`.
* The vocabulary is closed. `c.tran("1n", "1u", errpreset="moderate")` raises
  `TypeError: tran has no 'errpreset'; it has: name, step, stop, ...`. There is
  no escape hatch for raw text.
* `netlist(dialect)` raises `sprack.Unsupported` when the dialect cannot say
  something, with the reason and the dialects that can. `strict=False` returns
  the netlist with the report attached as `.report`.
* Numbers are Python numbers or strings with an SI suffix (`"10n"`, `"4.7k"`,
  `"1meg"`). `"1M"` is refused as ambiguous. Any other string is an
  expression in the canonical spelling: `"2*wmin"`, `"ln(a)**2"`.
* `sprack.translate(text, frm=..., to=...)` and `sprack.read(text, dialect)`
  work on existing netlists.
* `c.code(text, dialect="ngspice")` (on a circuit or a subcircuit) reads
  `text` with that dialect's reader, with no title line, and adds the
  statements: `c.code(".tran 1n 1u\n.save v(out)")` is then written for any
  target like `c.tran(...)` would be. What the reader cannot understand is
  in `netlist()`'s report, so a strict `netlist()` raises on it.
* Every `dialect` argument (`netlist`, `write`, `translate`, `read`, `code`)
  may also be a path to a `.spgrammar` file.

### Shipping it inside another program

`zig build py` also writes the package as a self-contained directory:

    zig-out/python/sprack/__init__.py
    zig-out/python/sprack/_core.abi3.so     # statically linked; CPython 3.10+
    zig-out/python/sprack/pdks/*.json       # the PDK manifests

Copy `zig-out/python/` anywhere and put it on `PYTHONPATH`; nothing is
installed and nothing else is needed. Build it with `-Doptimize=ReleaseSafe`
(about 6 MB) for a release. The only file written outside it is the PDK
translation cache, `~/.cache/sprack` unless `SPRACK_CACHE` or `cache_dir=`
says otherwise. `pip wheel .` packages the same files as a wheel.

### PDKs

`sprack.PDK(name, root=None, corner=None)` finds a PDK's model libraries, lists
the devices they define and makes each one a method of the circuit. A device's
terminals are counted and its parameter names are checked against what the
library declares.

A PDK is described by a small JSON manifest in `python/sprack/pdks/`: the
dialect it is written in, where its entry files are, and which files and
sections make up each corner. Nothing else about a PDK is built in; the device
list comes from reading the libraries. Four manifests ship:

| name | written in | corners | devices found |
|---|---|---|---|
| `sky130A` | ngspice | tt ff ss sf fs ll hh hl lh | 162 subcircuits, 76 model cards |
| `ihp-sg13g2` (`IHP`) | ngspice | tt ss ff sf fs | 35 subcircuits |
| `ASAP7` | HSPICE | tt ff ss | 8 BSIM-CMG models |
| `FreePDK45` | HSPICE | nom ff ss | 8 BSIM4 models |

When the target dialect is the one the PDK ships, the netlist references the
PDK's own files. For any other dialect the whole library is translated once
into `~/.cache/sprack` (as `sprack project` does) and referenced from there.
If the library contains something the target cannot say, that is an error like
any other, reported with file and line; `strict=False` accepts the copy and
puts those errors in the netlist's report.

Pass `manifest=` to use a PDK that has no manifest here.

## What was run

* `zig build test`: 51 tests, among them the 64 translations of one circuit
  between the eight dialects with a read-back comparison (into CDL, the
  sources and analyses are each an `unsupported` error and the rest reads
  back the same), 20,000 randomly
  damaged netlists through every reader and writer, and a project with
  includes.
* `python/test_sprack.py`: 11 tests, 4 of them against the four PDKs' real
  model libraries.
* The four PDKs, whole libraries translated:

  | PDK, all corners | files | to ngspice | to HSPICE | to Xyce | to Spectre | to VACASK |
  |---|---|---|---|---|---|---|
  | sky130 (ngspice) | 280 | 0 errors | 2 | 2 | 8 | 4,303 |
  | IHP SG13G2 (ngspice) | 31 | 0 | 0 | 53 | 214 | 276 |
  | ASAP7 (HSPICE) | 3 | 24 | 0 | 0 | 0 | 24 |
  | FreePDK45 (HSPICE) | 27 | 0 | 0 | 0 | 0 | 24 |

  Every error names a file and a line. They are: two lines in the sky130
  repository that are not ngspice syntax; `pwr()`, `gauss()` and `agauss()`,
  which Spectre does not have; conditional blocks, which Xyce does not have
  and the Spectre grammar here cannot write; Verilog-A models in Xyce;
  BSIM-CMG, which ngspice has only as a Verilog-A model; and, for VACASK,
  library sections and the BSIM model families, which its grammar does not
  cover. sky130 takes 3 to 4 seconds per target.
* The VAMS Conformance Suite (969 decks): 9,670 translations, no crash, no
  difference the report does not explain; every deck is unchanged in meaning
  when written back in its own dialect. Read as ngspice, 99.8% of statements
  and 588 of 965 decks are understood completely (many decks are written in a
  wider dialect than ngspice).
* A 117 MiB netlist translates in 14 seconds using 2.0 GiB.

No simulator was available where this was developed, so no translated netlist
has been simulated. The VACASK manual could not be consulted; that grammar is
written from the project's README, slides and four upstream decks, and its
unconfirmed lines are marked `assumed`.

## The .spgrammar format

A grammar file is a list of directives. `#` starts a comment. Kinds and slots
are the canonical vocabulary in `src/schema.zig`; naming anything else is a
compile error with the file and line.

### lexer

    lexer
      case      insensitive            # or: sensitive
      title     yes                    # first line is a title; optional prefix: yes "// "
      comment   line "*"               # whole-line comments
      comment   tail "$" ";"           # trailing comments
      comment   block "/*" "*/"
      continue  lead "+"               # continuation marker at the start of the next line
      continue  trail "\"              # or at the end of this one
      parens    space                  # ( ) , are blanks; or: token
      expr      "{" "}"                # expression delimiters, may repeat
      expr      bare                   # expressions need no delimiters (Spectre)
      expr      after-equals           # undelimited after "=" up to the next blank
      values    strict                 # or: idents (a bare name may be a value)
      scale     meg=6 k=3 m=-3 u=-6    # suffix = power of ten; longest match wins
      readscale _=0 %=-2               # accepted when reading, never written
      oddscale  mil=25.4e-6            # multipliers that are not powers of ten
      units     ignore                 # letters after a number; or: after-scale
      end       ".end"
    end

### Statements

    rule  tran = ".tran" step stop [ start [maxstep] ] [ skip_dc:"uic"=yes ]
    read  include = ".inc" path        # this form is only read
    write save = ".probe" signals+     # this form is only written

    define wave = ( wave:"pulse" ... | wave:"pwl" ~"(" pwl+ ~")" )
    rule  vsource = name~"V" pos neg [ <wave> ]   # a define, used by name

    block subckt
      open   ".subckt" name ports* ( {...params} | "params:" {...params} )
      inner  "parameters" {...params}  # lines inside that belong to the header
      close  ".ends" [name]
    end

    header   ... end                   # lines at the top of every file
    preamble ... end                   # lines at the top of the top netlist only
    needs resistor ... end             # lines written once if the kind is used
    wrap "control" "endc" : op dc tran # these kinds are collected into one block
    raw ".control" ".endc"             # kept verbatim, never translated

A `define` names a pattern fragment; `<name>` in a later rule, block line or
define stands for it. It is parsed where it is used, so its slot names are
those of the using rule's kind (`vsource` and `isource` share one `wave`).

Rules are tried in file order when reading. When writing, the rule that loses
least is chosen and, among equals, the one that keeps the instance's name. A
`control` kind (options, save, ...) may be written as several statements when
no single rule holds everything, which is how `.options timeint ...` and
`.options device ...` come from one set of options.

### Patterns

| form | meaning |
|---|---|
| `"lit"` | a literal word |
| `~"("` | a literal glued to its neighbours when written (`v(out)`) |
| `slot` | one value into the slot; `slot*` zero or more; `slot+` one or more |
| `slot~"R"` | the name must start with R; added, with a note, when writing |
| `slot?default` | written when the slot is empty; `$other` and `$#` expand |
| `slot:"lit"=atom` | the literal stands for a value of an atom slot; a trailing `?` writes it even when the slot is unset |
| `slot...` | the rest of the line as text, or as one expression for a value slot |
| `-slot` | when writing, deliberately not written (a `caveat` says why) |
| `_` | any one word |
| `[ ... ]` | optional |
| `( a \| b )` | alternatives |
| `( ... )*` `( ... )+` | the group repeated, zero or more / one or more times. Every slot in it is a list slot, written without `*`; each pass takes the next item of each (`( "f" freqs "h" harms )*` writes `f 1k h 3 f 2k h 5`). A separator may be glued on: `( ... )*","`, or `( ... )*~","` to write it tight. Groups do not nest, and hold no `{ }` or `...` |
| `<name>` | the pattern of a `define`, as if written here |
| `/` | the statement continues on the next line |
| `{ k=slot k="slot" k=[slot] k==lit k=slot! k=p@s:a v(*)=slot ...rest }` | `key=value` pairs in any order: plain, quoted, vector, fixed, required, tagged, `v(node)=value`, and everything else. `...rest?` also takes bare flags |

### Meaning that is not syntax

    implied noise ref = 0              # what the dialect assumes when it says nothing
    enum options method : trap=trap gear=gear2      # canonical = this dialect's word
    move options.method -> tran.method # this dialect says it on another statement
    merge ac -> noise                  # read: noise takes what it lacks from the ac
                                       # before it, and absorbs it if only comments
                                       # stand between them
    caveat tran skip_dc : UIC skips ... # a warning attached to a slot when used
    no pz : Xyce has no pole-zero analysis          # the simulator lacks it, and why

    signals                            # how recordable things are written
      v = "v(%)"
      i = "%:p"
    end
    functions                          # canonical name = spellings here
      same abs sqrt exp
      ln = log
    end
    variables  temper = temp  end
    operators  pow "**" "^"   end
    models
      bsim4 n = nmos level=14 | nmos level=54     # first spelling is written
    end

Expressions are translated token by token: numbers, function names, simulator
variables and the two operators that differ (`**`/`^` for power, `^` for
exclusive-or in Spectre). Spacing, parentheses and operand order stay as
written. A function with no spelling in the target is an error naming the
dialects that have it; so is one that nothing defines.

## Report codes

| code | severity | meaning |
|---|---|---|
| `untranslated` | error | no rule of the source grammar understood the line |
| `unsupported` | error | the target has no statement, model family, function or operator for it |
| `loss` | error | one value of a statement has no place in the target form |
| `invalid` | error or warning | the input is wrong or cannot be right in the target |
| `synthesized` | warning | the target needs a value the source did not give; one was written |
| `caveat` | warning | written, but the two simulators do not mean quite the same |
| `ambiguous` | warning | the same text means different things in the two dialects |
| `rename` | info | a name got the device letter the target needs |
| `oneway` | info | written in a form the target's own grammar does not read back |
| `cosmetic` | info | something without meaning was not written (an analysis label) |

## Layout

    grammars/*.spgrammar   the eight dialects
    src/schema.zig         canonical kinds, slots, model families, functions
    src/grammar.zig        the .spgrammar compiler (at compile time and at run time)
    src/lexer.zig          lines, tokens, exact numbers
    src/reader.zig         pattern matcher: text to statements
    src/writer.zig         patterns in reverse: statements to text
    src/expr.zig           expressions
    src/ir.zig             statements, values, reports, circuit comparison
    src/json.zig           the IR as JSON
    src/project.zig        include following, shared declarations, catalogue
    src/main.zig           the command
    src/pyext.zig          the CPython extension
    src/capi.zig           a C ABI for other hosts
    python/sprack/         the Python package and the PDK manifests
    tools/                 corpus audit scripts

## Known limits

* `sprack caps` shows every kind per dialect. A `-` there is a statement the
  simulator has but its grammar here has no rule for; it is an error when
  used. Most are in VACASK (controlled sources, coupling, transmission lines,
  libraries, initial conditions), where the syntax could not be confirmed, and
  in Spectre (user functions, conditional blocks, `tf`, `pz`, `sens`, `four`,
  `hb`).
* HSPICE noise is written as `.AC` plus `.NOISE`. A `.NOISE` read takes its
  sweep from the `.AC` before it; a `.NOISE` with an output-interval number
  after the source is not read. Nested DC sweeps have no Spectre form here. Parameter sweeps (`.dc` of
  a parameter, `.step`, `.alter`, `.data`) are not in the vocabulary;
  temperature sweeps are.
* Parameters of model cards are copied by name, with a warning: the simulators
  ship different versions of the same model.
* The whole netlist is held in memory, at about 17 times its size.
