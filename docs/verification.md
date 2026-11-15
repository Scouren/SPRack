# Grammar verification

Research only: no grammar was edited. Each claim gets a verdict
(**correct**, **wrong**, **unclear**), the correct value when wrong, and a
source. "Proposed rule" lines use the `.spgrammar` syntax of README.md and are
meant to be pasted in later; they have not been compiled.

## Sources and versions

| simulator | source | revision |
|---|---|---|
| VACASK | `https://codeberg.org/arpadbuermen/VACASK` (manual = `docs/*.md`, parser = `lib/dfllexer.l`, `lib/dflparser.y`) | `b2c15511a1a7c6246cca6bcfd8d38bfb3c750d7a` (2026-11-13) |
| ngspice | `https://git.code.sf.net/p/ngspice/ngspice` (source); manual: see section 0 | see section 0 |
| Xyce | `https://github.com/Xyce/Xyce` (source, `doc/` LaTeX Reference Guide) | see section 0 |
| HSPICE, Spectre | behaviour observed by running tiny decks we wrote | HSPICE Y-2026.03-SP2-1, Spectre 25.10 |
| LTspice | behaviour observed by running tiny decks we wrote (section 8) | LTspice 26.0.2 |

Paths below are relative to each repository root. Line numbers are for the
revision above.

Not available while this was written: the conformance-suite checkout under the
session scratchpad (`suite/tests/netlist/stress/vacask_*`) was deleted when
`/tmp` filled up during the session, so the four upstream VACASK decks were not
re-read; the VACASK repository's own `demo/`, `test/` and `benchmark/` decks were
used instead.

### 0. ngspice and Xyce revisions

* ngspice: the repository's default branch is now `pre-master-48`
  (`f14a632a52647acdbda65ba40891ba0c0fb56bd4`, 2026-11-11), which has **removed
  the HICUM C model** (no `src/spicelib/devices/hicum2`; HICUM is only an OSDI
  file, `src/spinit.in:39`). The release is tag `ngspice-47`
  (`a80f6e3e95d51534905b1f23410a951802666656`). ngspice line numbers below are
  for `ngspice-47` unless marked "48-dev".
* The ngspice manual is **not** in the ngspice source tree (neither checkout has
  manual sources); it was not consulted. Every ngspice citation is to source code.
* Xyce: `https://github.com/Xyce/Xyce` `e5b7b9bb5b221630c66654c059fc2d33524f5b21`
  (2026-10-19). The Reference Guide LaTeX is in `doc/Reference_Guide/`.

---

## 1. VACASK (6.1)

### 1.1 Lexer

