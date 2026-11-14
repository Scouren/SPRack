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
| HSPICE, Spectre | checked by running the tools on decks we wrote (pending) | - |

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
   section. (The other `assumed` in the repo is `grammars/spectre.spgrammar:171`,
   `bsimbulk`; see 3.4.)

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

"pending tool check" means the claim has not yet been tested by running the tool.

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
| H1 | `no vswitch` | pending tool check | - |
| H2 | `no cswitch` | pending tool check | - |
| H3 | `no mesfet` | pending tool check | - |
| H4 | `no disto` | pending tool check | - |
| H5 | `no stb` | pending tool check | - |

### Spectre (4)

| # | line | verdict | source |
|---|---|---|---|
| S1 | `no disto` | pending tool check | - |
| S2 | `no measure` | pending tool check | - |
| S3 | `no vswitch` | pending tool check | - |
| S4 | `no cswitch` | pending tool check | - |

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

All level and master names, including Spectre `bsimbulk`: pending tool check.

---

## 4. Functions, operators, variables (6.3)

### 4.1 `log`

| dialect | grammar | verdict | source |
|---|---|---|---|
| ngspice | `ln = ln log` (log is natural) | correct | `src/spicelib/parser/inpptree.c:149-151` (B sources: `ln` and `log` are both `PTF_LOG`); `src/frontend/numparam/xpressn.c:127,158` (`.param`: both compute `log(x)`) |
| Xyce | `ln = ln log` | **wrong**: Xyce `log` is **base 10**; fixed in 4a70b88c | `src/UtilityPKG/ExpressionSrc/ExpressionParser.yxx:1424-1446` (natural only under `useHspiceMath`). `useHspiceMath_` defaults to false and is set only by `-hspice-ext math` or `all` (`src/IOInterfacePKG/N_IO_ParsingMgr.C:65,77-110`). `doc/Reference_Guide/Expression_Arithmetic_Functions.tex:205`: "LOG(x) ... log base 10". Proposed: `ln = ln` and `log10 = log10 log`. |
| HSPICE | `ln = log` | pending tool check | - |
| Spectre | `ln = log` | pending tool check | - |
| VACASK | `ln = ln` | correct, incomplete; fixed in 8ee108cb | `lib/context.cpp:52-54`: `log` and `ln` are both natural. Proposed: `ln = ln log`. |

### 4.2 Operators

| dialect | grammar | verdict | source |
|---|---|---|---|
| ngspice | `pow "**" "^"` | correct | `src/frontend/numparam/xpressn.c:706-707` (`**` becomes `^`); `src/spicelib/parser/inpptree-parser.y:94` |
| Xyce | `pow "**" "^"` | **wrong**: `^` is XOR by default; fixed in 4a70b88c | `ExpressionParser.yxx:1783-1792` (`^` is power only under `useHspiceMath`); `ExpressionLexer.l:268-269`; `doc/Reference_Guide/Expression_Operator.tex:29,35` (`**` is exponentiation, `^` is boolean XOR). Proposed: `pow "**"` and `xor "^"`. |
| HSPICE | `pow "**" "^"` | pending tool check | - |
| Spectre | `pow "**"`, `xor "^"` | pending tool check | - |
| VACASK | `pow "**"` | correct, incomplete; fixed in 8ee108cb | `lib/dfllexer.l:722` (`**`) and `:749-750` (`^` is `BITEXOR`); `docs/expr-operators.md`. Proposed: add `xor "^"`. |

### 4.3 Function tables and variables

