# Using SPRack with any simulator

A simulator is a dialect to SPRack, and a dialect is one `.spgrammar` file.
Wherever a dialect is named, on the command line (`--from`, `--to`) or in
Python (`netlist`, `write`, `check`, `translate`, `read`, `code`,
`to_python`), you give either a built-in name or the path of a grammar file.

## The built-in dialects

```console
$ sprack dialects
cdl
cktimg
espice
hspice
ltspice
ngspice
spectre
vacask
verilog
xyce
```

| name | simulator | notes |
|---|---|---|
| `ngspice` | ngspice | checked in ngspice itself: translations are loaded and their results compared |
| `xyce` | Xyce | checked in Xyce itself, the same way |
| `vacask` | VACASK | checked against its manual and parser, and in VACASK itself |
| `spectre` | Spectre's own language | checked by loading translations in the simulator; a `simulator lang=spice` section is read as HSPICE |
| `hspice` | HSPICE | checked by loading translations in the simulator |
| `ltspice` | LTspice | checked on LTspice 26.0.2 in batch mode, on decks written for the check |
| `cdl` | CDL, the netlist of layout-versus-schematic checks | connectivity only: every source, analysis and control is an error that says so; no tool was run, and unsettled lines are marked `assumed` |
| `cktimg` | the netlist cktImg draws schematics from | ngspice without analyses, outputs or options (left out with a note) and without the devices cktImg refuses; derived from ngspice (`grammars/cktimg.derive`) |
| `espice` | ESPice | ngspice with Verilog-A loaded by `.hdl`, `m` written `mfactor`, and digital Verilog as N cards with `.verilog`; derived from ngspice, from Schemify's spec; not run |
| `verilog` | structural Verilog | written, never read: one module a subcircuit and one for the top level, ports by name, leaves `verilog` instances (see below); other devices are errors, sources and analyses notes |

The header of each file in `grammars/` says what it was written from, and
the [verification log](verification.md) records what was measured.

Any pair works the same way. On the command line, with the report on
standard error:

```console
$ sprack translate --from ngspice --to xyce rc.sp -o rc.cir
warning[caveat]: line 6: tran.step: the first .TRAN number only sets the initial step in Xyce
```

In Python it is `c.netlist("xyce")` on a circuit, or `sprack.translate(text,
frm="ngspice", to="xyce")` on text.

## What each simulator can say

`sprack caps` prints every statement kind against every built-in dialect.
A few of its rows:

```console
$ sprack caps | grep -E '^( |resistor|diode|ic |pz|hb|montecarlo)'
            cdl      hspice   ltspice  ngspice  spectre  vacask   xyce
resistor    yes      yes      yes      yes      yes      yes      yes
diode       yes      yes      yes      yes      inst     inst     yes
ic          none     yes      yes      yes      yes      param    yes
pz          none     yes      none     yes      yes      none     none
hb          none     yes      none     none     yes      yes      yes
montecarlo  none     yes      none     none     yes      none     yes
```

| mark | meaning |
|---|---|
| `yes` | the dialect has its own statement for the kind |
| `inst` | written as a generic instance of its model (Spectre and VACASK name a device by its model, not by a letter) |
| `param` | written as a parameter of another statement (VACASK takes initial conditions on the analysis) |
| `none` | the simulator has no such thing; using it is an error that says why |
| `-` | the grammar has no rule for it; using it is an error naming the dialects that have one |

No built-in dialect has a `-`; a test keeps it so. A grammar you are still
writing will have them (see [Adding a simulator](adding-a-simulator.md)).

In Python, `sprack.can_write(kind, dialect)` and `sprack.why_not(kind,
dialect)` answer the same question for one kind.

## Reading the report

Every translation has a report. On the command line it goes to standard
error, one entry per line; in Python it is the `.report` of the netlist.

```text
error[unsupported]: line 2: analysis 'pz' cannot be written for xyce: Xyce has no pole-zero analysis. Dialects that define it: hspice, ngspice, spectre
```

An entry is `severity[code]: line N: message`. The line is the line of the
source netlist (in `project`, the entry starts with the file). An **error**
means the output does not say everything the input said; the exit status is
then 1 and `netlist()` raises `Unsupported`. A **warning** means it is
written but you should look. An **info** entry records a change that loses
nothing.

| code | severity | meaning |
|---|---|---|
| `untranslated` | error | no rule of the source grammar understood the line |
| `unsupported` | error | the target has no statement, model family, function or operator for it |
| `loss` | error or warning | one value of a statement has no place in the target form |
| `invalid` | error or warning | the input is wrong or cannot be right in the target |
| `synthesized` | warning | the target needs a value the source did not give; one was written |
| `caveat` | warning | written, but the two simulators do not mean quite the same |
| `ambiguous` | warning | the same text means different things in the two dialects |
| `rename` | info | a name got the device letter the target needs, or a parameter the target's spelling or number |
| `oneway` | info | written in a form the target's own grammar does not read back |
| `cosmetic` | info | something without meaning was not written (an analysis label) |