| claim (`grammars/vacask.spgrammar`) | verdict | source |
|---|---|---|
| `case sensitive` | correct | `docs/input-overview.md` "The input file is case-sensitive." |
| `title yes` | correct | `lib/dflparser.y:314` (`TITLE NEWLINE` starts the top-level netlist) |
| `comment line "//"`, `tail "//"`, `block "/*" "*/"` | correct | `docs/input-overview.md` "Comments" |
| `continue trail "\"` | correct, incomplete | `docs/input-overview.md` "Whitespace and newlines": a trailing `\` joins lines, **and** newlines inside `()`, `[]`, `{}` are ignored. A reader that only knows `\` will mis-split multi-line `( ... )` parameter lists, which the VACASK decks use heavily (`model x sp_bjt (` on one line, parameters on the next ones; e.g. `demo/spice/bjt.sim`). |
| `scale M=6 T=12 G=9 k=3 m=-3 u=-6 n=-9 p=-12 f=-15 a=-18` | correct but incomplete | `lib/dfllexer.l:643` accepts `[munpfakKMGTxX]`, `meg`, `mil`; `docs/input-numbers.md` table: `K` = kilo, `x`/`X`/`meg` = mega, `mil` = 25.4e-6. Proposed: `readscale K=3 X=6 x=6 meg=6` and `oddscale mil=25.4e-6`. |
| `units after-scale` | correct | `lib/dfllexer.l:643` (`[a-zA-Z_]*` after the prefix); `docs/input-numbers.md` |
| `expr bare`, `values idents` | correct | `lib/dflparser.y:515-783` (expressions are parameter values without delimiters; identifiers are values) |
| `parens token` | correct | instance and subckt terminal lists are in `( )`: `lib/dflparser.y:324,334,866-885` |

### 1.2 The nine `assumed` lines

1. **`needs inductor` loads `spice/inductor.osdi`, module `sp_inductor`** (line 51): **correct.**
   `devices/CMakeLists.txt:17` builds `spice/inductor.osdi`; `devices/spice/inductor.va:58`
   is `module sp_inductor(pos, neg)`; `docs/dev-spice.md` table. The instance
   parameter is `inductance` with `aliasparam l` (`devices/spice/inductor.va:64-65`), so `l=` works.
   Same check for the two neighbours: `sp_resistor` has `aliasparam r`
   (`devices/spice/resistor.va:85-86`), `sp_capacitor` has `aliasparam c`
   (`devices/spice/capacitor.va:60-62`).

2. **`needs diode` loads `spice/diode.osdi`** (line 55): **correct.**
   `devices/CMakeLists.txt:18`; module `sp_diode` (`devices/spice/diode.va:91`);
   `docs/dev-spice.md`. `spice/sn/diode.osdi` (`CMakeLists.txt:31`) is the
   small-signal-noise-only variant (`docs/dev-spice.md` "Model variants"); both are valid.

3. **Option names other than `tran_method` follow SPICE** (line 80): **correct** for every
   name the rule uses: `temp`, `tnom`, `gmin`, `scale`, `reltol`, `abstol`, `vntol`
   are registered at `lib/options.cpp:245-259`, `tran_maxord` at `lib/options.cpp:317`;
   `docs/cmd-options.md` table. Also available and missing from the rule: `chgtol`
   (`lib/options.cpp:260`). There is no `trtol`; the nearest is `tran_lteratio`
   (`lib/options.cpp:327`, default 3.5 vs SPICE trtol 7), not the same quantity, so do not map it.
   Proposed: add `chgtol=chgtol` to the `options` rule. **Fixed in 8ee108cb.**

4. **`rule save = "save" signals+`** (line 82): **correct**, with a caveat to add.
   `docs/cmd-save.md`; lexer `lib/dfllexer.l:860` (`save` is a keyword only inside
   `control`); parser `lib/dflparser.y:1272`. Caveat: in `ac`, `noise`, `acxf`, `dcinc` the
   directive `v(node)` saves the **operating point** value; the AC phasor is `dv(node)` and
   `di(inst)` (`docs/cmd-analysis-ac.md` "Save directives"). A translated `.save v(out)`
   followed by `.ac` therefore records the DC value. Proposed:
   `caveat save signals : in VACASK ac analyses v() saves the operating point; the AC phasor is dv()`. **Fixed in 8ee108cb.**

5. **`rule hb = "analysis" name "hb" { freq=[freqs] nharm=harms ...params }`** (line 91): **correct.**
   `docs/cmd-analysis-hb.md` "Parameters" (`freq` real vector, `nharm` integer or vector);
   `lib/corehb.cpp:28-29`; analysis id `include/anhb.h:23`.

6. **`mag` and `phase` on vsource/isource** (line 100): **correct** (`mag`=AC magnitude,
   `phase`=AC phase in degrees). `lib/devvisrc.cpp:64-65`; `docs/dev-builtin-src.md`
   "Small-Signal Excitation".
   **`v0`/`v1` as pulse aliases: wrong.** The builtin source registers only `val0`/`val1`
   (`lib/devvisrc.cpp:27-72`, full parameter list); `v0`/`v1` would be rejected as unknown
   parameters. Reading them is harmless (they are never written) but they should be dropped
   from both source rules so a deck using them is not silently accepted.
   Also wrong by omission in the same rules (source: `lib/devvisrc.cpp:27-72` and
   `docs/dev-builtin-src.md`):
   * sine phase is `tdphase` (degrees) and damping is `theta`; the canonical `sphase` and
     `damp` have no mapping. Note `phase` is the AC phase, **not** the sine phase.
   * `type="exp"` and `type="pwl"` exist (`lib/devvisrc.cpp:76-82`).
   * `type="fm"` is SPICE `sffm` (`docs/dev-builtin-src.md` "FM": `sinedc`, `ampl`, `freq`,
     `modfreq`, `modindex`).
   Proposed rule (both sources):

        rule  vsource   = name "(" pos neg ")" "vsource" { dc=dc mag=acmag phase=acphase type="wave" val0=val0 val1=val1 delay=delay rise=rise fall=fall width=width period=period sinedc=sinedc ampl=ampl freq=freq theta=damp tdphase=sphase tau1=tau1 tau2=tau2 wave=[pwl] modindex=mdi modfreq=fsig ...params }
        enum vsource wave : pulse=pulse sine=sine exp=exp pwl=pwl sffm=fm

   Two semantic differences the grammar cannot express and that need a `caveat` (or engine
   work), from `lib/devvisrc.cpp`:
   * **exp**: VACASK's `td2` is measured **from `delay`** ("start of fall" =
     `delay + td2`, `lib/devvisrc.cpp:798`), SPICE's TD2 is absolute. Write
     `delay=td1 td2=(td2-td1)`. `td2` must be > 0 (`lib/devvisrc.cpp:501-505`).
   * **pulse**: `rise` must be > 0 (`lib/devvisrc.cpp:186-190`, default 1n), `fall<=0`
     means a step that never falls, `width<=0` and `period<=0` mean no flat top and a single
     pulse (`lib/devvisrc.cpp:192-198`, defaults at `:100-105`). SPICE substitutes TSTEP for a
     zero rise/fall and TSTOP for a missing width/period. A SPICE pulse with omitted
     fall/width/period therefore changes shape in VACASK.
   **Fixed in 8ee108cb**: tdphase/theta, exp/pwl/fm are mapped; `td2` is converted both ways
   (`convert`, engine 0eaab6a8); a missing or zero rise/fall, a missing width, and the sine,
   exp and sffm defaults that differ are `invalid` errors in both directions.
   * SPICE `am(...)` has a different parametrisation from VACASK `type="am"`
     (`modindex`, `docs/dev-builtin-src.md` "AM"): **unclear** whether a one-to-one
     mapping exists; leave unmapped.

7. **`signals v = "v(%)"`, `i = "i(%)"`** (line 124): **correct.** `docs/cmd-save.md`
   "Directive syntax"; `i(inst)` is the branch flow `inst:flow(br)`. VACASK has no
   `v(a,b)` save directive (not in `docs/cmd-save.md` or any `cmd-analysis-*.md` save
   table), so leaving `vdiff` out is right.

8. **`functions`** (line 129): every listed name is **correct**; the table is
   **incomplete**. Source: `lib/context.cpp:37-113` (builtin table) and
   `docs/expr-functions.md`.
   * `log` in VACASK is the **natural** log, same as `ln` (`lib/context.cpp:52-53`;
     `lib/rpnexprva.cpp:152-155` comments on exactly this pitfall). So `ln = ln log` (read
     both, write `ln`). `log10` is base 10 (`lib/context.cpp:54`).
   * Present in VACASK but missing from the grammar: `asinh acosh atanh` (`:48-50`),
     `sgn` (`:63`), `fmod` (`:75`), `agauss gauss aunif unif` (`:113-116`, same argument
     order as SPICE: `docs/expr-functions.md` "Monte Carlo"), `sign(x,y)` = magnitude of x
     with sign of y (`:74`), `int` (`:99`, type conversion) and `integer` (`:59`,
     truncation toward zero).
   * `sqr`, `pwr`, `nint`, `limit`, `if`, `stp`, `uramp`, `db` do not exist.
   Proposed:

        functions
          same abs min max sqrt exp pow floor ceil sin cos tan asin acos atan atan2 sinh cosh tanh asinh acosh atanh hypot sgn fmod agauss gauss aunif unif
          ln    = ln log
          log10 = log10
          sign2 = sign
          int   = integer
        end
        variables
          temper = $temp
        end
        operators
          pow "**"
          xor "^"
        end

   **Fixed in 8ee108cb**, except `sgn`: VACASK's `sgn(0)` is 1 (`include/rpnfunctor.h:300`), SPICE's 0, so it is left unmapped.

   (`int = integer`: SPICE `int` truncates toward zero; VACASK `integer` is `FwTrunc`,
   `lib/context.cpp:59`. VACASK `int` is a type conversion whose rounding was not
   checked.)

9. **The ninth `assumed` line is the file header comment at line 10.** Resolved by this
   section. (The other `assumed` in the repo was Spectre's `bsimbulk`, now
   confirmed; see 3.4.)

Also checked, not marked `assumed`:

| claim | verdict | source |
|---|---|---|
| `block subckt open "subckt" name ["("] ports* [")"]` | **wrong in writing**: the parentheses are mandatory | `lib/dflparser.y:324,334` accept only `SUBCKT IDENTIFIER LPAREN ... RPAREN`. Proposed: `open "subckt" name "(" ports* ")"`. |
| `close "ends"` | correct; `ends name` is also legal and must match | `lib/dflparser.y:445-460`. Proposed: `close "ends" [name]` |
| `rule global = "global" nodes+` | correct | `lib/dflparser.y:1145-1152` (with or without parens) |
| preamble `ground 0` | correct | `lib/dflparser.y:1153-1160` |
| `rule model = "model" name type ["("] {...} [")"]` | correct | `lib/dflparser.y:1076`, `:852` |
| `rule hdl = "load" path` | correct; `load` also accepts a `.va` file, compiled on the fly | `lib/dflparser.y:1162-1170`; `lib/openvafcomp.cpp`; decks `load "nl.va"` in `demo/` |
| `rule op/ac/tran/noise` key names | correct | `include/anop.h:24`, `include/anac.h:17`, `include/antran.h:18`, `include/annoise.h:16`; `lib/coreac.cpp:20-24`, `lib/coretran.cpp:232-236`, `lib/corenoise.cpp:19-23`; `docs/cmd-analysis-{ac,tran,noise}.md` |
| `rule tran` has no `skip_dc` | **gap**: VACASK has `icmode="uic"` | `lib/coretran.cpp:236`; `docs/cmd-analysis-tran.md` "Parameters". Proposed: add `icmode:"uic"=skip_dc` inside the braces (if the brace form takes a literal-to-atom pair; otherwise `icmode="skip_dc"` with `enum tran skip_dc : yes=uic`). |
| `rule dc` nested sweep: first `sweep` line is the outer loop | correct | `docs/cmd-sweep.md` "Nested sweeps": "The last `sweep` is the inner (fastest) loop" |
| `rule dc` has no temperature sweep | **gap** | `docs/cmd-sweep.md` "What can be swept": `option="name"`. Proposed: `rule dc = "sweep" _?sweep$# { option=="temp" from=start to=stop step=step } / "analysis" name?dc$# "op"` with `var:"temp"` set. |
| `enum options method : trap=trap gear=gear2 euler=euler` | correct | `lib/coretran.cpp:585-591` (`am bdf gear euler trap bdf2 gear2`); `docs/cmd-options-tran.md`. Note `gear` (variable order up to `tran_maxord`, default 2) is closer to ngspice `method=gear`; `gear2` forces order 2. Either is defensible. |
| `wrap "control" "endc" : options save op dc ac tran noise hb` | correct | `lib/dfllexer.l:811-868` (`analysis`, `sweep`, `save` are keywords only when `inControl`) |
| `raw "embed" ">>>FILE"` | correct | `lib/dfllexer.l:188,695`; `docs/input-overview.md` example |
| `models psp103 n = psp103va type=1` | correct | `devices/psp103v4/psp103.va:46` `module PSP103VA`, OSDI lowercases it (`demo`/`benchmark` decks: `model psp103n psp103va (`); `TYPE` +1/-1 at `devices/psp103v4/PSP103_module.include:96`; OSDI file `psp103v4.osdi` (`devices/CMakeLists.txt:14`) |

### 1.3 `no` lines in the VACASK grammar (counted in section 2)

See section 2, rows V1-V10.

### 1.4 Statement kinds: does VACASK have it, and in what form

Every builtin below needs a `model <name> <builtin>` line before use
(`docs/dev-builtin.md`); the proposed `needs` blocks write it.

| kind | VACASK has it? | syntax and source | proposed grammar text |
|---|---|---|---|
| mutual (fixed in 8ee108cb) | **yes**, builtin `mutual` | `m12 () mutual k=0.95 ind1="l1" ind2="l2"`; empty terminal list required. `docs/dev-builtin-mutual.md`; params `lib/devctlsrc.cpp:804-809`; registered `lib/devbuiltins.cpp:15`. Needs inductors exposing `flow(br)` and `l`; `sp_inductor` has `branch (pos, neg) br` and `aliasparam l` (`devices/spice/inductor.va:61-65`), so it should qualify (**unclear**, not run). | `needs mutual` / `  model mutual mutual` / `end`; `rule mutual = name "(" ")" "mutual" { k=k ind1="l1" ind2="l2" }` |
| vcvs (fixed in 8ee108cb) | **yes**, builtin `vcvs` | `e1 (out 0 in 0) vcvs gain=10`; `docs/dev-builtin-vcvs.md`; `lib/devctlsrc.cpp:17-19`, `lib/devbuiltins.cpp:12` | `needs vcvs` / `model vcvs vcvs`; `rule vcvs = name "(" pos neg cpos cneg ")" "vcvs" { gain=gain ...params }` |
| vccs (fixed in 8ee108cb) | **yes**, builtin `vccs`; transconductance is `gain` | `docs/dev-builtin.md`; `lib/devctlsrc.cpp:17-19`, `lib/devbuiltins.cpp:11` | `needs vccs` / `model vccs vccs`; `rule vccs = name "(" pos neg cpos cneg ")" "vccs" { gain=gm ...params }` |
| cccs (fixed in 8ee108cb) | **yes**, builtin `cccs`; controlling source by name | `f1 (0 out) cccs ctlinst="vprobe" gain=10`; `docs/dev-builtin-cccs.md`; `lib/devctlsrc.cpp:28-32`. Direction `I(p->n) = gain*I(ctlinst)`, same as SPICE F | `needs cccs` / `model cccs cccs`; `rule cccs = name "(" pos neg ")" "cccs" { ctlinst="vsrc" gain=gain ...params }` |
| ccvs (fixed in 8ee108cb) | **yes**, builtin `ccvs`; transresistance is `gain` | `docs/dev-builtin.md`; `lib/devctlsrc.cpp:28-32`, `lib/devbuiltins.cpp:14` | `needs ccvs` / `model ccvs ccvs`; `rule ccvs = name "(" pos neg ")" "ccvs" { ctlinst="vsrc" gain=gain ...params }` |
| bsource (fixed in 8ee108cb) | **yes** (grammar says `no`) | `b1 (p n) v=<expr>` / `i=<expr>` (also `potential=`, `flow=`); no master name. `docs/dev-builtin-behavioral.md` "Syntax"; parser `behavioral` production `lib/dflparser.y:1058-1066` (allowed at top level and in subckts, `:372`, and in conditional blocks, `:474`). Expression accessors `v(n)`, `v(a,b)`, `i(inst)`; time is `$abstime` (behavioural only, `docs/dev-builtin-behavioral.md:265-275`). | `rule bsource = name "(" pos neg ")" { v=v i=i ...params }`, placed before `rule instance`; `variables time = $abstime` only valid inside it |
| tline (fixed in 8ee108cb) | **yes**, as a shipped Verilog-A device | `tline_ideal.osdi`, module `tline_ideal(p1,n1,p2,n2)`, params `z0 td f nl`, `td` wins, else `nl/f`. `docs/dev-vacask.md` table; `devices/tline_ideal.va:4-30`; `devices/CMakeLists.txt:7` | `needs tline` / `load "tline_ideal.osdi"` / `model tline tline_ideal` / `end`; `rule tline = name "(" p1 n1 p2 n2 ")" "tline" { z0=z0 td=td f=f nl=nl ...params }` |
| libsection (fixed in 8ee108cb) | **yes** | `section name` ... `endsection`. `docs/input-include.md` "Section syntax"; `lib/dfllexer.l:536,553` | `block libsection` / `open "section" name` / `close "endsection"` / `end` |
| lib (fixed in 8ee108cb) | **yes** | `include "file" section=name`. `docs/input-include.md`; `lib/dfllexer.l:300,374-381` | `rule lib = "include" path { section=section! }` before `rule include` |
| cond_if / elif / else (fixed in 8ee108cb) | **yes** | `@if expr` / `@elseif expr` / `@else` / `@end`. `docs/cir-conditional.md`; `lib/dfllexer.l:783-798`; `lib/dflparser.y:463-499`. A branch may hold only instances, behavioural sources, models and nested blocks (`lib/dflparser.y:467-499`), not `parameters`. | `block cond_if` / `open "@if" cond...` / `close "@end"` / `end`; `rule cond_elif = "@elseif" cond...`; `rule cond_else = "@else"`; plus a `caveat` that parameters inside a branch are not allowed |
| ic (fixed in 0eaab6a8, 8ee108cb: carried as tran ic=) | **no statement**; `ic=` is a parameter of `tran` and `pss` | `analysis t tran ... ic={"n1", 2.0, "n2", 1.0}` (list of node,value; a node pair gives a difference). `docs/cmd-analysis-tran.md` "Parameters"; `lib/coretran.cpp:247` | Not a rule: needs an engine `move ic -> tran.ic` that renders `{"node", value, ...}`. Until then `no ic : VACASK takes initial conditions as the ic= list of a tran analysis` would be wrong (it has them); keep `-` and record it for Phase 3. |
| nodeset (fixed in 0eaab6a8, 8ee108cb) | **no statement**; `nodeset=` parameter of `op`, `ac`, `tran`, `noise`, `hb`, ... | `analysis op1 op nodeset={"node1", 1.2}`. `docs/cmd-analysis-op.md` "Parameters" and examples; `lib/corehb.cpp:38` | Same as ic: an engine move to every analysis's `nodeset=`. |
| sens (`no` line in 8ee108cb) | **no** | No sensitivity analysis among the registered analyses (`include/an*.h` `analysisId`: `op ac noise dcxf hb dcinc acxf tran acstb pss pnoise acsp hbnoise pac hbac`); no `docs/cmd-analysis-sens*` | `no sens : VACASK has no sensitivity analysis` |
| sp (fixed in 8ee108cb; ports stay a loss error) | **yes**, analysis `acsp` | `analysis s acsp ports=["v1","r1","v2","r2"] from=... to=... mode="dec" points=...`; a port is a vsource **plus a series resistor**, named in pairs. `docs/cmd-analysis-acsp.md`; `include/anacsp.h:20`; `lib/coreacsp.cpp:19-24` | `rule sp = "analysis" name?sp$# "acsp" { from=fstart to=fstop mode="sweep" points=points ...params }` plus `caveat sp : VACASK ports are named in ports=[vsrc, rser, ...]; SPICE portnum/z0 on a source has no direct form` |
| pss (fixed in 8ee108cb, tper = 1/fund by `convert`) | **yes**, analysis `pss` (shooting) | `tper` (period, not frequency), `tstab`, `maxharm`, `oscillator`. `docs/cmd-analysis-pss.md`; `lib/corepss.cpp:27-31` | Canonical `fund` is a frequency; VACASK wants `tper=1/fund`. Grammar cannot invert; needs an engine transform or `rule pss = "analysis" name?pss$# "pss" { tper=fund ... }` is **wrong**. Proposed after engine support: `{ tper='1/$fund' tstab=tstab maxharm=harms ...params }`. |
| stb (fixed in 8ee108cb) | **yes**, analysis `acstb` | `analysis s acstb probe="vprobe" from=... to=... mode="dec" points=...`; probe is a series voltage source. `docs/cmd-analysis-acstb.md`; `lib/coreacstb.cpp:19-23`; `include/anacstb.h:16` | `rule stb = "analysis" name?stb$# "acstb" { probe="probe"! from=fstart to=fstop mode="sweep" points=points ...params }` |
| tf (fixed in 8ee108cb) | **yes**, analysis `dcxf` (grammar says `no`) | `analysis xf1 dcxf out="out"` (or `out=["p","n"]`); saves `tf(src)`, `zin(src)`, `yin(src)` for every independent source. No output resistance. `docs/cmd-analysis-dcxf.md`; `lib/coredcxf.cpp:16`; `include/andcxf.h:16` | `rule tf = "analysis" name?tf$# "dcxf" { out="out" ...params }` with `caveat tf src : dcxf reports tf() and zin() for every source; SPICE's output resistance has no counterpart`. `ref` needs the vector form `out=["out","ref"]`. |
| PWL sources (fixed in 8ee108cb) | **yes** | `type="pwl" wave=[t1,v1,t2,v2,...]`, plus `file=`, `period`, `stretch`, `scale`, `offset`. `docs/dev-builtin-src.md` "PWL"; `lib/devvisrc.cpp:51-60` | in the source rules: `wave=[pwl]`; enum `pwl=pwl` |
| exp sources (fixed in 8ee108cb) | **yes**, with a different `td2` origin | see 1.2 item 6 | `tau1=tau1 tau2=tau2` + `td2` transform |
| switches (reasons reworded in 8ee108cb) | **no builtin**, no shipped module | `docs/dev-builtin.md` lists exactly 7 builtins; `docs/dev-vacask.md` and `docs/dev-spice.md` list no switch. `demo/sc/swtest.sim:3` loads a user Verilog-A `vsw.va`. | keep `no vswitch`, `no cswitch` |

### 1.5 Model families beyond R, C, L, diode, PSP103

Shipped OSDI files: `devices/CMakeLists.txt:2-41`; module names `docs/dev-spice.md`,
`docs/dev-vacask.md` and the `module` lines quoted. All take `type=1` (n/npn) or
`type=-1` (p/pnp): `devices/spice/bjt.va:89`, `mos1.va:112`, `jfet1.va:95`,
`mes1.va:76`, `bsim3v3.va:566`, `bsim4v8.va:1038`, `vdmos.va:113`;
`devices/bsimbulk106.va:706` (`TYPE`); `devices/vbic/vbic_1p3.va:302`.
The load lines are the ones the decks use (e.g. `load "spice/bjt.osdi"`).

    models
      bjt npn    = sp_bjt type=1          # load "spice/bjt.osdi"; terminals c b e sub (devices/spice/bjt.va:77)
      bjt pnp    = sp_bjt type=-1
      jfet n     = sp_jfet1 type=1        # load "spice/jfet1.osdi" (level 1); sp_jfet2 = level 2 Parker-Skellern
      jfet p     = sp_jfet1 type=-1
      mesfet n   = sp_mes1 type=1         # load "spice/mes1.osdi"
      mesfet p   = sp_mes1 type=-1
      mos1 n     = sp_mos1 type=1         # load "spice/mos1.osdi"; also mos2, mos3, mos6, mos9
      mos1 p     = sp_mos1 type=-1
      mos2 n     = sp_mos2 type=1
      mos2 p     = sp_mos2 type=-1
      mos3 n     = sp_mos3 type=1
      mos3 p     = sp_mos3 type=-1
      bsim3 n    = sp_bsim3v3 type=1 | bsim3 type=1     # spice/bsim3v3.osdi (ngspice-distilled) | bsim3v3.osdi (module bsim3, devices/bsim3v3.va:101)
      bsim3 p    = sp_bsim3v3 type=-1 | bsim3 type=-1
      bsim4 n    = sp_bsim4v8 type=1 | bsim4 type=1     # spice/bsim4v8.osdi | bsim4v8.osdi (module bsim4, devices/bsim4v8.va:454)
      bsim4 p    = sp_bsim4v8 type=-1 | bsim4 type=-1
      bsimbulk n = bsimbulk type=1        # bsimbulk106.osdi, module bsimbulk(d,g,s,b,t) (devices/bsimbulk106.va:622): 5 terminals
      bsimbulk p = bsimbulk type=-1
      vdmos      = sp_vdmos               # spice/vdmos.osdi, module sp_vdmos(d,g,s,t,tc): 5 terminals
      vbic npn   = vbic13 type=1          # vbic_1p3.osdi (3 terminals); vbic13_4t / vbic13_5t for 4 and 5 (devices/vbic/vbic_1p3.va:196-221, CMakeLists.txt:11-13)
      vbic pnp   = vbic13 type=-1
    end

Each family also needs a `needs <kind>` block with its `load` line. Not
shipped with VACASK (would need a user-compiled OSDI): HICUM, BSIM-SOI,
BSIM-CMG, HiSIM2, HiSIM-HV (no such file in `devices/`). The terminal counts
of `bsimbulk`, `sp_vdmos` and the VBIC variants differ from SPICE's, which the
writer has to handle; **unclear** how the grammar should express that.

---

## 2. The 31 `no` lines (6.4)

HSPICE and Spectre rows: "observed" is the behaviour of HSPICE Y-2026.03-SP2-1 or
Spectre 25.10 on a deck of a few lines written for the check; the deck is
quoted in the row.

### ngspice (3)

| # | line | verdict | source |
|---|---|---|---|
| N1 | `no hb` | correct | `src/spicelib/analysis/analysis.c:22-23,55-56`: `HBinfo` is only declared, under `#ifdef WITH_HB`; nothing in `src/` defines it and `configure.ac` never sets `WITH_HB`. |
| N2 | `no pss` (oscillator only) | correct | `.pss` takes `fguess stabtime oscnode points harmonics sc_iter steady_coeff [uic]` (`src/spicelib/parser/inp2dot.c:662-700`; parameters `src/spicelib/analysis/psssetp.c:57-66`). An oscillation node is required, and every shipped example is an oscillator (`examples/pss/`). |
| N3 | `no stb` | correct | `src/spicelib/analysis/analysis.c:36-58` lists OP, AC, DCT, DCO, TRAN, PZ, TF, DISTO, NOISE, SENS, PSS, SP, HB; no stability analysis. |

### Xyce (9)

The dot commands Xyce's reader knows (every `".XXX"` literal in
`src/IOInterfacePKG/*.C`): `.AC .DATA .DCVOLT .END .ENDDATA .ENDL .ENDS .FFT
.FOUR .FUNC .GLOBAL .GLOBAL_PARAM .HB .IC .INC .INCL .INCLUDE .INITCOND .LIB .LIN
.LOAD .MEAS .MEASURE .MODEL .MOR .MPDE .NODESET .NOISE .OP .OPTION .OPTIONS
.OUTPUT .PARAM .PREPROCESS .PRINT .RESULT .SAVE .SENS .STEP .SUBCKT .TRAN`. The
Reference Guide has one `*_Command.tex` per command, and the two lists match.

