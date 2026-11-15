# The .spgrammar reference

One `.spgrammar` file describes one dialect: how its text is cut into
tokens, the form of each statement, and what the dialect means where its
syntax does not say. The reader and the writer for the dialect are both
generated from it. [Adding a simulator](adding-a-simulator.md) builds a file
step by step; this page lists every directive.

A grammar file is a list of directives. `#` starts a comment. The first
directive is `dialect <name>`, the name the dialect is known by. Kinds and
slots are the canonical vocabulary in `src/schema.zig`, which `sprack info`
prints; naming anything else is a compile error with the file and line.

## lexer

How the text is cut into lines, words and numbers. Each line is optional.

```text
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
  quotes    '"' expr-in-values except rlgcfile   # "..." in a value slot is an
                                   # expression, in a path or name slot a string;
                                   # or: quotes '"' string (the default)
  values    strict                 # or: idents (a bare name may be a value)
  scale     meg=6 k=3 m=-3 u=-6    # suffix = power of ten; longest match wins
  readscale _=0 %=-2               # accepted when reading, never written
  oddscale  mil=25.4e-6            # multipliers that are not powers of ten
  units     ignore                 # letters after a number; or: after-scale
  numbers   strict                 # a malformed number (3.3.0) is refused
  vectors   comma                  # `[a, b]` written with commas; or: space
  end       ".end"
end
```

## Statements

One directive per form a statement can take. `rule` is read and written,
`read` and `write` one way only; a `block` is a statement that holds others.

```text
rule  tran = ".tran" step stop [ start [maxstep] ] [ skip_dc:"uic"=yes ]
write bjt[hicum2] = ...            # only for an instance whose model is of that family
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
header folded ... end              # instead, when the source folds case
preamble ... end                   # lines at the top of the top netlist only
preamble unless global ... end     # unless a statement of that kind says it
needs resistor ... end             # lines written once if the kind is used
wrap "control" "endc" : op dc tran # these kinds are collected into one block
raw ".control" ".endc"             # kept verbatim, never translated
raw "embed" ">>>FILE" : reason     # and why no other dialect can take it
```

A `define` names a pattern fragment; `<name>` in a later rule, block line or
define stands for it. It is parsed where it is used, so its slot names are
those of the using rule's kind (`vsource` and `isource` share one `wave`).

Rules are tried in file order when reading. When writing, the rule that loses
least is chosen and, among equals, the one that keeps the instance's name. A
`control` kind (options, save, ...) may be written as several statements when
no single rule holds everything, which is how `.options timeint ...` and
`.options device ...` come from one set of options.

## Patterns

What may stand on the right of a rule, and on the lines of a block.

| form | meaning |
|---|---|
| `"lit"` | a literal word |
| `~"("` | a literal glued to its neighbours when written (`v(out)`) |
| `slot` | one value into the slot; `slot*` zero or more; `slot+` one or more; `slot#1` exactly one item of a list slot; `slot#n` as many items as slot `n` holds |
| `slot~"R"` | the name must start with R; added, with a note, when writing |
| `path!` | a path written without quotes when it has no blank |
| `slot?default` | written when the slot is empty; `$other` and `$#` expand, and `$+list` is the number of items in a list slot |
| `slot:"lit"=atom` | the literal stands for a value of an atom slot (or a number in a value slot); a trailing `?` writes it even when the slot is unset |
| `slot...` | the rest of the line as text, or as one expression for a value slot |
| `-slot` | when writing, deliberately not written (a `caveat` says why) |
| `_` | any one word |
| `[ ... ]` | optional |
| `( a \| b )` | alternatives |
| `( ... )*` `( ... )+` `( ... )#n` | the group repeated, zero or more / one or more / exactly slot `n` times. Every slot in it is a list slot, written without `*`; each pass takes the next item of each (`( "f" freqs "h" harms )*` writes `f 1k h 3 f 2k h 5`). A separator may be glued on: `( ... )*","`, or `( ... )*~","` to write it tight. Groups do not nest, and hold no `{ }` or `...` |
| `<name>` | the pattern of a `define`, as if written here |
| `/` | the statement continues on the next line |
| `{ k=slot k="slot" k=[slot] k==lit k=slot! k=slot?$other k=p@s:a v(*)=slot ...rest }` | `key=value` pairs in any order: plain, quoted, vector, fixed, required, defaulted (written from another dialect when the slot is empty, a `synthesized` warning), tagged, `v(node)=value` (`v(*)=slot+` also reads bare `node value` pairs), and everything else. `k=slot+` writes another dialect's slot once more under this key (`reli=reltol+`: HSPICE says one reltol twice); read, it takes only a repeat of the value already read, and otherwise leaves the key to later entries. Two slots one key spells (`gmin=gmin gmin=gmindc`) are written once, a loss when their values differ. `...rest?` also takes bare flags; `k==lit!@s:a` is a fixed pair that stands for `s` = `a` |

