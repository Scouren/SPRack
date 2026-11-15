# Command line

```text
sprack translate --from <dialect> --to <dialect> [file] [-o out]
sprack project   --from <dialect> --to <dialect> --out <dir> <file>...
sprack catalog   --from <dialect> <file>...
sprack read      --from <dialect> [file]
sprack write     --to <dialect> [file.json] [-o out]
sprack audit     --from <dialect> --to <dialect> <file>
sprack dialects | caps | info
```

A `<dialect>` is a built-in name (`sprack dialects`) or a path ending in
`.spgrammar`. `translate`, `read`, `write` and `audit` read standard input
when no file is given. `sprack` with no arguments prints the usage.

## Exit status

| status | meaning |
|---|---|
| 0 | nothing was lost: the report has no error (it may have warnings) |
| 1 | the report has an error: something in the input has no form in the target, so the output does not say everything the input said |
| 2 | the command line is wrong, a file cannot be read, or a grammar file has a mistake; nothing was translated |

The examples below use this deck, [`rc.sp`](examples/rc.sp):

```spice
RC low-pass
* a divider with a capacitor
V1 in 0 DC 1 AC 1
R1 in out 1k
C1 out 0 100n $ load
.tran 1u 1m
.end
```

## translate

One netlist. The result goes to standard output or to `-o`, the report to
standard error.

```console
$ sprack translate --from ngspice --to hspice < rc.sp
RC low-pass
.option tnom=27
* a divider with a capacitor
V1 in 0 dc 1 ac 1
R1 in out 1k
C1 out 0 100n $ load
.tran 1u 1m
.end
warning[caveat]: options: ngspice assumes other defaults for tnom than hspice does; they are written out
$ echo $?
0
```

When the target cannot say something, the output is still written, the line
is left in it as a comment, the report has an error and the status is 1:

```console
$ sprack translate --from ngspice --to cdl rc.sp
* RC low-pass
* a divider with a capacitor
* [sprack] not written: device 'vsource' has no cdl form
R1 in out 1k
C1 out 0 100n $ load
* [sprack] not written: analysis 'tran' has no cdl form
.end
error[unsupported]: line 3: device 'vsource' cannot be written for cdl: CDL describes connectivity for LVS; it has no sources. Dialects that define it: espice, hspice, ltspice, ngspice, spectre, vacask, xyce
error[unsupported]: line 6: analysis 'tran' cannot be written for cdl: CDL is a netlist, not a simulation deck; it has no analyses. Dialects that define it: espice, hspice, ltspice, ngspice, spectre, vacask, xyce
$ echo $?
1
```