| # | line | verdict | source |
|---|---|---|---|
| X1 | `no cond_if` | correct | no `.IF` in the list above; no `IF_Command.tex` |
| X2 | `no tf` | correct | no `.TF` |
| X3 | `no pz` | correct | no `.PZ` |
| X4 | `no disto` | correct | no `.DISTO` |
| X5 | `no stb` | correct | no `.STB` or `.LSTB` |
| X6 | `no sens` (objective function plus parameter list) | correct | `doc/Reference_Guide/SENS_Command.tex`: `.SENS objfunc=<expr> param=<params>`; "Unlike the SPICE version, this capability will not automatically use every parameter in the circuit." |
| X7 | `no save` | correct | `doc/Reference_Guide/SAVE_Command.tex`: Xyce's `.SAVE` writes the operating point as `.IC`/`.NODESET` lines and selects no signals. |
| X8 | `no hdl` | correct | plugins are named on the command line, `-plugin <list>` (`src/IOInterfacePKG/N_IO_CmdParse.C:218,494`); no `.hdl` literal in `src/IOInterfacePKG`; no OSDI support in `src/` |
| X9 | `no device` | **unclear** | `user_plugin/rlc_adms.cir` instantiates the attribute-less module `rlc` (`user_plugin/rlc.va:45`) as `Yrlc rlc1 1 0 R=1kohm ...`, so a generic `Y<module> <name> <nodes> <params>` form exists for a compiled plugin. But the ADMS template (`utils/ADMS/xyceBasicTemplates_nosac.xml:483-495`) emits "FIXME" for the device letter and level when the module lacks `xyceSpiceDeviceName`/`xyceLevelNumber`. Whether that form works for any module is not established. At minimum, reword: "a plugin must be compiled with buildxyceplugin and loaded with -plugin". |

### VACASK (10)

| # | line | verdict | source |
|---|---|---|---|
| V1 | `no bsource` | **wrong**; fixed in 8ee108cb | `docs/dev-builtin-behavioral.md` "Syntax": `name (p n) v=<expr>` / `i=<expr>`; `lib/dflparser.y:1058-1066`. Rule in 1.4. |
| V2 | `no func` | correct | `lib/dflparser.y` has no function-definition production; the items allowed at top level and in subckts (`:344-428`) are parameters, model, instance, behavioral, condblock, subckt, global, ground, load, embed and control. No doc page. |
| V3 | `no measure` | correct | no measure command among `docs/cmd-*.md`; results go to raw files and `postprocess` |
| V4 | `no print` | correct in substance; **reason text wrong**; fixed in 8ee108cb | VACASK **has** `print`, but it prints expressions and circuit state, not analysis results (`docs/cmd-print.md`). Proposed text: `no print : VACASK's print shows expressions and circuit state; analysis results go to raw files` |
| V5 | `no tf` | **wrong**; fixed in 8ee108cb | `dcxf` is the DC small-signal transfer function: `analysis xf1 dcxf out="out"` saves `tf(src)`, `zin(src)`, `yin(src)` (`docs/cmd-analysis-dcxf.md`; `include/andcxf.h:16`; `lib/coredcxf.cpp:16`). It gives no output resistance. Rule in 1.4. |
| V6 | `no pz` | correct | analysis ids in `include/an*.h` (list in 1.4, row sens) |
| V7 | `no disto` | correct | same list; `hb` and `hbac` exist |
| V8 | `no four` | correct | no Fourier command among `docs/cmd-*.md`; same analysis list |
| V9 | `no vswitch` | correct | `docs/dev-builtin.md` ("seven builtin device types", no switch); `devices/CMakeLists.txt` ships none; `demo/sc/swtest.sim:3` loads a user `vsw.va` |
| V10 | `no cswitch` | correct | same |

### HSPICE (5)

| # | line | verdict | source |
|---|---|---|---|
| H1 | `no vswitch` | correct | observed: `s1 a b c 0 smod` with `.model smod sw vt=0.5` is refused as a syntax error; `g1 a b vcr pwl(1) c 0 0,1e-9 1,1` loads |
| H2 | `no cswitch` | correct; reason reworded | observed: `w1 a b v1 wmod` with `.model wmod csw it=0.5m` is refused because a W element is read as a transmission line and wants a conductor count. New reason: the W element is a transmission line. |
| H3 | `no mesfet` | **wrong** | observed: `z1 d g 0 mm` with `.model mm nmf` is a syntax error, but `j1 d g 0 mm 2` with `.model mm njf level=3` loads, and that model warns about an unknown parameter while accepting `sat=1`, so level 3 is a model of its own. Now `mesfet n = njf level=3` (p likewise) and a J-element write rule; reading tells it from a JFET by its model. |
| H4 | `no disto` | **wrong reason** | observed: after `.ac dec 10 1 1k`, `.disto rl 1` loads and `.disto rl` alone does not. HSPICE has the analysis, but it reports into a named load resistor, which the SPICE form does not name. Kept as `no` with that reason. |
| H5 | `no stb` | correct | observed: `.lstb mode=single vsource=vin` after an `.ac` loads: the probe is a voltage source in the loop, not the probe instance of the canonical form |

### Spectre (4)

| # | line | verdict | source |
|---|---|---|---|
| S1 | `no disto` | correct | observed: `d1 disto start=1 stop=1k dec=10` is taken as an instance of an undefined master `disto` |
| S2 | `no measure` | correct | observed: `measure m1 tran find v(a) at=0.5m` is taken as an instance named `measure` |
| S3 | `no vswitch` | **wrong** | observed: `s1 (a b c 0) sm region=on` with `model sm vswitch vt=0.5 ron=1 roff=1e9` loads and solves. Now a rule and `vswitch = vswitch`. |
| S4 | `no cswitch` | **wrong** | observed: `w1 (a b) wm probe=v1` with `model wm iswitch it=0.5m ron=1 roff=1e9` loads and solves. Now a rule and `cswitch = iswitch`. |

---

## 3. Model level tables (6.2)

### 3.1 ngspice (`src/spicelib/parser/inpdomod.c`, ngspice-47)

| grammar line | verdict | source |
|---|---|---|
| `vbic npn = npn level=4 \| npn level=9` | correct | `:58-60` |
| `hicum2 npn = npn level=8` | correct for ngspice-47 | `:66-67`; message "Only BJT levels 1-2, 4, 8, 9" at `:75`. **48-dev drops it**: no `hicum2` device directory; HICUM only as `HICUMl0-2.0.osdi` (48-dev `src/spinit.in:39`). |
| `bsim3 = level=8 \| level=49` | correct | `:271` |
| `bsim4 = level=14 \| level=54` | correct | `:297` |
| `bsimsoi = level=10 \| level=58` | correct (B4SOI) | `:347-348`. Level 57 is B3SOIPD (`:339-340`); 55 and 56 are B3SOI FD and DD. |
| `hisim2 = level=68` | correct | `:363-364` |
| `hisimhv = level=73` | correct | `:371-377` (version 1.x selects HiSIMHV1, the default and 2.x select HiSIMHV2) |
| `hfet n = nhfet`, `hfet p = phfet` | **wrong**; fixed in 4a70b88c | `nmf pmf nhfet phfet` share one level switch (`:124-175`): level 0 or 1 is MES (Statz), 2-4 MESA, **5 HFET1, 6 HFET2**. An `nhfet` card with no level is a MESFET. Proposed: `hfet n = nhfet level=5 \| nhfet level=6` and `hfet p = phfet level=5 \| phfet level=6`. |
| `mesfet n = nmf` | correct | same switch, level 0 or 1 |
| `vdmos = vdmos` | correct | `:195-197` (`vdmosn` and `vdmosp` are also read) |
| `vswitch = sw`, `cswitch = csw` | correct | `:500-512` |

BSIM-BULK, BSIM-CMG and PSP103 have no C model and no level in ngspice; they
exist only as OSDI. They are absent from `inpdomod.c`, and 48-dev
`src/spinit.in:33-41` lists `BSIMBULK107.osdi`, `BSIMCMG.osdi` and
`psp103.osdi`, loaded only when `osdi_enabled` is set (it is unset at `:17`).
The grammar is right to give them no level. PSP103 is listed by the name of
its module instead (3.5).

### 3.2 Xyce

Sources: `.registerDevice` calls under `src/DeviceModelPKG`;
`doc/Common_Guide_Files/deviceFeatureSupportTbl.tex`;
`doc/Reference_Guide/M_Device.tex`.

| grammar line | verdict | source |
|---|---|---|
| `vbic npn = npn level=10 \| level=11 \| level=12` | **wrong**: there is no level 10; fixed in 4a70b88c | Q levels registered: 1, 11, 12, 23, 230, 234, 504, 505 (`OpenModels/N_DEV_BJT.C:4705`, `ADMS/N_DEV_ADMSvbic13.C:9194`, `ADMS/N_DEV_ADMSvbic13_4t.C:10175`, ...). VBIC 1.3 is 11 for 3 terminals and 12 for 4 (`deviceFeatureSupportTbl.tex:64-68`). Proposed: `vbic npn = npn level=11 \| npn level=12`, the same for pnp. |
| `hicum2 = level=234` | correct | `ADMS/N_DEV_ADMShicumL2va.C:14587`; HICUM L0 is 230 |
| `bsim3 = level=9 \| level=49` | correct | `OpenModels/N_DEV_MOSFET_B3.C:11668-11669` |
| `bsim4 = level=14 \| level=54` | correct | `OpenModels/N_DEV_MOSFET_B4.C:11704-11705` |
| `bsimsoi = level=70 \| level=10` | correct; note the versions | 70 is BSIM-SOI 4.6.1 (`ADMS/N_DEV_ADMSbsimsoi461.C:38096`); 10 and 57 are BSIM-SOI 3.2 (`OpenModels/N_DEV_MOSFET_B3SOI.C:19130-19131`); 70450 is 4.5.0 and 70470 is 4.7.0 (`M_Device.tex:147-149,672-677`). Reading level 57 is missing (added in 4a70b88c). |
| `bsimcmg = level=110 \| level=107` | correct but stale; 111 and 108 added in 4a70b88c | level 111 (BSIM-CMG 111.2.1) is current (`ADMS/N_DEV_ADMSbsimcmg_111.C:52253`; `M_Device.tex:865,891`: 110 "has been superceded by the level 111 version"); 108 also exists. Proposed: `bsimcmg n = nmos level=111 \| nmos level=110 \| nmos level=108 \| nmos level=107`. |
| `bsimbulk = level=77` | correct | `ADMS/N_DEV_ADMSbsim6.C:31325`; documented as "BSIM6 model version 6.1.1" (`M_Device.tex:788`), BSIM-BULK before the rename |
| `psp103 = level=103` | correct | `ADMS/N_DEV_ADMSPSP103VA.C:34418`; 1031 is the self-heating version (`ADMS/N_DEV_ADMSPSP103TVA.C:36451`) |
| `jfet`, `mesfet`, `mos1/2/3` | correct | `registerDevice("j",1)`, `("j",2)`, `("z",1)`, `("m",1/2/3/6)` |
| switch models `vswitch \| sw`, `iswitch \| csw` | `vswitch` and `iswitch` correct; **`sw` and `csw` are not Xyce model types** | `OpenModels/N_DEV_SW.C:1089-1092` registers only `switch`, `iswitch` and `vswitch`; there is no `"sw"` or `"csw"` anywhere in `src/`; `doc/Reference_Guide/S_Device.tex:26-27`. As read spellings they accept netlists Xyce rejects. Proposed: `vswitch = vswitch`, `cswitch = iswitch`. Fixed in 4a70b88c. (`switch` is the expression-controlled generic switch, `SW_Device.tex`, not SPICE `sw`.) |

HiSIM2 and HiSIM-HV are not registered in Xyce, and the grammar correctly omits them.

### 3.3 VACASK

See 1.5.

### 3.4 HSPICE and Spectre

| dialect | grammar | verdict | observed |
|---|---|---|---|
| Spectre | every master in the table, `bsimbulk` included | correct | a deck per master (`model mm <master> type=n`, one instance with the right terminal count, `op1 dc`) loads and solves for `diode bjt vbic jfet gaas mos1 mos2 mos3 bsim3v3 bsim4 bsimsoi bsimcmg bsimbulk psp103 hisim2 hisim_hv`; `bsim6` loads too, as a second name for `bsimbulk` |
| HSPICE | MOSFET levels | correct | a deck per level (`.model mm nmos level=N`, one M element, `.op`, `.option list`) loads, and the listing names the model: 49 and 53 BSIM3v3, 54 BSIM4, 57 BSIM-SOI (3.x, PD), 70 BSIM-SOI 4, 72 BSIM-CMG, 77 BSIM6 (BSIM-BULK), 69 PSP, 68 HiSIM2, 73 HiSIM-HV; levels 1, 2, 3 and no level load |
| HSPICE | BJT levels 4 (`vbic`) and 8 (`hicum2`) | loads; family not shown | `.model mm npn level=4` and `level=8` both load with a Q element; the run does not name the model family |
| HSPICE | `mesfet` | added | see H3 |

### 3.5 PSP103 between ngspice and Xyce (r1)

A PDK written for ngspice declares PSP103 as the module of a compiled
Verilog-A file: `.model m psp103va type=1 ...`, its transistors on `N`
cards. The ngspice grammar now lists that spelling (`psp103 n = psp103va
type=1`) and writes a PSP103 transistor on an `N` card; read, an `N` card
is a MOSFET once its model is known to be PSP103. ngspice 45 with the
`psp103.osdi` and `psp103_nqs.osdi` of IHP SG13G2, Xyce 7.10; one NMOS,
W 1u, L 0.13u, source and bulk grounded, drain 1.2 V; the drain current.

| deck | gate | ngspice 45 | Xyce 7.10 |
|---|---|---|---|
| a card of defaults (`psp103va type=1 tr=27`; in Xyce `nmos level=103 tr=27`), each written from the other by SPRack | 0.6 V | 102.076 uA | 102.076 uA |
| IHP `sg13_lv_nmos`, tt corner, as the PDK has it | 0.6 V | 24.0222 uA | |
| the same device, the branch of the subcircuit ngspice takes written out (Xyce has no conditional blocks), translated | 0.6 V | 24.0222 uA | 26.8396 uA |
| that card without the seven parameters below | 0.6 V | 26.8396 uA | |
| the translated device | 1.2 V | 400.526 uA | 462.471 uA |
| that card without the seven parameters | 1.2 V | 462.471 uA | |

