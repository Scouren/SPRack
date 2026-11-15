# Grammar verification (PLAN.md Phase 2, handoff 6.1-6.5)

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
The grammar is right to give them no level.

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

These are the `implied options` lines; LTspice and CDL have none, so a
translation into LTspice always states both.

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

## 7. Sweeps (PLAN 5.1)

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