Text a rule carried verbatim, such as an HSPICE `.meas` form no rule
types, is the source's syntax: between two dialects it is an `invalid`
error, written as it was. Written back in its own dialect, the lines no
rule understood are kept as they were, and one `oneway` note a file says
how many: the simulator itself may still refuse them. A block the target
has not (HSPICE's `.variation`) is one error that counts the statements it
held; each of them is in the output as a comment.

One real entry of each, with what to do about it:

```text
error[untranslated]: line 3: no ngspice rule understood this line; it is in the output only as a comment: .bogus 1
```

The line is not ngspice as the grammar knows it. Fix the source, or, if the
simulator does accept it, the grammar is missing a rule. Written back in its
own dialect such a line is kept as it is and is no error.

```text
error[loss]: line 2: resistor: 'bv_max=5' has no spelling in xyce, whose resistor takes no such instance parameter
```

The statement was written without that value. Decide whether the circuit
needs it.

```text
error[invalid]: line 3: V1, V2 form a loop of voltage sources through 'a' and '0'; Xyce's operating point fails on it
```

The circuit itself cannot run in the target. These come from the topology
check and from names or values the target refuses.

```text
warning[synthesized]: line 6: tran: vacask needs 'maxstep' to behave as ngspice does without it; wrote 1u
warning[caveat]: line 6: tran.step: the first .TRAN number only sets the initial step in Xyce
warning[ambiguous]: line 2: 'rmod' on R1 is a model name in ngspice, but no model of that name is declared here; spectre will read it as a parameter
info[rename]: line 6: renamed 'M1' to 'XM1': mini tells devices apart by the first letter
info[oneway]: line 4: tf: written in a form the spectre grammar does not read back as a tf
info[cosmetic]: line 4: op: ngspice does not name its analyses; the label 'myop' is not written
```

In the output itself, a line that could not be written stands as a comment
starting with `[sprack]`, in the target's comment syntax:

```text
* [sprack] not written: analysis 'pz' has no xyce form
```

## A simulator that is not built in

Give the path of its grammar file. The file is compiled when the command
starts (or on each Python call), by the same compiler that builds the
built-in ones; it takes a fraction of a millisecond.

```console
$ sprack translate --from ngspice --to mini.spgrammar rc.sp
RC low-pass
* a divider with a capacitor
V1 in 0 dc 1 ac 1
R1 in out 1k
C1 out 0 100n ; load
.transient 1m by 1u
.end
```

In Python the same path stands where a name would: `c.netlist("mini.spgrammar")`.

A mistake in the file is reported as `path:line: message` (exit status 2; in
Python a `ValueError`). Two things know only the built-in dialects:
`sprack caps`, and the list of "dialects that define it" in error messages.

[Adding a simulator](adding-a-simulator.md) writes such a file step by step.

## Digital Verilog

A `verilog` statement is an instance of a digital Verilog module: its
nodes one a bit in the module's port order, a bus from its left index
(`d[7]` ... `d[0]`; the caller expands buses), `pins` the port each node
is a bit of, `dirs` its direction (`in`, `out`, `inout`), `master` its
model, `module` the module (else the stem of `file`), `file` the source as
written, `code` the module's text where it is at hand, and the bridge
parameters (`vdd`, `vth`, `rout`, ...).

* ngspice co-simulates it with d_cosim: `AU1 [ ins ] [ outs ] [ inouts ]
  sar_m`, and once a model, after the last statement, `.model sar_m d_cosim
  simulation="sar.vvp"`, the module as Icarus Verilog compiles it
  (`iverilog -o sar.vvp sar.v`; without `file`, the module names it). The
  bridge parameters have no place: a caveat. ngspice cuts a word at `[`
  and `]` on an A line, so a net an A line names, `d[7]`, is `d_7`
  wherever its scope names it (`d_7_` where `d_7` is taken), an info note
  each; nets no A line names keep their brackets.
* espice writes `NU1 <nodes> sar_m vdd=1.8 ...`, then a `.model sar_m sar`
  card a model and a `.verilog "sar.v"` line a source, sorted.
* `verilog` writes it as an instance of its module, by port: `sar U1
  (.clk(clk), .d({\d[7] , ...}))`, and its `code` once after the modules.
* Every other dialect: an error that says it has no Verilog.

## Limits to know

* SPRack translates the netlist, not the models. The parameters of a model
  card are copied by name, with one warning per file, because simulators
  ship different versions of the same model.
* A `.control` block of ngspice is read as a script (steps 1 to 3 of #50):
  each command is a statement of its own. `op`, `dc`, `ac`, `tran`,
  `noise`, `save`, `meas` and `pre_osdi` are typed as the netlist's
  analyses, outputs and loads; every other command (`let`, `print`,
  `wrdata`, `set`, `run`, ...) is a `simctl` line, written back as it was
  for ngspice. Into a dialect without a control script, a script with an
  analysis or output in it becomes the deck's own lines in order; `run`,
  `quit` and `reset` are left out with a note, and every other command is
  `unsupported`, because post-processing in ngspice's vector language has
  no counterpart. A script of commands only is `unsupported` whole.
  `.csparam` is a statement of its own, which only ngspice has.
* The topology check (`invalid` entries about DC paths and source loops)
  runs when translating between two dialects, and only for a netlist that
  has an analysis.
* Memory: `sprack translate` surveys the netlist, then reads and writes one
  top-level statement at a time. Measured peak: 1.5 times the input on a
  111 MiB RC mesh and 1.6 times on 45 MiB of sky130 cells (2.1 times into
  Spectre, whose report alone is a third of the input). A netlist with a
  sweep, an alter, a pole-zero analysis, a model of an unlisted type, a
  statistics block to fold or a change of language is still read whole, at
  7 times its size or more; so are `read`, `write` and the Python package.