* The two simulators agree to the six digits printed on the same
  parameters. The 12 % (0.6 V) and 15 % (1.2 V) between them on the IHP
  card are parameters Xyce 7.10's PSP103 does not have: it loads the card
  with a warning for each (`No model parameter THECSO found for model ...,
  parameter ignored`), 14 in all: `st2vfbo ctgo ctbo stcto thecso stthecso
  nsubedgelexp` and the seven of IHP's operating-area check (`swsoa`,
  `vgs_max` and the like). With the first seven removed from the card,
  ngspice gives Xyce's number. SPRack copies them and says the two ship
  different versions of the model (a `caveat`).
* The module's own `level` (`level=103.6` on the IHP cards) changes nothing
  in ngspice: without it, with 103, 103.6 or 7 the current is the same
  102.076 uA. In Xyce, HSPICE and ESPice `level` is what names the model, so
  the card's own is not written (a `loss` warning). Xyce itself loads
  `level=103.6` as 103.
* The instance parameters of the IHP cards (`w l nf mult as ad ps pd dta
  ngcon delvto factuo`) are all instance parameters of Xyce's level 103
  (`Xyce -param M 103`). HSPICE's level 69 was not tried with `dta` and
  `factuo` (no HSPICE where this was measured): they are not in its
  `params mosfet` table, and stay errors.