[Report codes](simulators.md#reading-the-report) explains each kind of entry.

## audit

Translates, reads the result back with the target's reader and compares the
two circuits. It prints one line of tab-separated columns:

```console
$ sprack audit --from ngspice --to spectre rc.sp
rc.sp	4	0	1	0	0	0	0	0	0	0	0	0	0	0	0	
$ sprack audit --from ngspice --to cdl rc.sp
rc.sp	4	0	0	2	0	2	0	0	0	0	0	0	0	0	0	
```

| column | meaning |
|---|---|
| 1 `file` | the file (`-` for standard input) |
| 2 `stmts` | statements read |
| 3 `opaque` | lines no rule of the source grammar understood |
| 4 `same` | 1 when the circuit read back is the circuit read |
| 5 `errors` | errors in the report |
| 6 to 15 | entries per report code: `untranslated`, `unsupported`, `loss`, `synthesized`, `caveat`, `rename`, `cosmetic`, `invalid`, `ambiguous`, `oneway` |
| 16 `reread_opaque` | lines of the output the target's reader did not understand |
| 17 `keys` | the first words of the lines counted in column 3, with counts (`.bogus:1`) |

`same` may be 0 only when the report explains it, as in the second run (two
`unsupported` errors). The status of `audit` is 0 either way; the verdict is
in the columns. `tools/corpus_audit.py` runs it over a directory of decks.

## read and write

`read` prints the netlist as JSON, the statements of the canonical
vocabulary; `write` makes a netlist from that JSON.

```console
$ sprack read --from ngspice rc.sp > rc.json
$ cat rc.json
{"title":"RC low-pass","dialect":"ngspice","stmts":[{"kind":"comment","line":2,"raw":"a divider with a capacitor"},
{"kind":"vsource","line":3,"name":"V1","pos":"in","neg":"0","dc":"1","acmag":"1"},
{"kind":"resistor","line":4,"name":"R1","pos":"in","neg":"out","r":"1e3"},
{"kind":"capacitor","line":5,"tail":"load","name":"C1","pos":"out","neg":"0","c":"100e-9"},
{"kind":"tran","line":6,"step":"1e-6","stop":"1e-3"}]}
$ sprack write --to xyce rc.json
RC low-pass
* a divider with a capacitor
V1 in 0 dc 1 ac 1
R1 in out 1k
C1 out 0 100n ; load
.tran 1u 1m
.end
warning[caveat]: line 6: tran.step: the first .TRAN number only sets the initial step in Xyce
```

## project

A file and everything it includes, as a translated copy of the tree. This is
how a model library is translated. It follows every `.include` and `.lib`,
rewrites the include lines as relative paths, and copies the Verilog-A files
that `.hdl` lines name. `--out <dir>` is required.

Given [`tree/top.sp`](examples/tree/top.sp), which includes `inc/sub.sp` and
the section `tt` of `$PDK/corners.lib`:

```console
$ sprack project --from ngspice --to spectre --section tt -D PDK=pdk --out out-spectre tree/top.sp
tree/pdk/corners.lib: info[cosmetic]: section 'ff' not followed: it is not among the sections asked for, so the files it includes are not translated
3 files, 0 errors, 0 warnings
$ cat out-spectre/top.sp
// top
simulator lang=spectre insensitive=yes
global 0
include "inc/sub.sp"
include "pdk/corners.lib" section=tt
X1 (a 0) rdiv
op1 dc
```

| option | meaning |
|---|---|
| `--out <dir>` | where the translated tree is written |
| `--lib` | the files named are libraries themselves, with no title line, as in a PDK |
| `--section NAME` | follow only this library section (a corner) and the sections it names; repeatable. The log lists each section not followed |
| `-D NAME=VALUE` | a value for `$NAME` in include paths; without it the environment is used |

Every log line names a file, and a line where there is one. The last line
counts files, errors and warnings. An include that cannot be opened is an
error, and the status is 1:

```console
$ sprack project --from ngspice --to xyce --out out-xyce tree/top.sp
tree/$PDK/corners.lib: error[invalid]: cannot open this file; it is included by the project
2 files, 1 error, 0 warnings, 1 included file not found
```

`project` reads the set twice: once to learn which models, subcircuits and
functions each file declares, once with that knowledge. That is what lets a
Spectre instance line be recognised as a MOSFET when its model is declared
three includes away.

## catalog

A JSON list of every subcircuit and model the files and their includes
define. The files named are read as libraries (as with `--lib`); `-D` and
`--section` work as for `project`. Paths in the output are absolute; `…`
stands here for the directory the command was run in.

```console
$ sprack catalog --from ngspice tree/inc/sub.sp
{"devices":[
{"name":"rdiv","file":"…/tree/inc/sub.sp","section":"","kind":"subckt","ports":["a","b"],"params":{}}
],"files":["…/tree/inc/sub.sp"],"root":"…/tree/inc","errors":0,"warnings":0,"missing":0}
1 file, 0 errors, 0 warnings
```

A subcircuit entry has its `ports` and its `params` with their defaults; a
model entry has `device`, `family` and `polarity` instead. This is the list
[`sprack.PDK`](pdks.md) builds its device methods from.

## dialects, caps, info

```console
$ sprack dialects
cdl
espice
hspice
ltspice
ngspice
spectre
vacask
xyce
```

`sprack caps` prints a table of every statement kind against every built-in
dialect: whether the dialect has a statement for it. See
[Using SPRack with any simulator](simulators.md#what-each-simulator-can-say).

`sprack info` prints the schema as JSON: the dialects, every kind with its
class, its slots, the dialects that can write it and the reason where one
cannot, and the functions and variables an expression may use. For example,
the slots of `tran`:

```console
$ sprack info | jq -r '.kinds.tran.slots[] | "\(.name)\t\(.type)\(if .list then " list" else "" end)"'
name	name
step	value
stop	value
start	value
maxstep	value
skip_dc	atom
method	atom
params	params
ic	params
nodeset	params
segments	value list
```

## A wrong command line

```console
$ sprack translate --from pspice --to xyce rc.sp
unknown dialect 'pspice'. Built in: cdl espice hspice ltspice ngspice spectre vacask xyce; or a path to a .spgrammar file
$ echo $?
2
```