## Meaning that is not syntax

What a dialect assumes, lacks or evaluates differently, and the tables that
map its spellings to the canonical ones.

```text
implied noise ref = 0              # what the dialect assumes when it says nothing
implied options temp = $tnom       # for options, over the whole netlist; a
                                   # translation states the ones the target
                                   # assumes otherwise (HSPICE's TNOM 25)
implied vsource td1 = 0 wave=exp   # only where that slot holds that word
enum options method : trap=trap gear=gear2      # canonical = this dialect's word
move options.method -> tran.method # this dialect says it on another statement
move options.delmax -> tran.maxstep oneway   # only when writing
merge ac -> noise                  # read: noise takes what it lacks from the ac
                                   # before it, and absorbs it if only comments
                                   # stand between them
caveat tran skip_dc : UIC skips ... # a warning attached to a slot when used
caveat hdl path=*.osdi : ...       # only where the value ends so
caveat read options gmin : ...     # said when a netlist of this dialect is
                                   # translated out, not into it
inert options post : ...           # a parameter that changes no result here:
                                   # left out crossing out, with an info note
threshold vswitch : von voff = vt vh   # switch levels: on = vt + vh, off = vt - vh
convert pss : fund = 1 / fund      # a value this dialect says differently:
convert vsource wave=exp : td2 = td2 - td1    # a = b, a = a +/- c, a = 1 / a;
                                   # inverted when reading
invalid vsource rise=0 wave=pulse : ...  # left out (or 0) it means something
                                   # else here: an error crossing in or out
default vsource rise=0 wave=pulse : tran.step  # left out (or 0) by a dialect
                                   # that means its default by that: written
                                   # out from the netlist's first .tran
default vsource td2 wave=exp : td1 + tran.step  # counted from a slot of the
                                   # statement itself
default vsource td1 wave=exp : tran.step from ngspice espice  # only for a
                                   # statement of a dialect measured to mean
                                   # that (an error where the netlist has no
                                   # .tran); from any other, an `ambiguous`
                                   # warning unless an `invalid` line speaks
unique param : ...                 # a parameter defined twice in one scope is
                                   # refused here: an error
unique master : ...                # a name both a model and a subcircuit define
                                   # (in any file of a project): the model and
                                   # the devices that use it by their SPICE
                                   # letter are renamed (nch__m), an info
hoist param from ngspice ltspice   # an instance sets only what a subcircuit's
                                   # header declares here: a parameter
                                   # statement inside one, read from a dialect
                                   # measured to take it per instance, is
                                   # written on the header (an `oneway` info,
                                   # once a file); from any other dialect it
                                   # stays, an `ambiguous` warning
reserved vt temp : ...             # parameter names the simulator refuses
requires dc-path error : ...       # a topology the simulator cannot solve, and
                                   # whether it is an error or a warning here:
                                   # dc-path (nodes no DC path reaches ground),
                                   # cutset (such nodes fed by a current
                                   # source; without it, dc-path with any
                                   # analysis), no-vloop, no-vlloop, no-lloop (a loop of
                                   # voltage sources, of sources and inductors,
                                   # of inductors). An `invalid` entry naming
                                   # the nodes or elements; src/topology.zig
requires dc-path error [op dc ac] : ...  # only in a netlist with one of these
                                   # analyses (`tran`: one without UIC); with
                                   # no list, with any analysis
spread montecarlo                  # a block written by adding its rule to each
                                   # analysis of its body (`sweep monte=30`)
spread step "sweep"                # the same; only the rules starting with
                                   # the word are endings (`.temp` is not)
rerun alter                        # analyses run where they stand: written
                                   # again after each statement of the kind
switch "simulator lang=spice" -> hspice   # from such a line on, read with
                                   # another grammar, until the next switch
noparam jfet level=2 error : ...   # a model parameter (with that value) the
                                   # family's model here refuses: not written, a loss;
                                   # error (the card is another model now, said card
                                   # by card) or warning (the same model, once a file)
computes resistor narrow short : R = RSH (L - 2 SHORT) / (W - 2 NARROW)
                                   # how the family's model here computes with
                                   # these parameters, as measured: a card with
                                   # one of them crossing to a dialect that
                                   # says another formula is copied with a
                                   # `caveat` stating both
no pz : Xyce has no pole-zero analysis          # the simulator lacks it, and why
differs pow : the exponent is cut to an integer  # a shared function or operator
                                                 # evaluated differently: a caveat
                                                 # (`negpow`: a minus after an
                                                 # operator, before `**`;
                                                 # `minuspow`: any minus before
                                                 # `**`; `andor`: `&&` and `||`)

signals                            # how recordable things are written
  v = "v(%)"
  i = "%:p"
end
functions                          # canonical name = spellings here
  same abs sqrt exp
  ln = log
end
variables  temper = temp  end
operators                          # pow, xor; ternary "?" if it has c ? a : b
  pow "**" "^"
end
params resistor                    # the instance parameters a device takes,
  same ac dtemp l m>0 w            # by canonical (ngspice) name; m>0: refused
  noisy = noise                    # at zero or less; canonical = spelling
end
models
  bsim4 n = nmos level=14 | nmos level=54     # first spelling is written
end
```

