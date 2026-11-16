# Adding a simulator

A simulator SPRack does not know needs one file: a `.spgrammar` that
describes its netlist language. No Zig or Python is written. This page
builds one from nothing for **Mini**, a made-up SPICE-like dialect, and runs
it at every step. The finished file is
[`mini.spgrammar`](examples/mini.spgrammar); the
[reference](grammar-reference.md) has every directive.

A Mini netlist looks like this:

```text
inverter
.set vdd=1.8 wn=1u
.cell inv in out vdd vss wp=2u
M1 out in vss vss nch w={wn} l=0.18u
.endcell inv
V1 vdd 0 dc {vdd}
.transient 12n by 5p cold
.end
```

## 1. Know the vocabulary

A grammar maps the text of a dialect onto SPRack's canonical statements. A
statement has a **kind** (`resistor`, `tran`, `subckt`, ...) and named
**slots**. A rule says which words of a line go into which slots. `sprack
info` lists them:

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

`sprack caps` shows which kinds exist, and the grammars in `grammars/` are
worked examples of every one.

## 2. The lexer block and a first rule

Start the file with the dialect's name and how its text is cut into lines,
words and numbers:

```text
dialect mini

lexer
  case      insensitive
  title     yes
  comment   line "*"
  comment   tail ";"
  continue  lead "+"
  parens    space
  expr      "{" "}"
  values    strict
  scale     meg=6 g=9 k=3 m=-3 u=-6 n=-9 p=-12 f=-15
  units     ignore
  end       ".end"
end
```

Line by line: names ignore case; the first line of a netlist is its title;
`*` starts a comment line and `;` a trailing comment; a line starting with
`+` continues the one before; parentheses and commas count as blanks;
expressions stand in braces; a value must be a number or an expression; the
scale suffixes and their powers of ten; letters after a number are a unit
and are ignored; `.end` ends the netlist.

Then one rule:

```text
rule resistor  = name~"R" pos neg r
```

`rule <kind> = <pattern>`. The pattern is the line, left to right: the
`name` slot, which must start with `R`, then `pos`, `neg` and `r`. That is
enough to translate into Mini. With [`rc.sp`](examples/rc.sp):

```console
$ sprack translate --from ngspice --to mini.spgrammar rc.sp
RC low-pass
* a divider with a capacitor
* [sprack] not written: device 'vsource' has no mini form
R1 in out 1k
* [sprack] not written: device 'capacitor' has no mini form
* [sprack] not written: analysis 'tran' has no mini form
.end
error[unsupported]: line 3: device 'vsource' cannot be written for mini: mini.spgrammar defines no rule for it. Dialects that define it: hspice, ltspice, ngspice, spectre, vacask, xyce
error[unsupported]: line 5: device 'capacitor' cannot be written for mini: mini.spgrammar defines no rule for it. Dialects that define it: cdl, hspice, ltspice, ngspice, spectre, vacask, xyce
error[unsupported]: line 6: analysis 'tran' cannot be written for mini: mini.spgrammar defines no rule for it. Dialects that define it: hspice, ltspice, ngspice, spectre, vacask, xyce
```

The resistor is written. Everything else is an error that names what is
missing: the report is the to-do list.

## 3. More rules, and the audit

```text
rule capacitor = name~"C" pos neg c
rule vsource   = name~"V" pos neg [ "dc" dc ] [ "ac" acmag ]
rule op        = ".dcop"
rule tran      = ".transient" stop "by" step [ skip_dc:"cold"=yes ]
```

* `"dc"` is a literal word; `[ ... ]` is optional. A source is written
  `V1 in 0 dc 1 ac 1`, each part only when its slot has a value.
* Mini writes a transient as `.transient <stop> by <step>`: the slots are in
  Mini's order, and the writer and the reader both follow it.