* The NQS module (`pspnqs103va`, the PDK's `_rf` cards) has no Xyce form:
  `Xyce -param M 103` lists no NQS parameter, and a level 103 card with
  `swnqs=5 munqs=1` loads with `No model parameter SWNQS found ...
  parameter ignored` for both. Such a card stays an error.
* ngspice 45 without the module loaded refuses the card (`Unknown model
  type psp103va - ignored`): a PSP103 card written for ngspice carries a
  caveat that the deck must load `psp103.osdi` with `pre_osdi`.
* ESPice was not there to try `psp103va` on; its grammar is unchanged.

---

## 4. Functions, operators, variables (6.3)

### 4.1 `log`

| dialect | grammar | verdict | source |
|---|---|---|---|
| ngspice | `ln = ln log` (log is natural) | correct | `src/spicelib/parser/inpptree.c:149-151` (B sources: `ln` and `log` are both `PTF_LOG`); `src/frontend/numparam/xpressn.c:127,158` (`.param`: both compute `log(x)`) |
| Xyce | `ln = ln log` | **wrong**: Xyce `log` is **base 10**; fixed in 4a70b88c | `src/UtilityPKG/ExpressionSrc/ExpressionParser.yxx:1424-1446` (natural only under `useHspiceMath`). `useHspiceMath_` defaults to false and is set only by `-hspice-ext math` or `all` (`src/IOInterfacePKG/N_IO_ParsingMgr.C:65,77-110`). `doc/Reference_Guide/Expression_Arithmetic_Functions.tex:205`: "LOG(x) ... log base 10". Proposed: `ln = ln` and `log10 = log10 log`. |
| HSPICE | `ln = log` | correct; signed outside the domain | observed (`.meas tran pv param='...'`): `log(2)` is 0.693, `ln(2)` the same; `log(-2)` is -0.693 and `log10(-100)` is -2, the sign carried over instead of an error |
| Spectre | `ln = log` | correct | observed (`parameters p=...` on a source, read back from the operating point): `log(2)` and `ln(2)` are 0.693; `log(-2)` and `log10(-100)` stop the run with a domain error |
| VACASK | `ln = ln` | correct, incomplete; fixed in 8ee108cb | `lib/context.cpp:52-54`: `log` and `ln` are both natural. Proposed: `ln = ln log`. |

### 4.2 Operators

| dialect | grammar | verdict | source |
|---|---|---|---|
| ngspice | `pow "**" "^"` | correct | `src/frontend/numparam/xpressn.c:706-707` (`**` becomes `^`); `src/spicelib/parser/inpptree-parser.y:94` |
| Xyce | `pow "**" "^"` | **wrong**: `^` is XOR by default; fixed in 4a70b88c | `ExpressionParser.yxx:1783-1792` (`^` is power only under `useHspiceMath`); `ExpressionLexer.l:268-269`; `doc/Reference_Guide/Expression_Operator.tex:29,35` (`**` is exponentiation, `^` is boolean XOR). Proposed: `pow "**"` and `xor "^"`. |
| HSPICE | `pow "**" "^"` | correct spelling; **semantics differ** | observed: `2^3` is 8 and `5^3` is 125, so `^` is power; `2**3` is 8. But `pow(2,2.5)` is 4, `pow(2,-1.5)` is 0.5 and `(-2)**2.5` is 4: the exponent is cut to an integer first. Now `differs pow` in the grammar: a caveat on every crossing. |
| Spectre | `pow "**"`, `xor "^"` | correct | observed: `2^3` is 1 and `5^3` is 6 (exclusive-or); `5~^3` is -7 (exclusive-nor); `2**3` is 8; `(-2)**2.5` and `pow(-2,2.5)` stop the run |
| VACASK | `pow "**"` | correct, incomplete; fixed in 8ee108cb | `lib/dfllexer.l:722` (`**`) and `:749-750` (`^` is `BITEXOR`); `docs/expr-operators.md`. Proposed: add `xor "^"`. |

### 4.3 Function tables and variables

| dialect | finding | verdict | source |
|---|---|---|---|
| ngspice | every listed name exists in at least one of its two parsers | correct | `xpressn.c:91-94` (`.param`), `inpptree.c:138-182` (B sources). Caveat: the parsers differ. `int`, `sqr`, `limit`, `agauss`, ... exist only in `.param`; `u`, `uramp`, `pwl`, `ddt` only in B sources. `pwr` discards the sign in `.param` (`xpressn.c:139-141`, `pow(fabs(z), x)`) but keeps it in B sources (VACASK's `docs/input-include.md` documents the same split). `nint` rounds half to even (`xpressn.c:150-155`). |
| Xyce | every listed name exists | correct | `src/UtilityPKG/ExpressionSrc/ExpressionLexer.l`, one line per name: `abs:556 min:548 max:547 sqrt:613 exp:308 pow:586 pwr:585 floor:575 ceil:574 int:583 sgn:610 sign:611 limit:576 agauss:607 gauss:608 aunif:606 unif:605 nint:572 atan2:563 stp:612 uramp:695 if:582`. Missing from the grammar: `fmod` (`:573`) and `db` (`:545`); added in 4a70b88c. Xyce `pwr` keeps the sign (`Expression_Arithmetic_Functions.tex:61-66`). |
| Xyce variables | `temper = temp`, `hertz = freq`, `time = time` | correct | `ExpressionLexer.l:592-597` (`time temp temper freq hertz` are all tokens) |
| HSPICE | function table | **wrong** (`limit`), incomplete | observed: `int(-2.5)` is -2 and `int(2.7)` is 2 (truncation); `nint(2.5)` is 3 and `nint(3.5)` 4 (halves away from zero, now `differs nint`); `sqrt(-4)` is -2 and `db(-10)` is -20 (signed); `pwr(-2,2)` is -4 and `pwr(-2,3)` -8 (sign kept); `sgn(0)` is 0; `sign(3,-1)` is -3; `floor`, `ceil`, `fmod`, `hypot`, `atan2`, `asinh`, `cosh`, `min` give the usual values. `limit(5,0,2)` is refused inside an expression: HSPICE's `limit` is not the clamp of the other dialects, so it is dropped from the table. Added: `atan2 hypot fmod asinh`. |
| Spectre | function table | **incomplete** | observed: `pwr(-2,2)` is -4 (sign kept), `sgn(-3)` is -1, `sign(3,-1)` is -3, `nint(2.5)` is 2 and `nint(3.5)` 4 (halves to even), `db(10)` is 20 and `db(-10)` -20, `int(-2.5)` is -2 (truncation), `floor(-2.5)` -3, `ceil(-2.5)` -2; `limit` is not defined; `sqrt(-4)` stops the run. Added: `pwr sgn nint db` and `sign2 = sign`. |
| VACASK | see 1.2 item 8 | names correct, table incomplete | `lib/context.cpp:37-116` |

### 4.4 Measured for 8.2 (decks written for this, values read back)

| expression | ngspice `.param` | ngspice B source | Xyce 7.10 | HSPICE | Spectre |
|---|---|---|---|---|---|
| `-2**2` | -4 | -4 | -4 | -4 | -4 |
| `1+-2**2` | **5** | -3 | -3 | -3 | -3 |
| `2*-2**2` | **8** | | | | |
| `(-2)**3` | **8** | **8** | -8 | -8 | -8 |
| `pwr(-2,2)` | 4 | -4 | **4** | -4 | -4 |
| `pwr(-2,3)` | 8 | -8 | -8 | -8 | -8 |
| `nint(2.5)`, `nint(-2.5)` | 2, -2 | 2, -2 | **3, -3** | 3, -3 | 2, -2 |
| `int(-2.7)`, `floor(-2.5)` | -2, -3 | no `int`; -3 | -2, -3 | -2, -3 | -2, -3 |
| `log10(-100)` | error | error | **2** | **-2** | error |
| `sqrt(-4)` | error | error | 0 | -2 | error |
| `0 ? 1 : 1 ? 5 : 6` | 5 | 5 | 5 | 5 | 5 |
| `if(1,3,4)` | refused | refused | 3 | refused | refused |
| `ternary_fcn(1,3,4)` | 3 | 3 | refused | refused | n/a |

A minus after `(` or `,` or at the start binds as everywhere else in ngspice's
`.param`; only one right after another operator binds before the power.
VACASK loads and runs `p=(x > 1 ? 3 : 4)`. The `sqrt` rows are not written
as `differs`: they differ only where the others stop with an error, and the
caveat would follow nearly every PDK expression.

### 4.5 Instance parameters (7.3)

ngspice from `devhelp` (ngspice 45), Xyce from `Xyce -param` (7.10). HSPICE
and Spectre: one deck per device and name, against a made-up name as
control; a name is taken when it raises no warning or error the control
raises. Observed in HSPICE: a resistor takes `noise`, not `noisy`; `temp` is
taken by no device tried; a diode's `w`/`l` are taken at level 3; `m` of zero
or less stops the run for every device tried (in Spectre too); a current
source's PWL takes `r` and `td`; a capacitor takes `Q=`. In Spectre: a
resistor's noise switch is `isnoisy` (0 and 1 load), `trise` and `dtemp`
are both taken, no device tried takes `temp` except the inductor, and
`ic`/`off` on a diode, BJT or JFET draw a warning. Xyce refuses `m` of zero
or less on R, L and C, and takes negative `m` on D, Q and M; ngspice takes
`m=-2` and `m=0` on a resistor.

### 4.6 Pulse rise and fall (item 2)

A current pulse of width 10 ns into 1 F: with HSPICE `.tran 1n`, `tr=tf=0`
gives the same charge as `tr=tf=1n` (10.94 nC both), so zero means the time
step, as in ngspice (11.0 nC at step 1 ns, 12.0 nC at 2 ns). Spectre refuses
`rise=0`; left out, the charge is 10.08 nC, a default far below a 1 ns step.

### 4.7 Defaults and HSPICE spellings (c4)

Each value read from a deck written for it, run in the simulator named.

**TNOM and TEMP defaults.** A 1 V source across a 1k resistor with
`tc1=0.01`: with the TNOM set to 0 the current gives the default TEMP; with
TEMP set to 100 it gives the default TNOM.

| dialect | TNOM | TEMP | note |
|---|---|---|---|
| ngspice 45 | 27 | 27 | |
| ESPice (ngspice dialect) | 27 | 27 | |
| Xyce 7.10 | 27 | 27 | |
| VACASK | 27 | 27 | `sp_resistor` |
| Spectre | 27 | 27 | |
| HSPICE | 25 | TNOM | `.OPTION TNOM=0` with no `.TEMP` ran at 0 (the `temper` column) |

These are the `implied options` lines; CDL has none. LTspice's are 27 and
27 (section 8.3), so a translation into it states neither.

**SFFM.** ngspice 45 is `SFFM(VO VA FM MDI FC TD PHASEM PHASEC)`
(`vsrcload.c`: the modulating frequency third, the carrier fifth, MDI 90
when left out and cut to FC/FM). Measured: `sffm(0 1 10meg 0 1meg)` is
sin(2 pi 1M t). HSPICE and Xyce are `SFFM(VO VA FC MDI FS)`: Xyce matches
sin(2 pi 10M t + 0.5 sin(2 pi 1M t)) to the printed digits; HSPICE to its
print step; HSPICE's MDI is 0 when left out and FS 1/TSTOP. ESPice follows
ngspice (`net_waves.zig`).

**HSPICE.** `.OPTION GSHUNT= CSHUNT= DELMAX=` load; 1 mA into 1k with
`gshunt=1m` and `cshunt=1n` settles at 0.5 V. `.PARAMETERS` is `.PARAM`.
`.DCVOLT v(p)=1` and `.DCVOLT q 2` both set the start of a UIC transient.
`.FUNC` does not load (either argument spelling). A unary `!` loads
(`'1k*(!0)'` is 1k); `'10 % 3'` does not. A double-quoted `.param
t2="a^3"` is an expression (8 with a=2); read as one since d3 (4.9).

**ngspice 45.** `.options gshunt=1m` leaves 1 mA into 1k at 1 V in an
operating point; `rshunt=1k` gives 0.5 V. `!` works in `.param`, instance
braces and B sources; `%` in `.param` (10 % 3 is 1) but not in a B source.
`.meas ... deriv` and `err1`/`err2` print "currently not supported"
(`com_measure2.c`). Xyce refuses a unary `!`. Spectre takes `!` and refuses
`10%3`. ESPice takes both `!` and `%` in its ngspice dialect.

**HSPICE tolerances, GMINDC, BDF and POST (c5).** Four decks, each run
with one option changed and read back through `.measure` (HSPICE, ten
digits), `.measure` (ngspice 45, Xyce 7.10, ESPice), a PSF file (Spectre)
or the raw file (VACASK).

- *gmin.* 1 V through 1G into a reverse diode (`is=1e-20`), an
  operating point and a 10 us transient; V(a) is 0.999 V with the default
  gmin and 0.5 V with 1 nS across the junction. HSPICE: `gmindc=1e-9`
  gives 0.5 at t=0 and 0.999 at 5 us; `gmin=1e-9` gives 0.999 at t=0 and
  0.5 at 5 us; both give 0.5 throughout. So GMINDC is the DC and
  operating-point gmin and GMIN the transient one. ngspice, ESPice, Xyce
  (`.options device gmin=`), Spectre and VACASK each give 0.5 in both with
  one `gmin=1e-9`. Mapping: GMINDC reads into its own slot, written as
  `gmin` elsewhere with a caveat; HSPICE GMIN keeps its reading as gmin,
  now with a caveat; another dialect's gmin is written into HSPICE as
  both `gmin=` and `gmindc=`, which is exact. Different GMIN and GMINDC
  values cannot both be said in one gmin: an error.
- *ABSV, RELV, ABSI.* A 5 V source, 10 ohm and three diodes in series,
  operating point. HSPICE, with RELI=1 and ABSI=1 so that only the voltage
  test stops Newton: `absv=1` and `vntol=1` give the same V(a) to ten
  digits (2.3896202016, against 2.3813462420 without), and so do `relv=1`
  and `reltol=1` (2.3813462523). With the current tolerances left at their
  defaults, `reltol=1` moves nothing: HSPICE's RELTOL is RELV, voltages
  only, and RELI is the current one. A diode on a stepped source gave the
  same for ABSI against ABSTOL (a crossing time of 1.743061974 us for both,
  1.743719900 us without). ngspice and ESPice: `reltol=1` alone moves the
  operating point (2.410726 against 2.396933 in ngspice), as much as
  `reltol=1 abstol=1`; `vntol=1` or `abstol=1` alone moves nothing,
  together they do. So ngspice's reltol bounds currents as well as
  voltages, and Spectre's (`reltol=0.9` alone moves it) likewise. Mapping:
  ABSV is vntol and ABSI is abstol, plain; RELV is reltol with a caveat,
  and a reltol from another dialect is written into HSPICE as `reltol=`
  and `reli=`. RELI is read only where it repeats RELTOL; a value of its
  own has no counterpart and stays an error.
- *METHOD=BDF.* A 1 uH, 1 nF tank started at 1 V, run 20 us (100
  periods) with the step held to 10 ns; the largest V over the last
  microsecond. HSPICE: TRAP 0.10, GEAR 0.0051, GEAR with MAXORD=1 0,
  BDF 0.777 (MAXORD 1 or 2 changes nothing). ngspice 45 at the same
  step: trap 0.997, gear 0.022, gear with maxord=1 0, and maxord 3 to 6
  changes nothing. BDF is a higher-order method than any of them; the
  closest form elsewhere is gear (gear2 in Spectre and VACASK), with a
  caveat that it damps far more.
- *POST.* The tolerance deck with and without `post` gives the same
  measurements to ten digits. It is dropped crossing out of HSPICE with an
  info note (`inert options post`).

The ESPice suite's `hspice/gshunt.sp` (all six options at once) now
translates with no error to ngspice and ESPice, and both give the
oracle's 0.5 V.

### 4.8 Pole-zero ports (d2)

ngspice names a pole-zero analysis by its input and output node pairs
(`.pz in 0 out 0 vol pz`); HSPICE by an output signal and a source
(`.pz v(out) vin`); Spectre by its output terminals and a probe instance
(`pz1 (out 0) pz iprobe=vin`). The writer turns each half into the form
the target takes (`pzPorts` in `src/writer.zig`):

- **Input.** A node pair becomes the one independent source of the
  matching kind (V for `vol`, I for `cur`) that connects exactly those two
  nodes, either way round. None or several is an error naming the pair; a
  source is never made up. A source becomes its own nodes, `vol` or `cur`
  by its kind.
- **Output.** `out_pos 0` is `v(out_pos)`, and a signal `v(a)` or
  `v(a,b)` is the pair `a 0` or `a b`. Spectre takes both terminals.
- **`pol`, `zer`.** HSPICE and Spectre always find both: one alone is a
  caveat. Read back, the find is `pz`.

Measured on five decks written for this, ngspice 45 against HSPICE
Y-2026.03 and Spectre 23.10, each ngspice deck translated by sprack. Poles
and zeros in rad/s (Spectre reports Hz; multiplied by 2 pi here):

| deck | ngspice | HSPICE | Spectre |
|---|---|---|---|
| RC low-pass, 1k, 1n | pole -1.000e6 | pole -1.000e6 | pole -1.000e6 |
| same, source reversed (`vin 0 in`) | pole -1.000e6 | pole -1.000e6 | pole -1.000e6 |
| RC, current input reversed, 1k shunt | pole -5.000e5 | pole -5.000e5 | pole -5.000e5 |
| RLC band-pass, 1m, 1n, 100 | poles -5.000e4 +-9.98749e5j, zero 0 | same | same |
| two-stage, differential output `o2p o2n` | 5 poles, 3 zeros (below) | no form | as ngspice to 6 digits |

The two-stage deck: an RC input, two stages of transconductors with
crossed 0.5 pF feedback capacitors, the halves deliberately unequal.
ngspice and Spectre both give poles -1.000e9, -3.08083e8, -3.00079e8,
-1.58688e5, -1.52747e5 and zeros -3.04051e8, -1.55722e5, 4.4512e9; the
rational function they form matches the circuit's own response, computed
by a separate nodal solve, to four digits from 1e5 to 1e10 rad/s.

HSPICE accepts `.pz v(o2p,o2n) vin` without a word but gives poles
-1.58688e5, -3.00079e8, -1.000e9 and zero 4.000e9: exactly what it gives
for `.pz v(o2p) vin`, and `.pz v(o2n,o2p) vin` gives exactly `v(o2n)`'s.
The second node is not used. So a differential output written for HSPICE
is an error, and an HSPICE `v(a,b)` read for another dialect is a caveat
that HSPICE found `v(a)`'s poles and zeros.

A reversed source flips the sign of the transfer function and nothing
else: same poles and zeros in all three, and in ngspice for both pair
orders. HSPICE names no orientation, so ngspice `.pz in 0 ...` across
`vin 0 in` comes back as `.pz 0 in ...` (an info note); with the source
the same way round as the pair the round trip is exact.

An exactly symmetric version of the two-stage deck has repeated roots;
there ngspice reported one of the doubled poles (-3.01e8) as a zero, where
Spectre agreed with the hand-worked answer. Not a translation
matter; the deck above is unequal for that reason.

### 4.9 Double quotes (d3)

Where a double-quoted value is an expression and where a string. Each
row a deck of a few lines written for it: a 1 V source across the
resistor, its current read back (`.meas`, the `.print` column or the raw
file). HSPICE Y-2026.03-SP2-1, Spectre 23.10, ngspice 45, Xyce 7.10, ESPice.

| written | HSPICE | ngspice 45 | Xyce 7.10 | Spectre | ESPice |
|---|---|---|---|---|---|
| `.param a=2 t2="a^3"` (`a*3` elsewhere), used as `t2*1k` | 8k: expression | refused | refused | a string: 0 A as a number | 6k: expression |
| `r1 a 0 "2*rv"`, rv=1k | 2k | refused (taken for a model name) | refused | no such form | refused |
| `r1 a 0 r="2*rv"` | 2k | refused | refused (no number) | refused | 2k |
| `"2 * rv"`, blanks inside | 2k | | | | |
| `.model rmod r rsh="rv/10"`, l=10u w=1u | 1k | | | | |
| subcircuit default `rv="3*rv0"`, instance `rv="2*rv0"` | 3k, 2k | | | | |
| `v2 b 0 "vv*3"` and `dc="vv*3"`, vv=2 | 6 V both | | | | |
| `.temp "tv*2"`, tv=50, tc1=0.01 | 100 degrees (1.75k) | | | | |
| `.tran "st" "10*st"` | loads; a pulse at 2*st is seen by 9n | | | | |
| `.meas dc ib param="ia*2"` | twice ia | | | | |
| `.param n="4"` | 4 | | | | |
| `.param s="abc"` | refused: abc is no parameter | | | | |
| `.include "dir/inc-a.sp"`, `.lib "dir/lib.l" tt` | the files (5k, 9k) | | | | |
| `.option search="sub"` then `.include "inc_b.sp"` | found in sub (7k) | | | | |
| `.meas dc "ia" find ...` | the measurement ia | | | | |
| `rlgcfile="line.rlgc"`, `tstonefile="m.s1p"` | the files, the same as unquoted | | | | |
| `'3*"a"'` and `"3*'a'"` | both refused | | | | |

So HSPICE reads `"..."` in a value as it reads `'...'`; the slot decides,
not the quote. Each grammar says which: `quotes '"' expr-in-values except
rlgcfile tstonefile` in HSPICE, `quotes '"' expr-in-values` in ESPice
(read leniently: its positional refusal is not modelled), `quotes '"'
string` in ngspice, Xyce and Spectre. Read as an expression, the value is
written in the target's form (`{a**3}`, `'a**3'`, `a**3`). A path slot
(`.include`, `.lib`, `.hdl`), an option not declared in the grammar and a
key in the `except` list keep the string, written quoted; a `name` slot
takes the quotes off.

`hspice/hspice_expressions.sp` (Conformance Suite 9830a79c), translated
to ngspice and to ESPice and run there: i(vdd) -1.66667e-4, i(v2)
-1.25e-4, i(v3) -1e-3, i(v4) -2.5e-4, its `.expected.json` in both.
Before, `t2` was written as the string `"a^3"`, which ngspice refuses.

### 4.10 Blanks around Spectre operators (g1)

Spectre 25.10, one deck per expression: `parameters a=2 b=3`, then
`parameters t=<expr>` driving a 1 V-per-unit source, the node voltage read
back.

| written unspaced | Spectre 25.10 |
|---|---|
| `a<=b` `a>=b` `(a<=b)` `(a>=b)` | 1, 0, 1, 0 |
| `a==b` `a<b` `a>b` | 0, 1, 0 |
| `a&&b` `a\|\|b` `(a<b)&&(b>a)` `(a<b)\|\|0` | 1, 1, 1, 1 |
| `a**b` `a**-1` | 8, 0.5 |
| `a*-b` `a+-b` `a/-b` `-a` | -6, -1, -0.667, -2 |
| `a==-b` `a<=-b` `a>=-b` | 0, 0, 1 |
| `a&&!b` `a\|\|!b` `a==!b` `a-!b` `!a` `!(a == b)` | 0, 1, 0, 2, 0, 1 |
| `a!=b` `a!= b` `a!=-b` `a!=(b)` `a!=1` `!(a!=b)` | all refused |
| `a !=b` `a != b` `(a)!=b` `2!=b` | 1 each |

So only `!=` needs a blank, and only before it after a name: there the `!`
is taken as part of the name (`a!`), as in a global node `vdd!`. The
grammar spells it `ne " != "`; a blank at the end of an operator spelling
is written unless the text has one there already. SPRack itself reads
`a!=b` as `a`, `!=`, `b` in every dialect.

`global`: `global 0` followed by `global 0 vdd`, and `global 0 vdd`
alone, give the same current (1.5 mA, a subcircuit resistor to the global
`vdd`); with no global line at all 0 is still ground but `vdd` is local
(0.5 mA); `global 0` then `global vdd` is refused, as the first node of a
global line is the ground. `preamble unless global` now leaves out the
`global 0` line when the netlist writes a global statement.

`hspice/hspice_expressions.sp` (Conformance Suite 9830a79c), translated
to Spectre and run in 25.10: i(vdd) -1.666667e-4, i(v2) -1.25e-4, i(v3)
-1e-3, i(v4) -2.5e-4, its `.expected.json`. Before, the deck was refused
at `a!=b`.

### 4.11 A conditional block as conditional values (s1)

Xyce and LTspice have no conditional blocks but have a choice inside an
expression. A subcircuit written for it: `R1` in a two-level block (`.if
(sw == 0)` holding `.if (floor(n/2)*2 != n)` with 1k*n and 2k*n, then
`.elseif (sw == 1)` with 5k and `.else` with 7k+n), beside `R2` of 1 MOhm
under `.if (z == 0)` and of `1meg/z` otherwise. Five instances, each across
its own 1 V source. ngspice 45 runs the blocks; Xyce 7.10 and LTspice
26.0.2 run the translation, whose subcircuit holds

```text
R1 a b {(sw == 0) ? ((floor(n/2)*2 != n) ? (1k*n) : (2k*n)) : ((sw == 1) ? (5k) : (7k+n))} tc1=0
R2 a b {(z == 0) ? (1meg) : (1meg/z)}
```

in Xyce and `{if(sw == 0, if(floor(n/2)*2 != n, 1k*n, 2k*n), if(sw == 1,
5k, 7k+n))}`, `{if(z == 0, 1meg, 1meg/z)}` in LTspice. Source currents
(ngspice `print`, Xyce `.print dc`, LTspice `.meas op` in the log, which is
single precision):

| instance | branch taken | ngspice 45 | Xyce 7.10 | LTspice 26.0.2 |
|---|---|---|---|---|
| `n=1 sw=0` | n odd: 1k | -1.00100000e-3 | -1.001000000e-3 | -1.00100006e-3 |
| `n=2 sw=0` | n even: 4k | -2.51000000e-4 | -2.510000000e-4 | -2.50999990e-4 |
| `n=3 sw=1` | `.elseif`: 5k | -2.01000000e-4 | -2.010000000e-4 | -2.01000003e-4 |
| `n=4 sw=2` | `.else`: 7004 | -1.43775557e-4 | -1.437755568e-4 | -1.43775556e-4 |
| `n=5 sw=0 z=4` | n odd: 5k, and `R2` 250k | -2.04000000e-4 | -2.040000000e-4 | -2.03999996e-4 |

The first four have z=0, so `1meg/z` stands in the branch not taken:
neither Xyce nor LTspice objects to it there.

Only a device's value is made a choice. ngspice 45 does not make a `.param`
in a branch conditional. The deck: `.param top=2`, then `.if (top == 2)`
`.param g=3` `.else` `.param g=5` `.endif` at the top level, and in a
subcircuit with `sw=0` `.if (sw == 0)` `.param k=1` `.else` `.param k=2`
`.endif` and `R1 a b {k*1k*g}`, instantiated with sw=0 and with sw=1,
each across 1 V. Both instances draw -1.00000e-4 A: 10k, k=2 and g=5, the
last definition of each. Conditional parameters would give -3.33e-4 (3k)
and -1.67e-4 (6k). A block whose `.param` lines differ is therefore not
merged, and its error says that only a device's value is written as a
choice.

IHP SG13G2, all corners, to Xyce: 27 conditional blocks were errors; 6 are
now written (three blocks of the MIM capacitor subcircuit, in the plain and
the mismatch file), 21 are still errors: 12 choose the transistor's model
by a parameter, 8 give `ic` in one branch only, 1 holds a device of another
name and model in each branch.

### 4.12 What an EXP source leaves out (s2)

`EXP(0 1)`, `EXP(0 1 3n)`, `EXP(0 1 3n 0.5n)`, `EXP(0 1 3n 0.5n 6n)` and
`EXP(0 1 3n 0.5n 6n 0.25n)`, each across 1k, with `.tran 2n 50n` and a
largest step of 0.05 ns. TD1, TAU1, TD2 and TAU2 were fitted to every solver
point of the waveform (ngspice `wrdata`, Xyce `.print tran`, the VACASK raw
file); LTspice was read at 60 times through `.meas tran ... find v() at`.
All four reproduce the six given values of the last source.

| left out | ngspice 45 | Xyce 7.10 | LTspice 26.0.2 | VACASK |
|---|---|---|---|---|
| TD1 | the step (2 ns) | 0 | 0 | 0 (`delay`) |
| TAU1 | the step | the step | 0: an instant rise | 0: the run stops (operating point, or "Timestep too small") |
| TD2 | TD1 plus the step | TD1 plus the step | 0: the fall starts with the rise | refused: "td2 ... must be greater than 0"; it counts from `delay` |
| TAU2 | the step | the step | 0: an instant fall | 0: "Timestep too small" |

In LTspice `EXP(0 1)` and `EXP(0 1 3n)` stay at 0 V, `EXP(0 1 3n 0.5n)` is
`-exp(-(t-3n)/0.5n)` from 3 ns on, and `EXP(0 1 3n 0.5n 6n)` rises as given
and drops at 6 ns to that same curve.

The grammars now say it: `implied vsource td1 = 0 wave=exp` in Xyce, LTspice
and VACASK (read from them, the 0 is in the netlist; `exp(0 1 0)` in
ngspice), and `default ... td1 wave=exp : tran.step from ngspice espice`
(written into them, ngspice's step is said; `exp(0 1 1n)` in Xyce). LTspice
also takes TAU1, TAU2 and `td1 + tran.step` for TD2 from ngspice, ESPice and
Xyce, and has `invalid` lines for the three, so a source read from LTspice
without them is an error. VACASK's TD2 is now written out as well
(`delay=1n td2=1n` for `EXP(0 1)` at a 1 ns step), where it was an error.
ESPice was not run here: it is listed with ngspice on the word of the
Conformance Suite deck `netlist/tran/source_exp_defaults_ngspice` (TD1 =
TAU1 = TAU2 = 1n, TD2 = 2n at a 1 ns step). HSPICE and Spectre were not
measured and their grammars are unchanged: a source from them that leaves
TD1 out is written as it was, with an `ambiguous` warning.

### 4.13 A resistor model's NARROW and SHORT (s3)

`.model ... R RSH=1000` with NARROW and SHORT, a resistor of the model
across a 1 V source, the current read back (ngspice `print`, Xyce `.print
dc`).

| card | L, W | ngspice 45 | Xyce 7.10 |
|---|---|---|---|
| `NARROW=1u` | 11u, 2u | 0 A: open | -1.0e-4 (10k) |
| `NARROW=1u` | 11u, 5u | -2.72727273e-4 (3666.7) | -4.0e-4 (2500) |
| `NARROW=1u` | 20u, 4u | -1.0e-4 (10k) | -1.578947368e-4 (6333.3) |
| `SHORT=1u` | 11u, 5u | -5.55555556e-4 (1800) | -4.545454545e-4 (2200), with a netlist warning on the card |
| `NARROW=1u SHORT=0.5u` | 11u, 5u | -3.0e-4 (3333.3) | -4.0e-4 (2500), with the warning |
| neither | 11u, 5u | -4.54545455e-4 (2200) | -4.545454545e-4 (2200) |

So ngspice 45 computes RSH (L - 2 SHORT) / (W - 2 NARROW), and Xyce 7.10
RSH (L - NARROW) / (W - NARROW), with no SHORT. A Xyce card with NARROW = n
is the ngspice card with NARROW = SHORT = n/2 for every L and W, by
substitution; an ngspice card has a Xyce form only when its SHORT equals
its NARROW (Xyce NARROW twice that). VACASK's `sp_resistor`, the same six
rows from the raw file: 0, -2.727272727e-4, -1.0e-4, -5.555555556e-4,
-3.0e-4 and -4.545454545e-4 A, ngspice's formula.

Each grammar says its formula in a `computes resistor narrow short` line.
A card with NARROW or SHORT that crosses between two dialects whose lines
differ (ngspice or VACASK and Xyce, either way) is copied with a `caveat`
warning that states both formulas; between ngspice and VACASK, and to or
from a dialect not measured (HSPICE, Spectre), nothing is added to the
general model caveat. The card is not converted: the exact form exists one
way only, and a model card's parameters have no `convert`.

### 4.14 A parameter defined inside a subcircuit, set from an instance (u1)

A subcircuit `rr` holding `R1 a b {r0}`, and four instances of it in the
order X2, X1, X3, X4, each across its own 1 V source; X2 and X4 give no
parameter. The source currents are read back (ngspice `print`, Xyce `.print
dc`, the VACASK raw file, LTspice `.meas op` in the log, which is single
precision). In the first two rows X1 gives `r0=4k` and X3 `r0=2k`; in the
last three X1 gives `a=2k` and X3 `a=500`. Currents in the order X2, X1, X3,
X4, their sign left out.

| the subcircuit declares | ngspice 45 | Xyce 7.10 | LTspice 26.0.2 |
|---|---|---|---|
| `.param r0=1k` inside | 1 mA, 250 uA, 500 uA, 1 mA | 1 mA, 250 uA, 500 uA, **500 uA** | 1 mA, 250 uA, 500 uA, 1 mA |
| `r0=1k` on the header | 1 mA, 250 uA, 500 uA, 1 mA | 1 mA, 250 uA, 500 uA, 1 mA | 1 mA, 250 uA, 500 uA, 1 mA |
| `.param a=1k` and `.param r0={2*a}` inside | 500 uA, 250 uA, 1 mA, 500 uA | 500 uA, 250 uA, 1 mA, **1 mA** | 500 uA, 250 uA, 1 mA, 500 uA |
| `a=1k r0={2*a}` on the header | 500 uA, 250 uA, 1 mA, 500 uA | 500 uA, 250 uA, 1 mA, 500 uA | 500 uA, 250 uA, 1 mA, 500 uA |
| `a=1k` on the header, `.param r0={2*a}` inside | 500 uA, 250 uA, 1 mA, 500 uA | 500 uA, 250 uA, 1 mA, 500 uA | 500 uA, 250 uA, 1 mA, 500 uA |

So ngspice 45 and LTspice 26.0.2 take an instance's value for a parameter
defined inside the subcircuit as they take one for a header parameter: for
that instance alone. Xyce 7.10 takes it too, and keeps it for the later
instances that give none (X4 has X3's value); it does so only for a
parameter the header does not declare, and prints no warning. ngspice reads
`.params` as `.param` here (the same four currents). VACASK (b2c1551) has no
header parameters: its `parameters` lines inside the subcircuit are the
declaration, and the translations of the first and third deck (`parameters
r0=1k`; `parameters a=1k` and `parameters r0=2*a`) give 1 mA, 250 uA, 500
uA, 1 mA and 500 uA, 250 uA, 1 mA, 500 uA.

What a Xyce 7.10 header default may be, each with the currents right for all
four instances: an expression of a header parameter that comes after it
(`params: r0={2*a} a=1k`); of a parameter of the netlist (`.param g=1k`,
`params: r0={2*g}`); of a function, the `.func` standing inside the
subcircuit or outside it; and `{1k*agauss(1,s,1)}` under `.sampling` (three
samples, seed 7), which draws the same twelve values as the same `.param`
inside does.

A name on the header and inside (`r0=1k` on the header, `.param r0=3k`
inside): in ngspice 45 the inner value is the default (X2 and X4 draw
333.333 uA, X1 and X3 their own 250 and 500 uA); in Xyce 7.10 the header's is
(1 mA). A parameter the subcircuit declares nowhere is refused on an
instance by ngspice 45 ("Mismatch: 0 formal but 1 actual params"), so every
parameter an ngspice instance gives is one of the two kinds above.

The Xyce grammar now says it: `hoist param from ngspice ltspice`. A
subcircuit's parameter statements read from those two are written on its
header, in order, a later value of a name replacing an earlier one, with one
`oneway` info a file (the output reads back as header parameters). Xyce's
own stay where they are. HSPICE and ESPice were not measured: theirs stay
too, with one `ambiguous` warning a file. Spectre's and VACASK's
`parameters` lines are read as the header already. A parameter inside a
conditional block of the subcircuit is not moved.

IHP SG13G2, `capacitors_mod.lib` to Xyce: three subcircuits change, 26
parameter statements in all. `cap_cmim` was

```text
.subckt cap_cmim PLUS MINUS
.param l=7u
.param w=7u
.param mm_ok=0
.param sf=1u
.param ic=1e10
```

and is `.subckt cap_cmim PLUS MINUS params: l=7u w=7u mm_ok=0 sf=1u
ic=1e10`. A deck in its shape (`l`, `w`, `sf`, `ic` and `carea={1.5m*(l/sf)*(w/sf)*1p}`
as `.param` lines inside, `C1 PLUS MINUS {carea}`), four instances giving
nothing, `l=10u w=10u`, `l=20u`, nothing, each across a 1 V AC source,
`.ac lin 1 1meg 1meg`; the imaginary part of the source currents:

| | first | `l=10u w=10u` | `l=20u` | last |
|---|---|---|---|---|
| ngspice 45 | -4.61814e-7 | -9.42478e-7 | -1.31947e-6 | -4.61814e-7 |
| Xyce 7.10, the translation before | -4.61814120e-7 | -9.42477796e-7 | -1.31946891e-6 | **-1.31946891e-6** |
| Xyce 7.10, the translation now | -4.61814120e-7 | -9.42477796e-7 | -1.31946891e-6 | -4.61814120e-7 |

---

## 5. Enum spellings (6.5): integration method

| dialect | grammar | verdict | source |
|---|---|---|---|
| ngspice | `trap=trap gear=gear` | correct | `src/spicelib/analysis/cktsopt.c:141-146` (`trap` matches as a prefix, `gear` exactly; anything else is `E_METHOD`) |
| Xyce | `trap=trap gear=gear trap=7 gear=8` | correct | `doc/Reference_Guide/timetbl.tex:19-23` ("trap or 7", "gear or 8"; trap is the default) |
| VACASK | `trap=trap gear=gear2 euler=euler` | correct | `lib/coretran.cpp:585-591`; `docs/cmd-options-tran.md` |
| HSPICE | `trap=trap gear=gear bdf=bdf` | correct | observed: `.option method=trap`, `method=gear` and `method=bdf` each load with a `.tran`; BDF is a method of its own (4.7), written elsewhere as gear (`bdf=gear`, `bdf=gear2`) |
| Spectre | `trap gear2 euler` | correct | observed: `tran stop=1m method=trap`, `method=gear2` and `method=euler` each load and run |

---

## 6. Summary

### Wrong (9)

1. **Xyce `log` is base 10.** Change `ln = ln log` to `ln = ln` and `log10 = log10 log`. (4.1) **Fixed in 4a70b88c.**
2. **Xyce `^` is XOR.** Change `pow "**" "^"` to `pow "**"` and `xor "^"`. (4.2) **Fixed in 4a70b88c.**
3. **Xyce has no VBIC level 10.** Change to `npn level=11 | npn level=12` (11 is 3-terminal, 12 is 4-terminal); the same for pnp. (3.2) **Fixed in 4a70b88c.**
4. **Xyce has no `sw`/`csw` model types.** Use `vswitch = vswitch` and `cswitch = iswitch`. (3.2) **Fixed in 4a70b88c.**
5. **ngspice `nhfet`/`phfet` without a level is a MESFET.** Use `hfet n = nhfet level=5 | nhfet level=6`, and the same for p. (3.1) **Fixed in 4a70b88c.**
6. **VACASK `no bsource` is wrong.** Add `rule bsource = name "(" pos neg ")" { v=v i=i ...params }` before `rule instance`. (1.4, V1) **Fixed in 8ee108cb** (two rules, `v=v!` and `i=i!`).
7. **VACASK `no tf` is wrong.** Add `rule tf = "analysis" name?tf$# "dcxf" { out="out" ...params }`, with a caveat for the missing output resistance. (1.4, V5) **Fixed in 8ee108cb**; the input source is a loss error, since dcxf reports every source.
8. **VACASK subckt parentheses are mandatory.** Change to `open "subckt" name "(" ports* ")"`. (1.2) **Fixed in 8ee108cb.**
9. **VACASK `v0`/`v1` are not source parameters.** Drop them from the source rules. (1.2 item 6) **Fixed in 8ee108cb.**
10. **HSPICE has MESFETs** as J elements with an `njf`/`pjf` level-3 model. Done. (H3)
11. **HSPICE has `.DISTO`**, into a named load resistor; the `no` line now says so. (H4)
12. **Spectre has `vswitch` and `iswitch`.** Done. (S3, S4)
13. **HSPICE `limit()` is not the clamp.** Dropped from the table. (4.3)
14. **Spectre has `pwr`, `sgn`, `sign`, `nint`, `db`.** Added. (4.3)
15. **HSPICE `pow` and `**` cut the exponent to an integer**, and `nint` rounds halves away from zero. Written as before, with a `differs` caveat. (4.2, 4.3)

Gaps found alongside the verdicts (not counted as wrong):

* VACASK sine phase and damping are `tdphase`/`theta`, not mapped; `exp`, `pwl` and `fm` (sffm) exist but are not in the rules; `exp`'s `td2` is relative to `delay`; the pulse defaults differ from SPICE's.
* VACASK: `readscale` (K, x, X, meg, mil); the `functions`/`variables`/`operators` tables; `chgtol`; `icmode="uic"`; the temperature sweep; the `save` caveat for AC; the reason text of `no print`.
* VACASK has every statement kind in 1.4 except sens and switches. ic and nodeset are analysis parameters, so they need engine work.
* Xyce: `bsimcmg` level 111; level 57 for `bsimsoi`; `fmod` and `db`; `.LIN` for `sp`.
* HSPICE: `log`, `log10`, `sqrt` and `db` carry the sign of a negative argument instead of failing; `pwr` keeps the sign, as Spectre's does (ngspice's `.param` `pwr` drops it).

### Counts

Each table row or numbered claim above counts once. Descriptive rows (1.4, 1.5,
and the "has it?" findings) are not counted.

| section | correct | wrong | unclear |
|---|---|---|---|
| 1. VACASK: lexer (8), assumed lines (9 claims in 8 items; the ninth `assumed` is the header), other rules (12 claims) | 26 | 2 | 0 |
| 2. `no` lines (31) | 24 | 6 | 1 |
| 3. model levels (ngspice 11, Xyce 10, Spectre `bsimbulk` 1) | 19 | 3 | 0 |
| 4. functions, operators, variables (16) | 12 | 4 | 0 |
| 5. enums (5) | 5 | 0 | 0 |
| **total** | **86** | **15** | **1** |

The 18 HSPICE and Spectre rows were settled by running the tools (counts
above include them; the HSPICE `pow` row counts as correct, with its
caveat). The one left unclear is Xyce `no device` (X9). The VACASK `mutual` coupling to `sp_inductor` (1.4) is also
unclear and untested but is not counted.


---

## 7. Sweeps

What the sweep rules rest on. HSPICE and Spectre: observed by running decks
of a few lines written for this; the others: run locally (ngspice 45,
Xyce 7.10, VACASK b2c1551, ESPice 0.3.0) or cited.

| dialect | observed |
|---|---|
| Spectre | A `dc` or `ac` sweep whose stop equals its start is refused; with `start=f values=[f]` (and `lin=`, `dec=` or `step=` beside them) it runs one point. `lin=N` gives N+1 points, in `dc` and `ac`. `dev=` without `param=` sweeps the instance's own value (a source's dc, a resistor's resistance); `param=dc` on a resistor does not. `oct=`, `values=[...]` and `dc param=temp` are accepted. A `sweep` block runs the analyses inside it per point and nests. `paramset` columns must be netlist parameters. |
| HSPICE | `.STEP` is ignored with a warning: one run. `.TEMP t1 t2 t3` runs every analysis at each value. `.DC` of a `.PARAM`, `DEC`/`OCT`/`LIN np` (LIN counts points), `POI n v1 ... vn` followed by a second `LIN` sweep, `START= STOP= STEP=`, a zero-width sweep and `.DATA` rows all on one line are accepted, with the expected number of points. |
| VACASK | `instance="__topinst__" parameter="p"` sweeps a top-level parameter; `variable="p"` does not find it. Leaving out `parameter=` sweeps the principal one (docs/cmd-sweep.md). `option="temp"`, `values=[...]`, `mode="dec"` and a zero-width sweep run. A sweep applies to the one analysis after it (docs/cmd-sweep.md), hence `no step`. |
| Xyce | `.DC LIST v1 ...` and `.DC DEC v1 ...` put the type first; `.STEP DEC rv ...` too, but a list is `.STEP rv LIST ...` (`.STEP LIST rv` is refused). A second sweep may follow a list. `.DC` of a resistor, of a parameter, `.DATA` rows on one line, `.DC DATA=` and `.STEP DATA=` run. |
| ngspice | `.dc` of a parameter stops with "not in the circuit"; `.temp` with several values is ignored with a warning. No `.step` (hence `no step`). |
| ESPice | `.dc` of a parameter runs alone but not nested with a second sweep. A deck with `.data` is taken for HSPICE unless run with `--tokenizer ngspice` (a `caveat`). |

### Alters and SWEEP tails (c2)

Each alter deck changes a parameter, then an element, the temperature, a
model card and a library section in turn, and records the operating point
after each change. "Cumulative" means a later alter sees every earlier
change.

| dialect | observed |
|---|---|
| HSPICE | `.alter` blocks are cumulative for all five kinds of change; an alter may also add an element. `SWEEP` after `.tran`, `.ac`, `.dc` and `.op` (a step, `POI`, `DEC`, `LIN`, `DATA=`) runs that analysis once per point; on `.dc` it is the outer loop. |
| Spectre | Analyses run where they are written. `altergroup` and the one-change `alter` (`dev=`, `mod=`, `param=`, `param=temp`) are cumulative, across each other too. An altergroup takes `parameters`, instances, `model`, `options temp=` and `include ... section=`; an instance the netlist does not have is refused. Spectre 23.10 and 25.10. |
| VACASK | In the control block, `alter instance("__topinst__") p=v` changes a top-level parameter and `options temp=` the temperature for every later analysis; both stay set (b2c1551). |
| ngspice | `alterparam p=v` takes one parameter per line and needs `reset` to apply; `reset` drops an earlier `option temp=`, but keeps `alterparam` values. Once a `.control` block is present the dot analyses run only from it, and after the blocks ngspice runs them once more in the last state (45). |
| Xyce | No alter. A `.data` table with a `temp` column and parameter columns, swept with `.step data=`, runs once per row (7.10). |

Compared per run, a deck changing two parameters and the temperature
(`alt_pt`) and one changing a parameter, an element, the temperature and a
diode model (`alt_em`), both at `tnom=27`, translated from HSPICE:

| run | HSPICE v(b) | Spectre | Xyce (`alt_pt`) | VACASK | ngspice |
|---|---|---|---|---|---|
| base | 0.5000 | 0.5 | 0.5 | 0.5 | 0.5 |
| ra=3k | 0.2500 | 0.25 | 0.25 | 0.25 | 0.25 |
| temp 75 | 0.3304 | 0.330357 | 0.330357 | 0.330357 | 0.330357 |
| rb=2k | 0.4966 | 0.496644 | 0.496644 | 0.496644 | 0.496644 |

In `alt_em` (HSPICE against Spectre), v(b) is 0.5, 0.25, 0.4, 0.4966,
0.4966 in both; the diode voltage agrees at 27 degrees (0.6551) and moves
the same way with each change, 0.015 V lower in Spectre at 75 degrees,
where the two diode models' temperature terms differ.

## 8. LTspice (LTspice 26.0.2)

Observed: every statement below is what LTspice 26.0.2 did, in batch mode
(`tools/ltspice-batch.sh`), with a deck of a few lines written for the
question. Values were read back from `.meas` lines in the log (`.meas tran
m param p` for a parameter, `find v(n) at t` for a node) or from the
operating point in the `.raw` file. "Refused" means LTspice named the line
and ran nothing. Each expression was measured twice, in a `.param` and in a
B source whose operands are node voltages; the two agree unless said.

### 8.1 The `assumed` lines

| grammar line | verdict | observed |
|---|---|---|
| `block libsection` (`.lib name` ... `.endl [name]`) | correct | a file with sections `fast` (rv = 100) and `slow` (rv = 400), closed by `.endl fast` and by a bare `.endl`: loaded by section `slow`, a 100 ohm / rv divider from 1 V gives 0.8 V. The same file loaded whole, by `.lib file` or `.include`, is refused: there `.lib fast` is taken for a file name |
| `rule lib = ".lib" path section` | correct, as written (the path quoted) | `.lib "f.lib" slow` and `.lib 'f.lib' slow` load the section; `.lib f.lib slow` is refused, the section read as part of the file name. `.lib file` with no section loads the whole of a file without sections |
| `E`, `G` with `value=` | correct | `E1 b 0 value={3*v(a)}` with 2 V on `a` gives 6 V; `G1 0 c value={v(a)/1k}` into 1k gives 2 V; unbraced `value=4*v(a)` gives 8 V |
| `tline` with `zo=` | correct; `Z0=` is read too | 50 ohm source into `T1 b 0 c 0 Zo=50 Td=5n` and 50 ohm: half the step at the input, 5.0 ns to the far end. With `Zo=100` the input sits at 0.667; `Z0=100` gives the same 0.667 (now a `read` rule) |
| `O` with an LTRA model | correct | `.model lmod ltra(R=0 L=250n C=100p len=1)`: the far end follows 5.0 ns later, sqrt(LC) |
| POLY controlled sources | correct | `E poly(1) a 0 1 2 3` with 2 V: 17; `G poly(1) a 0 0 1m` into 1k: 2 V; `F poly(1) V1 0 1` and `H poly(1) V1 0 1k` with -2 mA in V1: -2 V each; `E poly(2) a 0 x 0 0 1 10 100` with 2 V and 3 V: 432, the SPICE coefficient order |
| `no print` | **wrong** | `.print tran v(a)`, `.print ac vdb(b)` and `.plot tran v(a)` load; nothing is printed and the `.raw` file holds every node as without them. `.probe v(a)` and an unknown `.foobar` are refused. Now a `print` rule for `.print` and `.plot` with a caveat |
| `nint = round` | spelling correct, value differs | `nint(2.5)` is refused (no such function). `round` of 0.5, 1.5, 2.5, 3.5, -0.5, -1.5, -2.5: 1, 2, 3, 4, -1, -2, -3, halves away from zero. Now `differs nint` |
| `hertz = freq` | **wrong** | `B1 b 0 V=v(a)*freq` and `R2 b 0 R=1k*freq/100` under `.ac` are refused ("no such parameter"), and so is `hertz`. Removed: the frequency has no name in an expression |
| `xor "^"` | correct | `2^3` and `5^3` are 0, `1^0` and `0^1` are 1, `0.4^0.6` is 1: exclusive-or of truth values, true above 0.5 (bitwise, `2^3` would be 1). It binds below `+`: `5 + 2 ^ 1` is 0. `2**3` is 8 |
| `mesfet p = pmf` | correct | `Z` devices on `.model mp pmf` and `.model mn nmf` at -2 V and 2 V: 6.25 mA and -6.25 mA |
| `bsim4` = level 14 or 54 | correct | both load and draw the same 116.14 uA at 1 V, 1 V (levels 8 and 49: 80.47 uA both). Of `toxe pclm theta neff` a level 14 card knows the first two, level 8 only `pclm`, level 3 only `theta`, level 2 only `neff`, level 1 and a card with no level none |
| `ltra = ltra` | correct | the model card above |

The comment on a DC value beside a waveform: `V1 a 0 dc 3 sine(1 2 1k)`
loads; the operating point has 3 V, the transient starts at 1 V (the
waveform) and reaches 3 V at a quarter period. `dc 3 ac 1 sine(...)`, the AC
part before the waveform, loads too.

### 8.2 Functions and operators

| expression | `.param` | B source |
|---|---|---|
| `-2**2`, `1+-2**2`, `2*-2**2` | 4, 5, 8 | 4, 5, 8 |
| `-(1+1)**2`, `0-2**2`, `2**-1` | 4, -4, 0.5 | same |
| `(-2)**3`, `(-2)**2.5`, `2**3**2` | -8, 0, 512 | same |
| `pwr(-2,2)`, `pwr(-2,3)`, `pow(-2,3)`, `pow(2,2.5)` | 4, 8, -8, 5.657 | same |
| `int(-2.7)`, `int(2.7)`, `floor(-2.5)`, `ceil(-2.5)` | -2, 2, -3, -2 | same |
| `log(100)`, `ln(100)`, `log10(100)` | 4.605, 4.605, 2 | same |
| `log10(-100)`, `sqrt(-4)` | -3.8e101, 0 | 0, 0 |
| `sgn(0)`, `sgn(-3)`, `u(0)`, `u(1)`, `stp(0)`, `stp(1)` | 0, -1, 0, 1, 0, 1 | same |
| `limit(5,0,2)`, `limit(-5,0,2)`, `limit(5,2,0)` | 2, 0, 2 | same |
| `uramp(-1)`, `uramp(2)`, `min(1,2)`, `max(1,2)`, `abs(-2)` | 0, 2, 1, 2, 2 | same |
| `atan2(1,-1)`, `hypot(3,4)`, `asinh(1)`, `acosh(2)`, `atanh(0.5)` | 2.356, 5, 0.8814, 1.317, 0.5493 | same |
| `sin(1)`, `cos(1)`, `tan(1)`, `asin(0.5)`, `acos(0.5)`, `atan(1)` | 0.8415, 0.5403, 1.557, 0.5236, 1.047, 0.7854 (radians) | same |
| `sinh(1)`, `cosh(1)`, `tanh(1)`, `exp(1)` | 1.175, 1.543, 0.7616, 2.718 | same |
| `if(1,3,4)`, `if(0,3,4)`, `if(0.4,3,4)`, `if(0.6,3,4)` | 3, 4, 4, 3 | same |
| `1 > 0 ? 5 : 6`, `0 ? 1 : 1 ? 5 : 6`, `1 ? 2 : 3 + 10` | 5, 5, 2 | same |
| `2 == 2`, `2 != 2`, `2 <= 2`, `2 >= 3`, `1 <> 2`, `!1`, `!0`, `5 % 3` | 1, 0, 1, 0, 1, 0, 1, 2 | same |
| `1 & 0`, `1 \| 0`, `3 & 5`, `1 \| 0 & 0`, `1 + 2 & 0` | 0, 1, 1, 0, 0 | same |
| `1 && 0`, `1 \|\| 0` | refused | refused |
| `agauss(1,0.1,3)`, `aunif(1,0.1)`, `unif(1,0.1)` | refused | |
| `mc(1,0.1)` twice, `gauss(0.1)` twice | 1.094 and 0.944; -0.015 and -0.187 | `mc` loads, `gauss` is refused |

What the grammar now says from this:

* A minus binds before `**` wherever it stands, also at the start and
  before a group, where every other simulator of section 4.4 gives -4 for
  `-2**2`: `differs minuspow`, a new name for `differs` that finds a unary
  minus on the base of a power.
* `pwr` drops the sign (`differs pwr`); `round` is `nint` with halves away
  from zero (`differs nint`).
* `&&` and `||` do not exist; `&` and `|` are the logical operators, of one
  precedence and taken from the left (`1 | 0 & 0` is 0), so they are not
  written for `&&` and `||`: `differs andor` says so on each use.
* `!` and `%` exist (`not`, `mod` in the operators table, which had made
  them errors); `stp` is a second spelling of `u`.
* `?:` exists beside `if()`; the grammar keeps writing `if()`, which is the
  same choice. `if` and the logical operators take a value above 0.5 as
  true; not written as `differs`, a condition being 0 or 1 in practice.
* The variables: `time` (a B source `V=time*1k` is 0.5 at 0.5 ms), `temp`
  (40 under `.temp 40`, 27 with none); `temper` is refused.
* `agauss`, `aunif` and `unif` do not exist, so the reason on the
  `statistics` lines now names `gauss()` and `mc()`.
* Expressions need no braces after `=`: `.param s = 2 * 3 t = 5` gives 6
  and 5, `B2 c 0 V=v(a) * 2 + 1` gives 5 for 2 V, `R2 a 0 R=2*500` is 1k.
  The lexer now has `expr after-equals`; before, such lines of an LTspice
  deck were not read. Braces in a B source load too (`v={v(a)*2}`).

### 8.3 Models, sources, measures, defaults

* MOS levels that load: 1 to 9, 12, 14, 44, 49, 54, 55, 73. Refused
  ("invalid level"): 10, 11, 13, 15, 16, 17, 47, 53, 57, 58, 60, 68, 70,
  72, 77. Which model levels 4 to 7, 9, 12, 44, 55 and 73 select was not
  established; the table claims only 1, 2, 3, 8/49 and 14/54.
* `d`, `npn`, `pnp`, `njf`, `pjf`, `vdmos` (an `M` with three nodes), `sw`
  and `csw` load and conduct the right way. A `sw` with `vt=1 vh=0.2`
  closes at 1.2 V rising and opens at 0.8 V falling; a `csw` with `it=1m
  ih=0.2m` at 1.2 mA and 0.8 mA.
* Sources, the same deck in ngspice 45 and (translated) in LTspice: pulse
  edges and period, `sin(1 2 1k 0.25m 500 90)` before and after its delay
  (3, 1.000, -0.557), `exp(0 1 1m 0.5m 3m 0.5m)` (0.8647 at 2 ms, 0.1329 at
  4 ms: the second delay is absolute in both), `pwl`, and a current source
  agree to four digits. `sffm(0 1 1k 5 10k)` is -0.985 at 20 us: the
  carrier is the third value, the signal the fifth.
* A pulse of two or three values is refused ("minimum of 4 parameters").
  With four the pulse stays up; with five (a fall time and no width) it is
  back at 0 at 5 ms, where ngspice holds it for the stop time. A zero rise or fall time is made a tenth of the width (0.1 ms for
  1 ms, 0.2 ms for 2 ms), where ngspice takes the .tran step (10 us). So
  the rule now needs delay and rise, and `default` lines write rise and
  fall from the .tran step and the width from its stop time.
* `sine(0 1)` without a frequency loads and stays at 0 (ngspice: one period
  over the run), so the frequency is required and such a source is an
  error, as for Xyce.
* `.meas`: `find .. at=`, `find .. when`, `when .. rise= / fall= / cross=`,
  `trig .. targ` with `val=`, `td=`, `avg`, `rms`, `min`, `max`, `pp`,
  `integ` with `from=` `to=`, `param expr` and `param={expr}` load and
  give the values expected of a 1 ms pulse (average 0.2875 over 4 ms, 80 us
  from 10% to 90%). The grammar had only the text form, so a measure from
  another dialect was an error; it now has ngspice's rules.
* `.tran 1m`, one number, runs to 1 ms: a `read` rule.
* Every log states `tnom = 27` and `temp = 27`: `implied options`.

### 8.4 The `no` lines

One deck with a line of each: `.pz`, `.sens`, `.disto`, `.hb`, `.pss`,
`.sp`, `.stb`, `.lstb`, `.hdl`, `.if` / `.elseif` / `.else` / `.endif`,
`.data` / `.enddata`, `.alter`, `.control` / `.endc`, `.xf`, `.dcmatch`,
`.pac`, `.pnoise`, `.pxf`, `.psp`, `.qpss`, `.envelope`, `.phasenoise`,
`.trannoise`, `.montecarlo` and `.probe` are each refused ("expected device
instantiation or directive here"). `.print`, `.plot`, `.four` and `.net`
are not. An `N` instance is refused; an `A` instance is refused for its
last word not being one of LTspice's own function names; a `Y` instance
is refused. So every `no` line stands except `print`.

### 8.5 Topologies

Each circuit with `.op`, with `.tran 1u 1m` and with `.tran 1u 1m uic`.

| circuit | observed | `requires` |
|---|---|---|
| node between two capacitors | runs, "WARNING: Node b is floating", the node at 1 nV; the same warning with UIC | `dc-path warning` |
| 1 mA into a node with only a capacitor | runs, "ERROR: Node a is floating and connected to current source I1", the node at 1e9 V (-1e9 V with a second source of 2 mA out); with UIC the same line, starting at 0 V | `cutset error` |
| two voltage sources in parallel, 1 V and 1 V, or 1 V and 2 V | stops in all three: "paralleled making an over-defined circuit matrix" | `no-vloop error` |
| 1 V source across an inductor | runs, 1000 A in the inductor: 1 milliohm in series | `no-vlloop warning` |
| two inductors in parallel fed through 1k | runs, 0.5 mA each and 0.5 uV across them | `no-lloop warning` |

### 8.6 Does a translation load

40 decks of the conformance suite, spread over its directories, read as
ngspice, with no include and an error-free translation to LTspice, and the
five core samples of `src/tests.zig` (ngspice, HSPICE, Spectre, Xyce,
VACASK), each translated and loaded.

| | before | after |
|---|---|---|
| suite decks loaded, of 40 | 37 | 37 |
| core samples loaded, of 5 | 0 | 0 |

The three suite decks that do not load are the same before and after: one
names a node that does not exist (a deck of the suite's `invalid` set),
one has a `pwl(...) r=` repeat, which LTspice calls an unknown parameter
and the grammar passes on with the source's other parameters, and a
100 x 100 resistor grid was still running at the 90 s limit. The five
samples are refused for one reason: "More than one analysis specified."
LTspice runs one analysis a deck (`.op`, `.dc`, `.ac`, `.tran`, `.noise`
together are refused); cut to their `.op` all five load. The grammar has no
way to say this yet, so a deck with several analyses is translated without
a word and does not load.

What changed for these decks is not whether they load but what they say:
`.temp 27` and `.options tnom=27` are no longer written, and a pulse
written with fewer values or zero edges now carries ngspice's meaning.

Left open: `.lib file` with no section in an LTspice deck is read as the
start of a section and reported as a block that is not closed; a seventh
value of `sine` (a cycle count: `sine(0 1 1k 0 0 0 3)` stops after three)
has no slot; the instance parameters of devices were not checked.

## 9. An inductor's model (ngspice 45, Xyce 7.10, VACASK b2c1551, LTspice 26.0.2)

Observed: every statement below is what the simulator did with a deck of
a few lines written for the question. The deck is a 1 A AC current source
into the inductor at 159.15494309 Hz, where 1 mH reads 1 V: `vm(a)` is the
inductance in mH. A model with `tc1=0.01` doubles it at 127 degrees
(nominal 27) and leaves it alone at 27, so a model that is used must show.
Read back from `.print ac vm(a)` (ngspice, Xyce) and from the raw file
(VACASK, which was also run at twice the frequency: twice each value
below). LTspice was given a current ramp of 1 A per ms, `pwl(0 0 1m 1)`,
and `.meas tran m find v(a) at=0.5m`: 1 V per mH, to 3 mV. "Refused"
means the simulator named the line and ran nothing.

### 9.1 ngspice and Xyce

The card is `.model lmod l tc1=0.01` unless the row says otherwise.

| line | card | degrees | ngspice 45 | Xyce 7.10 |
|---|---|---|---|---|
| `L1 a 0 1m` | none | 27 | 1.000 | 1.000 |
| `L1 a 0 l=1m` | none | 27 | 1.000 | 1.000 (at 127) |
| `L1 a 0 1m tc1=0.01` | none | 127 | 2.000 | 2.000 |
| `L1 a 0 lmod 1m` | | 27 | 1.000 | 1.000 |
| `L1 a 0 lmod 1m` | | 127 | 2.000 | 2.000 |
| `L1 a 0 lmod 1m` | `.model lmod l(tc1=0.01)` | 127 | 2.000 | 2.000 |
| `L1 a 0 lmod 1m tc1=0.03` | | 127 | 4.000 | 4.000 |
| `L1 a 0 lmod 1m m=2` | | 27 | 0.500 | 0.500 |
| `L1 a 0 lmod {lv}`, `.param lv=1m` | | 127 | 2.000 | 2.000 |
| `L1 a 0 1m lmod` | | 127 | refused: "unknown parameter (lmod)" | 2.000 |
| `L1 a 0 lmod l=1m` | | 127 | refused: "unknown parameter (l)" | 2.000 |
| `L1 a 0 l=1m lmod` | | 127 | refused: "unknown parameter (lmod)" | refused: "Unrecognized parameter LMOD" |
| `L1 a 0 lmod` | `.model lmod l ind=3m` | 27 | 3.000 | refused: "Could not find L parameter in instance", after "No model parameter IND found" |
| `L1 a 0 lmod 1m` | `.model lmod l ind=3m` | 27 | 1.000 | not run |
| `L1 a 0 lmod` | | 27 | 0.000 | refused: "Could not find L parameter in instance" |
| `L1 a 0 lmod` | `.model lmod l l=3m` | 27 | not run | refused, the same |
| `L1 a 0 lmod 1m` | `.model lmod l l=3` | 27 | not run | 3.000 |
| `L1 a 0 lmod 1m` | `.model lmod l l=3m` | 27 | 1.000 | not run |
| `L1 a 0 lmod 1m` | `.model lmod ind tc1=0.01` | 127 | refused: "unknown parameter (lmod)" | 2.000 |
| `L1 a 0 lmod 1m` | `.model lmod r tc1=0.01` | 127 | refused | refused |
| `L1 a 0 lmod 1m` | none | 127 | refused: "unknown parameter (lmod)" | refused: "Illegal value found for device L1 for parameter = L value = LMOD" |

So in both the model stands between the nodes and the value, the card's
type word is `l`, the model changes the result, and what the line says
(`tc1`) wins over what the card says. They part in four places:

* The value before the model, and `l=` after it, load in Xyce only.
* A line with a model and no value takes the card's `ind` in ngspice (0 H
  without one); Xyce refuses it whatever the card says.
* Xyce also takes `ind` for the card's type word.
* A card's `l` multiplies the line's value in Xyce (3 for 1 mH) and does
  not in ngspice; `ind` is ngspice's alone.

ngspice also takes the value after the model as a bare parameter name
(`L1 a 0 lmod lv`: 2.000) and in quotes (`L1 a 0 lmod 'lv*2'`: 4.000);
Xyce `L1 a 0 lmod {lv*2} tc1=0.03`: 8.000.

### 9.2 VACASK

With `load "spice/inductor.osdi"`. The card is `model lmod sp_inductor
(tc1=0.01)` unless the row says otherwise.

| line | card | degrees | read back |
|---|---|---|---|
| `L1 (a 0) inductor l=1m` | `model inductor sp_inductor` | 27 | 1 |
| `L1 (a 0) lmod l=1m` | | 27 | 1 |
| `L1 (a 0) lmod l=1m` | | 127 | 2 |
| `L1 (a 0) lmod l=1m` | `model lmod sp_inductor tc1=0.01` | 127 | 2 |
| `L1 (a 0) lmod l=1m tc1=0.03` | | 127 | 4 |
| `L1 (a 0) lmod l=lv`, `parameters lv=1m` | | 127 | 2 |
| `L1 (a 0) lmod l=1m $mfactor=2` | | 27 | 0.5 |
| `L1 (a 0) lmod l=1m m=2` | | 27 | refused: "Parameter 'm' not found." |
| `L1 (a 0) lmod` | `model lmod sp_inductor (ind=3m)` | 27 | 3 |
| `L1 (a 0) lmod l=1m` | `model lmod sp_inductor (ind=3m)` | 27 | 1 |
| `L1 (a 0) lmod` | | 27 | 0 |
| `L1 (a 0) lmod l=1m` | `model lmod inductor (tc1=0.01)` | 127 | refused: "Device 'inductor' not found." |
| `L1 (a 0) lmod l=1m` | none | 27 | refused: "Master 'lmod' not found." |

The instance names its model where every VACASK instance does, the type
word is the module, `sp_inductor`, and the card means what ngspice's does:
`tc1` under the line's own, `ind` where the line gives no value.

### 9.3 LTspice

| line | card | degrees | LTspice 26.0.2 |
|---|---|---|---|
| `L1 a 0 1m` | none | 27 | 1.003 |
| `L1 a 0 1m tc1=0.01` | none | 127 | 2.001 |
| `L1 a 0 1m` | `.model lmod l tc1=0.01` | 127 | refused, at the card: "Expected model definition here." |
| `L1 a 0 lmod 1m` | `.model lmod l tc1=0.01` | 127 | refused: "Unknown parameter", and the card as above |
| `L1 a 0 1m lmod` | `.model lmod l tc1=0.01` | 127 | refused, the same two |
| `L1 a 0 lmod` | `.model lmod l ind=3m` | 27 | refused, the same two |
| `L1 a 0 1m model=lmod` | `.model lmod l tc1=0.01` | 27 | refused, the same two |
| `L1 a 0 lmod 1m` | `.model lmod ind tc1=0.01` | 127 | refused, the same two |

LTspice has no inductor model: the card is refused even when no line
names it, and so is a model's name anywhere on the line.

### 9.4 Voltage and current source models

A source into 1k, `v(a)` read back; the question is whether a source can
name a model and whether that model can hold anything.

* ngspice 45: `V1 a 0 vm 2`, `V1 a 0 vm` and `V1 a 0 2 vm` with `.model vm
  v dc=5` are refused ("unknown parameter (vm)"), as is `I1 0 a im 2m` with
  `.model im i dc=5m`. A card no device names loads whatever its type word
  says (`v`, `vsource`, `i`, `isource`, `zzz`: 2.000 from `V1 a 0 2` each
  time), so a card that loads shows nothing.
* Xyce 7.10: `V1 a 0 vm 2` and `V1 a 0 vm` are refused ("Invalid DC value
  "vm" for device V1"), and `I1 0 a im 2m` likewise. `V1 a 0 2 vm` loads
  and reads 2.000, and so does `V1 a 0 2 zzz` with no card: the word is
  passed over. Cards of the five type words above load unused.
* LTspice 26.0.2: `.model vm v dc=5` and `.model im i dc=5m` are refused
  ("Expected model definition here."); `V1 a 0 vm 2`, `V1 a 0 2 vm` and
  `I1 0 a im 2m` are refused ("Unknown parameter").
* VACASK: `model vm vsource` with `V1 (a 0) vm dc=2` reads 2, and `model
  im isource` with `I1 (0 a) im dc=2m` reads 2. `model vm vsource (dc=5)`,
  `(type="dc")` and `(foo=1)`, and `model im isource (dc=5m)`, are refused
  ("Parameter 'dc' not found." and so on).

So only VACASK lets a source name a model, and that model is a name with
no parameter. The vocabulary keeps no model for a source: a VACASK source
of such a model is read as the source (the card an info, "only names a
built-in vsource"), and the Python package refuses to make a device from
such a card, saying so.

### 9.5 What the grammars say, and whether a translation loads

`inductor` has a `master` slot, placed as a resistor's and a capacitor's.
ngspice: `L pos neg master [l]`. Xyce: the same with the value required,
and it reads the value before the model and `l=` after it; its table
reads `ind` as well as `l`. VACASK: `L (pos neg) master l=`, written, and
read as any instance of a declared model is. LTspice: nothing.

Each source deck run, translated, and the translation run:

| source | read back | written | read back |
|---|---|---|---|
| ngspice `L1 a 0 lmod 1m tc1=0.03`, `.model lmod l tc1=0.01`, 127 degrees | 4.000 | Xyce `L1 a 0 lmod 1m tc1=0.03`, `.model lmod l tc1=0.01` | 4.000 |
| | | VACASK `L1 (a 0) lmod l=1m tc1=0.03`, `model lmod sp_inductor (tc1=0.01)` | 4 |
| ngspice `L1 a 0 lmod`, `.model lmod l ind=3m` | 3.000 | VACASK `L1 (a 0) lmod`, `model lmod sp_inductor (ind=3m)` | 3 |
| | | Xyce `L1 a 0`, an error: `inductor.master = lmod has no spelling in xyce` | refused |
| Xyce `L1 a 0 1m lmod`, `.model lmod ind tc1=0.01`, 127 degrees | 2.000 | ngspice `L1 a 0 lmod 1m`, `.model lmod l tc1=0.01` | 2.000 |
| | | VACASK `L1 (a 0) lmod l=1m`, `model lmod sp_inductor (tc1=0.01)` | 2 |
| VACASK `L1 (a 0) lmod l=1m $mfactor=2`, `model lmod sp_inductor (tc1=0.01)`, 127 degrees | 1 | ngspice `L1 a 0 lmod 1m m=2`, `.model lmod l tc1=0.01` | 1.000 |
| | | Xyce, the same two lines | 1.000 |

(The two decks written from VACASK got a `.print ac vm(a)` by hand: the
VACASK deck has no such line to translate.)

Into LTspice the line is written without its model, `L1 a 0 1m tc1=0.03`,
with two errors: `inductor.master = lmod has no spelling in ltspice` and
`ltspice.spgrammar has no spelling for model family 'inductor'`.

Left open: there is no HSPICE, Spectre or ESPice here, so their grammars
have no form for an inductor's model. Crossing into them it is the same
`loss` error (their tables, older than this section, do write the card),
and `L1 a 0 lmod 1m` in a deck of theirs is a line no rule understands. A
Xyce line with a model and no value is read, though Xyce refuses it. The
card's parameters are copied as written, with the standing caveat: a Xyce
card's `l`, a multiplier there, means something else in ngspice.