A device's instance parameters that cross into a dialect with a `params`
table for its kind are renamed to that dialect's spelling (an info
`rename`); one its device does not take is a `loss` error and is not
written. A kind without a table is not checked, and neither is what a table
ending in `same ...` leaves out: such a table only renames.

Expressions are translated token by token: numbers, function names, simulator
variables and the operators that differ (`**`/`^` for power, `^` for
exclusive-or in Spectre, `!=` there with blanks: `ne " != "`). Spacing, parentheses and operand order stay as
written. A function with no spelling in the target is an error naming the
dialects that have it; so is one that nothing defines. The one
restructuring is a choice: `c ? a : b` is written `if(c, a, b)` for a
dialect that has only `if()` (LTspice), and the other way round for one that
has only `?:` (HSPICE, Spectre; ngspice's `ternary_fcn` is `if`).

A conditional block crossing into a dialect with `no cond_if` that has
either form of choice is written without the block when every branch holds
the same statements, one for one: the same kind, name, nodes and model and
the same parameter names, differing only in the values of devices, each a
number or an expression. Such a value is written as a choice between the
branches' values by their conditions (`{(c) ? (a) : (b)}` or `{if(c, a,
b)}`), nested blocks first, and an `oneway` info says so. Any other block
(no `else`, a statement or a parameter in one branch only, another model or
node, a `.param` that differs, a model card or a subcircuit in a branch) is
the `unsupported` error it would be, which says which of these it was.

## Report codes

Every entry of a translation's report has one of these codes.
[Reading the report](simulators.md#reading-the-report) shows an entry of each.

| code | severity | meaning |
|---|---|---|
| `untranslated` | error | no rule of the source grammar understood the line |
| `unsupported` | error | the target has no statement, model family, function or operator for it |
| `loss` | error or warning | one value of a statement has no place in the target form |
| `invalid` | error or warning | the input is wrong or cannot be right in the target |
| `synthesized` | warning | the target needs a value the source did not give; one was written |
| `caveat` | warning | written, but the two simulators do not mean quite the same |
| `ambiguous` | warning | the same text means different things in the two dialects |
| `rename` | info | a name got the device letter the target needs |
| `oneway` | info | written in a form the target's own grammar does not read back |
| `cosmetic` | info | something without meaning was not written (an analysis label) |