* `skip_dc:"cold"=yes` means the word `cold` stands for the value `yes` of
  the slot `skip_dc` (SPICE's `uic`).

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

No report, status 0. Now check the grammar against itself. `sprack audit`
translates, reads the result back with the same grammar and compares:

```console
$ sprack audit --from ngspice --to mini.spgrammar rc.sp
rc.sp	4	0	1	0	0	0	0	0	0	0	0	0	0	0	0	
```

The fourth column is `same`. It must be 1: what Mini's rules write, Mini's
rules read back as the same circuit. A 0 with no error counted in the later
columns means a rule writes something it cannot read; fix the rule. (The
[columns](cli.md#audit) are on the command-line page.)

## 4. Blocks

A statement that holds others is a `block`, with a line that opens it and a
line that closes it:

```text
block subckt
  open   ".cell" name ports* {...params}
  close  ".endcell" [name]
end

rule instance  = name~"X" nodes+ master {...params}
rule param     = ".set" {...params}
```

`ports*` takes zero or more words into a list slot, `nodes+` one or more.
`{...params}` takes `key=value` pairs, whatever their names. The `[name]`
after `.endcell` is optional.

[`inv.sp`](examples/inv.sp) has a subcircuit, model cards, MOSFETs and a
function call:

```spice
inverter
.param vdd=1.8 wn=1u
.model nch nmos level=54 vth0=0.42
.model pch pmos level=54 vth0=-0.41
.subckt inv in out vdd vss wp=2u
M1 out in vss vss nch W={wn} L=0.18u
M2 out in vdd vdd pch W={wp} L=0.18u
.ends inv
V1 vdd 0 DC {vdd}
X1 in out vdd 0 inv wp=3u
C1 out 0 20f
R1 out 0 {sqrt(wn)*1e9}
.tran 5p 12n uic
.end
```

```console
$ sprack translate --from ngspice --to mini.spgrammar inv.sp
inverter
.set vdd=1.8 wn=1u
* [sprack] not written: model 'nch'
* [sprack] not written: model 'pch'
.cell inv in out vdd vss wp=2u
XM1 out in vss vss nch w={wn} l=0.18u
XM2 out in vdd vdd pch w={wp} l=0.18u
.endcell inv
V1 vdd 0 dc {vdd}
X1 in out vdd 0 inv wp=3u
C1 out 0 20f
R1 out 0 {sqrt(wn)*1g}
.transient 12n by 5p cold
.end
error[unsupported]: line 3: model 'nch': mini.spgrammar has no spelling for model family 'bsim4 n'. Defined by: hspice, ltspice, ngspice, spectre, vacask, xyce
error[unsupported]: line 4: model 'pch': mini.spgrammar has no spelling for model family 'bsim4 p'. Defined by: hspice, ltspice, ngspice, spectre, vacask, xyce
info[rename]: line 6: renamed 'M1' to 'XM1': mini tells devices apart by the first letter
info[rename]: line 7: renamed 'M2' to 'XM2': mini tells devices apart by the first letter
error[unsupported]: line 12: expression 'sqrt(wn)*1e9': function 'sqrt' has no spelling in mini. Dialects that have it: cdl, hspice, ltspice, ngspice, spectre, vacask, xyce
```

The subcircuit, its instance and the parameters are there. Three things are
left, and the report names each: the model families, the MOSFETs (written
as generic instances of their model, because there is an `instance` rule
but no `mosfet` rule yet), and the function.

## 5. Models

```text
rule model     = ".model" name type {...params?}
rule mosfet    = name~"M" d g s b master {...params}

models
  mos1 n  = nfet level=1
  mos1 p  = pfet level=1
  bsim4 n = nfet level=14
  bsim4 p = pfet level=14
end
```

The `models` table says how this dialect spells each canonical model family:
`bsim4 n` is `nfet level=14` here. The source said `nmos level=54`; ngspice's
own table maps that to `bsim4 n`, and Mini's table maps it out again. The
first spelling on a line is the one written; more, after `|`, are also read.

```console
$ sprack translate --from ngspice --to mini.spgrammar inv.sp
inverter
.set vdd=1.8 wn=1u
.model nch nfet level=14 vth0=0.42
.model pch pfet level=14 vth0=-0.41
.cell inv in out vdd vss wp=2u
M1 out in vss vss nch w={wn} l=0.18u
M2 out in vdd vdd pch w={wp} l=0.18u
.endcell inv
V1 vdd 0 dc {vdd}
X1 in out vdd 0 inv wp=3u
C1 out 0 20f
R1 out 0 {sqrt(wn)*1g}
.transient 12n by 5p cold
.end
error[unsupported]: line 12: expression 'sqrt(wn)*1e9': function 'sqrt' has no spelling in mini. Dialects that have it: cdl, hspice, ltspice, ngspice, spectre, vacask, xyce
warning[caveat]: line 3: model 'nch' (bsim4) and 1 more model cards: ngspice and mini ship different implementations and versions of these models; parameters were copied as written, check them against mini
```

## 6. What the simulator does not have

Where the simulator has no such thing, say so with a reason. The reason is
what the user reads:

```text
no ac  : Mini has no small-signal analysis
no pz  : Mini has no small-signal analysis
no hdl : Mini cannot load Verilog-A
```

With a deck [`ac.sp`](examples/ac.sp) that asks for two analyses Mini lacks:

```spice
t
R1 a 0 1k
.ac dec 10 1 1meg
.noise v(a) V1 dec 10 1 1meg
.end
```

```console
$ sprack translate --from ngspice --to mini.spgrammar ac.sp
t
R1 a 0 1k
* [sprack] not written: analysis 'ac' has no mini form
* [sprack] not written: analysis 'noise' has no mini form
.end
error[unsupported]: line 3: analysis 'ac' cannot be written for mini: Mini has no small-signal analysis. Dialects that define it: hspice, ltspice, ngspice, spectre, vacask, xyce
error[unsupported]: line 4: analysis 'noise' cannot be written for mini: mini.spgrammar defines no rule for it. Dialects that define it: hspice, ltspice, ngspice, spectre, vacask, xyce
```

`ac` has a `no` line and gets its reason. `noise` has neither a rule nor a
`no` line, so the message can only say the grammar is silent. A finished
grammar has a rule or a `no` line for every kind.

## 7. Meaning that is not syntax

```text
functions
  same abs min max sqrt exp
  ln = log
end

operators
  pow "^"
end

caveat tran skip_dc : "cold" starts every node at zero; it does not read initial conditions
differs sqrt : a negative argument gives zero, where other simulators stop with an error
```

* `functions` lists the functions an expression may call: `same` for those
  spelled as in the canonical vocabulary, `ln = log` where this dialect's
  word differs.
* `operators` gives the spelling of the operators that differ between
  dialects (power here).
* `caveat <kind> <slot> : text` attaches a warning to a slot, said whenever
  a translation uses it.
* `differs <function> : text` says a shared function is evaluated
  differently here; it becomes a caveat on each expression that calls it
  in a translation into this dialect.

```console
$ sprack translate --from ngspice --to mini.spgrammar inv.sp -o inv.mini
warning[caveat]: line 12: expression 'sqrt(wn)*1e9': sqrt in mini: a negative argument gives zero, where other simulators stop with an error
warning[caveat]: line 13: tran.skip_dc: "cold" starts every node at zero; it does not read initial conditions
warning[caveat]: line 3: model 'nch' (bsim4) and 1 more model cards: ngspice and mini ship different implementations and versions of these models; parameters were copied as written, check them against mini
$ sprack audit --from ngspice --to mini.spgrammar inv.sp
inv.sp	11	0	1	0	0	0	0	0	3	0	0	0	0	0	0	
```

No errors, three caveats, and `same` is 1.

## 8. The other direction

A `rule` is both the reader and the writer, so the same file reads Mini.
`inv.mini`, written above, goes on to any other dialect:

```console
$ sprack translate --from mini.spgrammar --to spectre inv.mini
// inverter
simulator lang=spectre
global 0
parameters vdd=1.8 wn=1u
model nch bsim4 type=n vth0=0.42
model pch bsim4 type=p vth0=-0.41
subckt inv (in out vdd vss)
parameters wp=2u
M1 (out in vss vss) nch w=wn l=0.18u
M2 (out in vdd vdd) pch w=wp l=0.18u
ends inv
V1 (vdd 0) vsource dc=vdd
X1 (in out vdd 0) inv wp=3u
C1 (out 0) capacitor c=20f
R1 (out 0) resistor r=sqrt(wn)*1G
tran1 tran step=5p stop=12n skipdc=yes
warning[caveat]: line 13: tran.skip_dc: skipdc=yes skips the DC solve and takes initial conditions from ic statements; SPICE UIC also honours ic= on devices
warning[caveat]: line 3: model 'nch' (bsim4) and 1 more model cards: mini and spectre ship different implementations and versions of these models; parameters were copied as written, check them against spectre
```

Where a form should only be read or only be written, use `read` or `write`
in place of `rule`.

## 9. Mistakes in the grammar

A grammar that does not compile is reported with its path and line, and the
command exits with status 2. Here the capacitor rule is made to name a slot
`cap`:

```console
$ sed 's/pos neg c$/pos neg cap/' mini.spgrammar > typo.spgrammar
$ sprack translate --from ngspice --to typo.spgrammar rc.sp
typo.spgrammar:20: unknown slot 'cap' for kind 'capacitor' (known: name pos neg c master params) in pattern `name~"C" pos neg cap`
```

## 10. Where the file goes

**Used by path, it works at once.** Keep the file anywhere and name it where
a dialect is named, on the command line and in Python. Nothing is rebuilt.

**Dropped into `grammars/`, it becomes built in.** `build.zig` takes every
`grammars/*.spgrammar` file; the build has no list to edit. After `zig build`
the name is in `sprack dialects` and `sprack caps`, and after `zig build py`
in the Python package's `sprack.DIALECTS`.

**The tests do have a list.** `src/tests.zig` names the dialects it
translates between: the array `dialects` at its top, and the function
`sample`, which returns a sample deck for each. So after adding a grammar,
`zig build test` fails until you add the new name to `dialects` and a deck
for it to `sample`. The next section says what that buys.

## Testing a new dialect

While the grammar is a file of your own, the checks are the ones above:
`sprack translate` on real decks until the report has nothing you did not
expect, and `sprack audit` with `same` at 1, in both directions:

```console
$ sprack audit --from mini.spgrammar --to ngspice inv.mini
inv.mini	11	0	1	0	0	0	0	0	3	0	0	0	0	0	0	
```

`tools/corpus_audit.py` runs the audit over a directory of decks.

Once the file is in `grammars/`, `zig build test` covers it. Some tests go
over every grammar compiled in, with nothing to add: the grammar file
compiled at run time is the grammar compiled into the binary; every kind has
a rule, a place or a `no` line with a reason (so `sprack caps` shows no
`-`); every `no` line gives its reason in the error. The tests that
translate between every pair of dialects, and the damaged-input tests, go
over that list of names and sample decks. The first test (`all grammars
compiled`) is the one that fails until the new name is in it, because it
compares the list with the number of grammars compiled in.

Last, load what SPRack writes in the simulator itself. `tools/parse_check.py`
does that for ngspice, Xyce and VACASK; see [How it is tested](testing.md).