| dialect | finding | verdict | source |
|---|---|---|---|
| ngspice | every listed name exists in at least one of its two parsers | correct | `xpressn.c:91-94` (`.param`), `inpptree.c:138-182` (B sources). Caveat: the parsers differ. `int`, `sqr`, `limit`, `agauss`, ... exist only in `.param`; `u`, `uramp`, `pwl`, `ddt` only in B sources. `pwr` discards the sign in `.param` (`xpressn.c:139-141`, `pow(fabs(z), x)`) but keeps it in B sources (VACASK's `docs/input-include.md` documents the same split). `nint` rounds half to even (`xpressn.c:150-155`). |
| Xyce | every listed name exists | correct | `src/UtilityPKG/ExpressionSrc/ExpressionLexer.l`, one line per name: `abs:556 min:548 max:547 sqrt:613 exp:308 pow:586 pwr:585 floor:575 ceil:574 int:583 sgn:610 sign:611 limit:576 agauss:607 gauss:608 aunif:606 unif:605 nint:572 atan2:563 stp:612 uramp:695 if:582`. Missing from the grammar: `fmod` (`:573`) and `db` (`:545`); added in 4a70b88c. Xyce `pwr` keeps the sign (`Expression_Arithmetic_Functions.tex:61-66`). |
| Xyce variables | `temper = temp`, `hertz = freq`, `time = time` | correct | `ExpressionLexer.l:592-597` (`time temp temper freq hertz` are all tokens) |
| HSPICE | function table | pending tool check | - |
| Spectre | function table | pending tool check | - |
| VACASK | see 1.2 item 8 | names correct, table incomplete | `lib/context.cpp:37-116` |

---

## 5. Enum spellings (6.5): integration method

| dialect | grammar | verdict | source |
|---|---|---|---|
| ngspice | `trap=trap gear=gear` | correct | `src/spicelib/analysis/cktsopt.c:141-146` (`trap` matches as a prefix, `gear` exactly; anything else is `E_METHOD`) |
| Xyce | `trap=trap gear=gear trap=7 gear=8` | correct | `doc/Reference_Guide/timetbl.tex:19-23` ("trap or 7", "gear or 8"; trap is the default) |
| VACASK | `trap=trap gear=gear2 euler=euler` | correct | `lib/coretran.cpp:585-591`; `docs/cmd-options-tran.md` |
| HSPICE | `trap=trap gear=gear` | pending tool check | - |
| Spectre | `trap gear2 euler` | pending tool check | - |

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

Gaps found alongside the verdicts (not counted as wrong):

* VACASK sine phase and damping are `tdphase`/`theta`, not mapped; `exp`, `pwl` and `fm` (sffm) exist but are not in the rules; `exp`'s `td2` is relative to `delay`; the pulse defaults differ from SPICE's.
* VACASK: `readscale` (K, x, X, meg, mil); the `functions`/`variables`/`operators` tables; `chgtol`; `icmode="uic"`; the temperature sweep; the `save` caveat for AC; the reason text of `no print`.
* VACASK has every statement kind in 1.4 except sens and switches. ic and nodeset are analysis parameters, so they need engine work.
* Xyce: `bsimcmg` level 111; level 57 for `bsimsoi`; `fmod` and `db`; `.LIN` for `sp`.
* HSPICE and Spectre: pending tool check.

### Counts

Each table row or numbered claim above counts once. Descriptive rows (1.4, 1.5,
and the "has it?" findings) are not counted.

| section | correct | wrong | unclear |
|---|---|---|---|
| 1. VACASK: lexer (8), assumed lines (9 claims in 8 items; the ninth `assumed` is the header), other rules (12 claims) | 26 | 2 | 0 |
| 2. `no` lines (31) | 19 | 2 | 10 |
| 3. model levels (ngspice 11, Xyce 10, Spectre `bsimbulk` 1) | 18 | 3 | 1 |
| 4. functions, operators, variables (16) | 8 | 2 | 6 |
| 5. enums (5) | 3 | 0 | 2 |
| **total** | **74** | **9** | **19** |

All 19 "unclear" are HSPICE or Spectre (pending tool check), except Xyce
`no device` (X9). The VACASK `mutual` coupling to `sp_inductor` (1.4) is also
unclear and untested but is not counted.

