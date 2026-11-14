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
| HSPICE, Spectre | no public manual; marked **needs licensed check** | - |

Paths below are relative to each repository root. Line numbers are for the
revision above.

Not available while this was written: the conformance-suite checkout under the
session scratchpad (`suite/tests/netlist/stress/vacask_*`) was deleted when
`/tmp` filled up during the session, so the four upstream VACASK decks were not
re-read; the VACASK repository's own `demo/`, `test/` and `benchmark/` decks were
used instead.

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
   Proposed: add `chgtol=chgtol` to the `options` rule.

4. **`rule save = "save" signals+`** (line 82): **correct**, with a caveat to add.
   `docs/cmd-save.md`; lexer `lib/dfllexer.l:860` (`save` is a keyword only inside
   `control`); parser `lib/dflparser.y:1272`. Caveat: in `ac`, `noise`, `acxf`, `dcinc` the
   directive `v(node)` saves the **operating point** value; the AC phasor is `dv(node)` and
   `di(inst)` (`docs/cmd-analysis-ac.md` "Save directives"). A translated `.save v(out)`
   followed by `.ac` therefore records the DC value. Proposed:
   `caveat save signals : in VACASK ac analyses v() saves the operating point; the AC phasor is dv()`.

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
| `rule global = "global" nodes+` | correct | `lib/dflparser.y:1147-1153` (with or without parens) |
| preamble `ground 0` | correct | `lib/dflparser.y:1155-1161` |
| `rule model = "model" name type ["("] {...} [")"]` | correct | `lib/dflparser.y:1076`, `:852` |
| `rule hdl = "load" path` | correct; `load` also accepts a `.va` file, compiled on the fly | `lib/dflparser.y:1163-1170`; `lib/openvafcomp.cpp`; decks `load "nl.va"` in `demo/` |
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
| mutual | **yes**, builtin `mutual` | `m12 () mutual k=0.95 ind1="l1" ind2="l2"`; empty terminal list required. `docs/dev-builtin-mutual.md`; params `lib/devctlsrc.cpp:804-809`; registered `lib/devbuiltins.cpp:15`. Needs inductors exposing `flow(br)` and `l`; `sp_inductor` has `branch (pos, neg) br` and `aliasparam l` (`devices/spice/inductor.va:61-65`), so it should qualify (**unclear**, not run). | `needs mutual` / `  model mutual mutual` / `end`; `rule mutual = name "(" ")" "mutual" { k=k ind1="l1" ind2="l2" }` |
| vcvs | **yes**, builtin `vcvs` | `e1 (out 0 in 0) vcvs gain=10`; `docs/dev-builtin-vcvs.md`; `lib/devctlsrc.cpp:17-19`, `lib/devbuiltins.cpp:12` | `needs vcvs` / `model vcvs vcvs`; `rule vcvs = name "(" pos neg cpos cneg ")" "vcvs" { gain=gain ...params }` |
| vccs | **yes**, builtin `vccs`; transconductance is `gain` | `docs/dev-builtin.md`; `lib/devctlsrc.cpp:17-19`, `lib/devbuiltins.cpp:11` | `needs vccs` / `model vccs vccs`; `rule vccs = name "(" pos neg cpos cneg ")" "vccs" { gain=gm ...params }` |
| cccs | **yes**, builtin `cccs`; controlling source by name | `f1 (0 out) cccs ctlinst="vprobe" gain=10`; `docs/dev-builtin-cccs.md`; `lib/devctlsrc.cpp:28-32`. Direction `I(p->n) = gain*I(ctlinst)`, same as SPICE F | `needs cccs` / `model cccs cccs`; `rule cccs = name "(" pos neg ")" "cccs" { ctlinst="vsrc" gain=gain ...params }` |
| ccvs | **yes**, builtin `ccvs`; transresistance is `gain` | `docs/dev-builtin.md`; `lib/devctlsrc.cpp:28-32`, `lib/devbuiltins.cpp:14` | `needs ccvs` / `model ccvs ccvs`; `rule ccvs = name "(" pos neg ")" "ccvs" { ctlinst="vsrc" gain=gain ...params }` |
| bsource | **yes** (grammar says `no`) | `b1 (p n) v=<expr>` / `i=<expr>` (also `potential=`, `flow=`); no master name. `docs/dev-builtin-behavioral.md` "Syntax"; parser `behavioral` production `lib/dflparser.y:372,474,1062`. Expression accessors `v(n)`, `v(a,b)`, `i(inst)`; time is `$abstime` (behavioural only, `docs/dev-builtin-behavioral.md:265-275`). | `rule bsource = name "(" pos neg ")" { v=v i=i ...params }`, placed before `rule instance`; `variables time = $abstime` only valid inside it |
| tline | **yes**, as a shipped Verilog-A device | `tline_ideal.osdi`, module `tline_ideal(p1,n1,p2,n2)`, params `z0 td f nl`, `td` wins, else `nl/f`. `docs/dev-vacask.md` table; `devices/tline_ideal.va:4-30`; `devices/CMakeLists.txt:7` | `needs tline` / `load "tline_ideal.osdi"` / `model tline tline_ideal` / `end`; `rule tline = name "(" p1 n1 p2 n2 ")" "tline" { z0=z0 td=td f=f nl=nl ...params }` |
| libsection | **yes** | `section name` ... `endsection`. `docs/input-include.md` "Section syntax"; `lib/dfllexer.l:536,553` | `block libsection` / `open "section" name` / `close "endsection"` / `end` |
| lib | **yes** | `include "file" section=name`. `docs/input-include.md`; `lib/dfllexer.l:300,374-381` | `rule lib = "include" path { section=section! }` before `rule include` |
| cond_if / elif / else | **yes** | `@if expr` / `@elseif expr` / `@else` / `@end`. `docs/cir-conditional.md`; `lib/dfllexer.l:783-798`; `lib/dflparser.y:463-499`. A branch may hold only instances, behavioural sources, models and nested blocks (`lib/dflparser.y:467-499`), not `parameters`. | `block cond_if` / `open "@if" cond...` / `close "@end"` / `end`; `rule cond_elif = "@elseif" cond...`; `rule cond_else = "@else"`; plus a `caveat` that parameters inside a branch are not allowed |
| ic | **no statement**; `ic=` is a parameter of `tran` and `pss` | `analysis t tran ... ic={"n1", 2.0, "n2", 1.0}` (list of node,value; a node pair gives a difference). `docs/cmd-analysis-tran.md` "Parameters"; `lib/coretran.cpp:247` | Not a rule: needs an engine `move ic -> tran.ic` that renders `{"node", value, ...}`. Until then `no ic : VACASK takes initial conditions as the ic= list of a tran analysis` would be wrong (it has them); keep `-` and record it for Phase 3. |
| nodeset | **no statement**; `nodeset=` parameter of `op`, `ac`, `tran`, `noise`, `hb`, ... | `analysis op1 op nodeset={"node1", 1.2}`. `docs/cmd-analysis-op.md` "Parameters" and examples; `lib/corehb.cpp:38` | Same as ic: an engine move to every analysis's `nodeset=`. |
| sens | **no** | No sensitivity analysis among the registered analyses (`include/an*.h` `analysisId`: `op ac noise dcxf hb dcinc acxf tran acstb pss pnoise acsp hbnoise pac hbac`); no `docs/cmd-analysis-sens*` | `no sens : VACASK has no sensitivity analysis` |
| sp | **yes**, analysis `acsp` | `analysis s acsp ports=["v1","r1","v2","r2"] from=... to=... mode="dec" points=...`; a port is a vsource **plus a series resistor**, named in pairs. `docs/cmd-analysis-acsp.md`; `include/anacsp.h:20`; `lib/coreacsp.cpp:19-24` | `rule sp = "analysis" name?sp$# "acsp" { from=fstart to=fstop mode="sweep" points=points ...params }` plus `caveat sp : VACASK ports are named in ports=[vsrc, rser, ...]; SPICE portnum/z0 on a source has no direct form` |
| pss | **yes**, analysis `pss` (shooting) | `tper` (period, not frequency), `tstab`, `maxharm`, `oscillator`. `docs/cmd-analysis-pss.md`; `lib/corepss.cpp:27-31` | Canonical `fund` is a frequency; VACASK wants `tper=1/fund`. Grammar cannot invert; needs an engine transform or `rule pss = "analysis" name?pss$# "pss" { tper=fund ... }` is **wrong**. Proposed after engine support: `{ tper='1/$fund' tstab=tstab maxharm=harms ...params }`. |
| stb | **yes**, analysis `acstb` | `analysis s acstb probe="vprobe" from=... to=... mode="dec" points=...`; probe is a series voltage source. `docs/cmd-analysis-acstb.md`; `lib/coreacstb.cpp:19-23`; `include/anacstb.h:16` | `rule stb = "analysis" name?stb$# "acstb" { probe="probe"! from=fstart to=fstop mode="sweep" points=points ...params }` |
| tf | **yes**, analysis `dcxf` (grammar says `no`) | `analysis xf1 dcxf out="out"` (or `out=["p","n"]`); saves `tf(src)`, `zin(src)`, `yin(src)` for every independent source. No output resistance. `docs/cmd-analysis-dcxf.md`; `lib/coredcxf.cpp:16`; `include/andcxf.h:16` | `rule tf = "analysis" name?tf$# "dcxf" { out="out" ...params }` with `caveat tf src : dcxf reports tf() and zin() for every source; SPICE's output resistance has no counterpart`. `ref` needs the vector form `out=["out","ref"]`. |
| PWL sources | **yes** | `type="pwl" wave=[t1,v1,t2,v2,...]`, plus `file=`, `period`, `stretch`, `scale`, `offset`. `docs/dev-builtin-src.md` "PWL"; `lib/devvisrc.cpp:51-60` | in the source rules: `wave=[pwl]`; enum `pwl=pwl` |
| exp sources | **yes**, with a different `td2` origin | see 1.2 item 6 | `tau1=tau1 tau2=tau2` + `td2` transform |
| switches | **no builtin**, no shipped module | `docs/dev-builtin.md` lists exactly 7 builtins; `docs/dev-vacask.md` and `docs/dev-spice.md` list no switch. `demo/sc/swtest.sim:3` loads a user Verilog-A `vsw.va`. | keep `no vswitch`, `no cswitch` |

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

