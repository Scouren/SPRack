# SPRack fix regression ledger: 90c8df24..35d5a78f

Read-only audit of the 318 commits after the Zig import (90c8df24) up to HEAD 35d5a78f
(branch clean-rewrite = origin/main). Nothing was built or run; every status below comes from
reading commit messages, diffs, and the tests, code and grammars at HEAD.

## Counts

| class | commits |
|---|---|
| FIX/BEHAVIOUR (in the ledger) | 205 |
| TEST-ONLY | 14 |
| DOCS/AUDIT/BASELINE | 57 |
| BUILD/CI/TOOLS | 36 |
| MERGE (content carried by the merged commits) | 6 |
| total | 318 |

| status of the 205 FIX commits | commits |
|---|---|
| PINNED | 147 |
| PINNED-ENV | 4 |
| PARTIAL | 45 |
| WEAK | 5 |
| UNPINNED | 1 |
| SUPERSEDED | 3 |

Fixture proposals: 60 blocks, in "UNPINNED / WEAK — fixtures needed".

## How to read the ledger

- One row per FIX/BEHAVIOUR commit. A commit that fixes several things has its invariants lettered
  (a), (b), (c) in one cell, and the status says which letters are not pinned. Pure refactors and
  memory work of src/ are in the ledger too, with "(refactor)" opening the invariant and the bound
  they must keep.
- `issue` holds a GitHub issue (`#NN`) or, for the earlier rounds, the round tag of the subject
  (c2, c4, c5, c6, d1-d3, e1, e2, g1, h1, l2, m2, r1, s1-s4, t1, u1, v1, y1, y2, z1, z2) or a PLAN
  item (7.3, 8.2, b3, b4). Round tags are not issue numbers.
- Tests are in src/tests.zig unless prefixed: `expr.zig:`, `project.zig:`, `json.zig:`,
  `grammar.zig:`, `lexer.zig:`, `ir.zig:`, `stats.zig:` (unit tests in that file), `py:`
  (python/test_sprack.py), `cli:` (a `cliTests` case in build.zig).
- Status, decided by what a test at HEAD asserts, not by what the commit added:
  - PINNED: a test at HEAD asserts the output text or report entry. A note in parentheses says
    where the assertion is narrower than the invariant.
  - PINNED-ENV: asserted only by a test that needs something outside the repo (a PDK checkout
    through SPRACK_TEST_PDKS or SPRACK_TEST_PDKS_INSTALLED, an installed simulator, a Windows host)
    and is skipped otherwise.
  - PARTIAL: some lettered invariants are pinned and at least one is not (unpinned, weak, or
    env-only); the status names them.
  - WEAK: a test runs the path but asserts only no crash, a count, a loose substring, or
    `hasErrors`.
  - UNPINNED: no test at HEAD covers it.
  - SUPERSEDED(hash): the behaviour was deliberately replaced or removed by that later commit;
    the successor's row carries the invariant to keep.
- The three statuses asked for map as: PINNED = PINNED; WEAK = WEAK + PARTIAL + PINNED-ENV
  (something of the fix is not defended by a default `zig build test` and Python test run);
  UNPINNED = UNPINNED.
- How the statuses were checked: for every commit the test blocks its diff touched were mapped
  mechanically and looked up at HEAD by name (14 test names of the history no longer exist; each
  was traced to its renamed successor or to its removal), then the expected strings the commit
  added were searched for at HEAD or the test body was read. A sample of 30 PINNED strings and 35
  "not asserted" strings was re-checked by grep after the slices were merged; all agreed.


## Ledger: the 205 FIX/BEHAVIOUR commits, oldest first

| hash | date | issue | area | invariant | test name(s) at HEAD | status |
|---|---|---|---|---|---|---|
| 525d29d2 | 2026-11-14 | - | engine, grammar:hspice,ngspice,xyce | In a .spgrammar `define name = pattern` and `<name>` expand to exactly the pattern nodes of writing it inline (nested defines too); the shipped V/I source waveform is one shared fragment: hspice `V1 a 0 SIN(0 1 1k)` → xyce `V1 a 0 sin(0 1 1k)`, `I1 a 0 PWL(0 0 1n 1)` → `I1 a 0 pwl(0 0 1n 1)` | "define: a named pattern compiles to the same nodes as writing it out" | PINNED |
| b1931bc9 | 2026-11-14 | - | engine, grammar:hspice | (a) a repeated group `( ... )+"sep"` / `( ... )*` takes the next item of every list slot on each pass, reading and writing: tiny `.hb f 1k h 3 and f 2k h 5` reads as freqs=[1k,2k] harms=[3,5] and is written back identically; a separator with nothing after it is no match (the line stays `opaque`); (b) hspice `.hb tones=1k 1.3k nharms=7 7 intmodmax=7` → xyce `.hb 1k 1.3k`, → hspice unchanged with a clean report; xyce `.hb 1k 2k` → hspice `.hb tones=1k 2k` | "repeated groups: list slots in lockstep, with a separator" | PINNED |
| 66c431f7 | 2026-11-14 | - | reader, engine, grammar:hspice | hspice `.ac dec 10 1k 1meg` followed (only comments between) by `.noise v(out,ref) vin` reads as ONE noise statement and no ac (`merge a -> b`) → ngspice `.noise v(out,ref) Vin dec 10 1k 1meg` with no `.ac` line; when another statement (`.print ac v(out)`) stands between, the `.ac` stays an analysis and still lends its sweep to the `.noise`; report clean | "HSPICE .ac plus .noise is one noise analysis" | PINNED |
| a57bbdce | 2026-11-14 | - | grammar:vacask | A multi-tone HB crosses VACASK as lists: hspice `.hb tones=1k 2k nharms=3 3` → vacask `analysis hb1 hb freq=[1k, 2k] nharm=[3, 3]` (nharm a vector, not a scalar) and that line reads back as one hb with two harms (no opaque line) | none asserts it: "fuzz: a statement of thousands of repeated words does not overflow the stack" writes `.hb tones=1k 2k nharms=3 3` to every dialect but checks nothing of the text; no test contains a VACASK `hb` line | WEAK |
| 186dda8a | 2026-11-14 | - | engine, cli | (a) a .spgrammar compiled at run time is the same grammar as the built-in: `grammars/ngspice.spgrammar` loaded by path writes every dialect's sample byte for byte as built-in ngspice (same number of report entries) and reads it back to the same JSON; (b) a mistake in a grammar file is error.BadGrammar with `path:line: message` (`bad.spgrammar:5: missing ']' in pattern`, `:4: unknown kind 'nonsense'`, `:5: unknown slot 'bogus' for kind 'tran'`, `:3: lexer section is missing 'end'`), an unreadable path `cannot read <path>` (CannotRead), an unknown name UnknownDialect; (c) CLI `--from/--to` take a .spgrammar path; exit 2 with `bad.spgrammar:4: unknown slot 'zz' for kind 'op'`, `cannot read /no/such.spgrammar: FileNotFound`, `unknown dialect 'pspice'. Built in: cdl hspice ltspice ngspice spectre vacask xyce; or a path to a .spgrammar file` | "a grammar loaded at run time writes and reads byte for byte as the built-in"; "a broken grammar file is reported with its path and line"; grammar.zig: "compile a small grammar at comptime and at run time", "a broken grammar at run time names the file and line"; cli: translate --from grammars/ngspice.spgrammar, bad.spgrammar, pspice, /no/such.spgrammar | PINNED |
| cc1a6e08 | 2026-11-14 | - | python | (a) every Python dialect argument may be a .spgrammar path: `c.netlist(path)` == `c.netlist("ngspice")`, `translate(frm=path)`, `translate(to=path)`, `read(text, path)`, `write(out, path)` agree with the built-in; (b) a broken file raises ValueError `<path>:4: unknown slot 'zz' for kind 'op'`, a missing one `cannot read <abs path>`; (c) a PDK translated into a grammar-file target is cached in a directory named `<grammar basename>-<sha1[:8] of the file's bytes>-<stamp>` | py: test_grammar_file (a, b); py: test_library_of_a_grammar_file_dialect (the libs cache only: an edited grammar file makes a second copy) | PARTIAL: (c) not pinned for PDK.translate |
| 3bcb97fc | 2026-11-14 | - | python | `Scope.code(text, dialect='ngspice')` reads statements (no title line) in any dialect into a circuit or subcircuit and returns them (`.tran 1n 1u\n.ac dec 10 1 1G $ sweep\n.save v(out)` → kinds tran, ac, save); they translate like built statements (→ spectre `tran1 tran step=1n stop=1u`, `ac1 ac start=1 stop=1G dec=10 // sweep`, `save out`; spectre `rb (a b) resistor r=10` in a subckt → ngspice `rb a b 10`); a line no rule reads (`.bogus 1 2`) is kept verbatim for its own dialect and is Unsupported `no ngspice rule understood this line` (code `untranslated`) elsewhere; an unknown dialect is ValueError `unknown dialect` | py: test_code | PINNED |
| 211ec795 | 2026-11-14 | - | grammar:ltspice,cdl | (a) LTspice and CDL are dialects: each sample reads with no opaque line and every reader agrees on the circuit; (b) every ordered pair of the dialects writes and reads back the same circuit; into CDL each source, analysis and control statement is exactly one error[unsupported] and the rest reads back the same; CDL instances are `X<name> nodes / master`; (c) the ESPice dialect — SUPERSEDED(d875ee84: dialect removed) | "all grammars compiled"; "hand-written samples parse completely"; "the five readers agree on what the circuit is"; "every pair of dialects: write, read back, same circuit, no errors"; CDL `/` form also in "v1: a subcircuit is written once for each branch of a conditional block" | PINNED |
| 208dae35 | 2026-11-14 | - | grammar:ltspice | (refactor) the LTspice V/I waveform is one `define wave` fragment used by the write rule (waveform before `ac`) and the read rule (`ac` before the waveform also read); no output change. ESPice `.hb TONES=` as a repeated group — SUPERSEDED(d875ee84) | "every pair of dialects: write, read back, same circuit, no errors" (ltspice sample `V1 in 0 DC 1 PULSE(0 1.8 1n 100p 100p 5n 10n) AC 1`); "define: a named pattern compiles to the same nodes as writing it out" | PINNED |
| 144d7577 | 2026-11-14 | - | ir, json, writer, python | A statement carries the dialect it was read in (JSON `"dialect"` per statement, set by `Scope.code`), overriding the netlist's in the writer's same-dialect checks: `{"kind":"options","params":{"plotwinsize":"0","numdgt":"15"},"dialect":"ltspice"}` in a `sprack` netlist → ltspice `.options plotwinsize=0 numdgt=15` with a clean report; → ngspice error `options: 'plotwinsize=0' has no spelling in ngspice`; ltspice→ltspice of that line is byte-identical with an empty report | "a dialect's own options round-trip, also as statements added from another dialect"; py: test_code (lt block) | PINNED |
| 588cb36f | 2026-11-14 | - | json, writer, schema, engine, grammar:ngspice | (a) a JSON path slot accepts `{"str":...}`: ngspice `.lib "models.lib" tt` / `.include "extra.inc"` survive read→JSON→write byte for byte; bare `.lib models.lib tt` + `.include extra.inc` → xyce `.lib "models.lib" tt\n.include "extra.inc"`; (b) the case-collision check scopes a subcircuit's ports, nodes and instances to that subcircuit: `IN` inside `.subckt inv` and top-level `in` are no collision into ngspice, while spectre `in`/`IN` and `Out`/`out` in one scope → ngspice error `'in' and 'IN' are different names in the source but the same name in ngspice`; (c) ngspice XSPICE `AU1 [ clk rst cmp ] [ d_7 eoc ] sar_m` (vector ports) and `.model dinv d_cosim simulation="dinv.vvp"` round-trip; → xyce error `XSPICE code models are ngspice's...`; (d) `path!` writes a blank-free path bare: `.control\npre_osdi amp.osdi\n.endc`; (e) ESPice `.verilog` kind — SUPERSEDED(d875ee84, fa7180a9) | "Schemify decks: paths, scopes, control blocks and XSPICE survive the JSON trip" (renamed by 2f837502); "Verilog-A: loading a module and instantiating it" (`pre_osdi mydiode.va` bare) | PINNED |
| 0d842dba | 2026-11-14 | - | python | `Circuit.netlist(d)`: a `.lib`/`.include` whose statement dialect is not d is translated with the whole file tree it reaches into `$SPRACK_CACHE/libs/<key>/tree/` and the written line names the copy: (a) ngspice `.lib "$SPRACK_TEST_LIB/top.lib" tt` → xyce `.lib "<cache>/libs/<key>/tree/top.lib" tt`, the copied `m/nch.mod` says `.model nch nmos level=14`, the copy re-reads as two libsections; (b) the source dialect keeps the line as written (`$VAR` unexpanded); (c) a second write is a cache hit (marker `sprack.json` mtime unchanged); (d) a changed source file is translated again; (e) parallel writers on an empty cache all return the same text and leave one whole entry; (f) a missing file is Unsupported `cannot open ... nowhere.inc`; (g) what the library cannot say joins the netlist's report with `file` set | py: test_library_translated_on_the_fly (a–f); py: test_pdk_sky130_library_on_the_fly ((g) `all(e.file for e in report.errors)`; needs SPRACK_TEST_PDKS, skipped otherwise) | PARTIAL: (g) only PINNED-ENV |
| e4d1269f | 2026-11-14 | - | grammar:hspice,spectre | Reason text only (plus grammar comments): an ngspice XSPICE `A` device written for hspice or spectre is an error whose reason is `XSPICE code models are ngspice's; this grammar has no form for them` (no claim about the vendor tool). The `no verilog` lines — SUPERSEDED(fa7180a9: kind removed) | "Schemify decks: paths, scopes, control blocks and XSPICE survive the JSON trip" asserts only the prefix `XSPICE code models are ngspice's`, and only for target xyce | WEAK |
| 603d7d06 | 2026-11-14 | - | lexer, reader, ir | (refactor) the reader lexes one logical line at a time (a Window) and keeps no whole-netlist token copy; the spelling table is a caseless set of source spellings filled in the declaration pass; same statements and output; bound to keep: translation memory a small multiple of the input (≤ 0.8× of the input at HEAD, after d7bf89c1) | lexer.zig: "lines, comments, continuation", "spectre tokens"; "translation memory stays a small multiple of the input" | PINNED |
| 6d381c30 | 2026-11-14 | - | writer | (refactor) the writer's caseless name sets live outside the arena and the statement list is copied for `move`s only when one applies; output unchanged; same memory bound | "translation memory stays a small multiple of the input"; "every pair of dialects: write, read back, same circuit, no errors" | PINNED |
| d4d6a338 | 2026-11-14 | - | ir, reader, writer | (refactor) a statement stores only the slots it binds (slot mask + values; `Stmt.at/set/pack/unpack/store`) instead of one value per slot of its kind; output and JSON unchanged; same memory bound | "translation memory stays a small multiple of the input"; "every pair of dialects: write, read back, same circuit, no errors" | PINNED |
| b490b0d8 | 2026-11-14 | 8.1 | ir, lexer, reader, writer | (refactor) large temporary tables are allocated through `ir.big` so a counting allocator sees them; translating a generated 120×120 RC mesh ngspice→spectre and →xyce must stay under the bound (13× then; `peak*10 <= 8*input.len` at HEAD) else error.TooMuchMemory | "translation memory stays a small multiple of the input" | PINNED |
| dc34e36e | 2026-11-14 | - | writer | (refactor, merge fix) the per-subcircuit case maps of 588cb36f are allocated on `ir.big`; the memory bound still holds with Stmt.dialect | "translation memory stays a small multiple of the input" | PINNED |
| 872a7de6 | 2026-11-14 | - | ir, json, cli | (a) `Stmt.dialect` is a u8 index into a process-wide table: built-ins are 1..dialect_count, any other name (a run-time grammar, a JSON `"dialect"`) is interned once, case ignored; JSON still carries the name (`"dialect":"MyDialectForTest"` round-trips); the writer's own-dialect check compares names, so a statement marked `ngspice` written by a run-time-loaded ngspice grammar gives `.options klu` cleanly and one marked with another dialect gives error `options: 'klu' has no spelling in ngspice`; (b) past 255 names a grammar load fails with TooManyDialects (CLI/Python print the message) and a new JSON dialect name is a parse error | "statement dialects are table indices; the JSON keeps the name" (a) | PARTIAL: (b) not pinned |
| 63f08969 | 2026-11-14 | - | grammar:xyce,ngspice, writer | (a) ngspice `log(x)` → xyce `ln(x)`; xyce `log(x)` → ngspice `log10(x)`; (b) ngspice `x^3` → xyce `x**3`; xyce `1 ^ 0` → ngspice error `operator 'xor' has no spelling in ngspice`; (c) ngspice `.model qv npn level=4` → xyce `level=11`; xyce `npn level=10` → error `type 'npn' with these parameters is not in the xyce models table`; (d) ngspice `sw`/`csw` cards → xyce `vswitch`/`iswitch`; (e) BSIM-CMG's default Xyce level is 111 (hspice `nmos level=72` → xyce `level=111`); (f) xyce `nmos level=57` reads as bsimsoi; (g) ngspice `.sp lin 3 1meg 3meg` with `V1 in 0 dc 0 ac 1 portnum 1 z0 50` → xyce `PV1 in 0 dc 0 port=1 z0=50 ac 1` and `.ac lin 3 1meg 3meg\n.lin`, read back as one sp and no ac; (h) a pss → xyce is error[unsupported] `Xyce has no periodic steady-state (shooting) analysis; its periodic analyses are .HB and .MPDE`; (i) xyce has no cond_elif/cond_else either (later reworked by a1afc9a4/d583b921); (j) an ngspice `nhfet` card with no level is not family hfet; a model card of a kind whose instances name a model is never dropped as boilerplate: `Z1 d g 0 hm` + `.model hm nhfet level=6` → xyce error `no spelling for model family 'hfet n'`; (k) xyce keeps `fmod` and `db` under their names | "verification: Xyce log is base 10 and ^ is exclusive-or" (a,b); "verification: Xyce VBIC levels and switch model types" (c,d); "a model card's level by its version or by its instances' terminals (when)" (e); "verification: Xyce S-parameters through .LIN and P ports" (g); "verification: an ngspice nhfet card without a level is not an HFET" (j); "s1: a conditional block of the same statements is written once, with conditional values" (i, reason text) | PARTIAL: (f), (h), (k) not pinned |
| 68025e67 | 2026-11-14 | - | engine, writer, schema | Grammar directives and schema: (a) `needs <family>`: boilerplate (`load "spice/bjt.osdi"`) written only when a model card of that family is used; (b) `convert kind [slot=atom] : a = b / a = a ± c / a = 1 / a` computed on write and inverted on read with exact decimal arithmetic (vacask `td2=900n` for SPICE td1=100n td2=1u, `points=4` for `lin 5`, `tper=1u` for fund=1M); (c) `invalid kind slot[=0] [slot=atom] : text` → error[invalid] `<kind>.<slot> is 0 / is not given: <text>` when a statement crosses into or out of the dialect; (d) `k={slot}` pairs form `ic={"out",0.2}`; (e) lexer `vectors comma` → `wave=[0, 0, 1u, 1]`; (f) nodeset is a slot of every analysis and ic of tran/pss; one `.nodeset` fans out to every analysis and reading lifts them back to `.ic`/`.nodeset`; (g) a moved kind with nothing to carry it is an error `vacask says it as tran.ic, and this netlist has no tran`; (h) `sprack caps` prints `param` for a kind a dialect writes as a parameter of another statement | expr.zig: "convert arithmetic is exact where it can be" (b); "verification: VACASK model families load their modules" (a); "verification: VACASK sources: sine phase, exp origin, pwl, fm, and SPICE defaults" (b,c,e); "verification: VACASK analyses: acsp, acstb, pss period, ic and nodeset on the analysis" (b,d,f,g) | PARTIAL: (h) not pinned (cli caps asserts only the resistor row and the `none:` legend) |
| 062bcac0 | 2026-11-14 | - | grammar:vacask | ngspice→vacask: (a) `B1 b 0 V={v(in)*2}` → `B1 (b 0) v=v(in)*2`; `.tf v(b) V1` → `analysis tf1 dcxf out="b"` + warnings `tf.src: dcxf reports tf() and zin() for every independent source`; subckt header `subckt div (in out)`; vacask `v0=/v1=` are not pulse levels; (b) `sin(0.5 1 1meg 100n 1e5 30)` → `type="sine" delay=100n sinedc=0.5 ampl=1 freq=1M theta=1e5 tdphase=30`; `exp(0 1 100n 200n 1u 300n)` → `td2=900n` (counted from delay); `pwl(0 0 1u 1)` → `wave=[0, 0, 1u, 1]`; `sffm(0 1 2meg 3 200k)` → `type="fm" ... freq=200k modindex=3 modfreq=2M`; all back exactly; (c) SPICE defaults VACASK means otherwise are error[invalid]: `vsource.rise is 0: VACASK needs rise > 0`, `vsource.fall is not given: ...never falls`, `vsource.width is not given`, `vsource.freq is not given: VACASK's default frequency is 1k`, `vsource.td2 is not given`; (d) the same for an SFFM's carrier, index and modulating frequency; (e) `log(2)` → `ln(2)`, `temper` → `$temp`, vacask `log`/`^`/`integer` → spectre `log`/`^`/`int`, `sgn` → error `function 'sgn' has no spelling in vacask`; (f) `time` → `$abstime`; (g) K/E/G/F/H/T devices, `.lib 'f' typ` → `include "models.lib" section=typ`, `.lib typ`…`.endl` → `section typ`…`endsection`, `.if/.elseif/.else/.endif` → `@if/@elseif/@else/@end`; (h) spectre pss/stb → `analysis pss1 pss tper=1u tstab=1u maxharm=10`, `analysis stb1 acstb probe="V1" ...`; `.sp` → `acsp`; a `lin 5` sweep → `points=4`; ic/nodeset on the analysis; `.sens` → error `VACASK has no sensitivity analysis`, a switch → `VACASK has no switch device`; (i) model families load their modules (`load "spice/bjt.osdi"`, `model qn sp_bjt (type=1 bf=100)`, `vbic13_4t`, `sp_jfet1`, `sp_mos3`, `sp_vdmos`; nothing unused loaded); (j) `.options chgtol=` → vacask `options chgtol=`; (k) a `.save` beside an AC-type analysis carries the caveat that v() saves the operating point and the small-signal value is dv() | "verification: VACASK behavioural sources, dcxf, subckt parentheses, val0/val1" (a); "verification: VACASK sources: sine phase, exp origin, pwl, fm, and SPICE defaults" (b,c); "verification: VACASK functions, operators and variables" (e); "verification: VACASK coupling, controlled sources, lines, libraries, conditionals" (g); "verification: VACASK analyses: acsp, acstb, pss period, ic and nodeset on the analysis" (h); "verification: VACASK model families load their modules" (i); "VACASK control block and sweep"; py: test_build_every_dialect | PARTIAL: (d), (f), (j), (k) not pinned |
| 7d73f491 | 2026-11-14 | - | engine, reader, writer, schema | (a) `differs <function or operator> : text` → warning[caveat] `expression '...': <name> in <dialect>: <text>` whenever an expression using it crosses into or out of that dialect (ngspice `2**x` → hspice: `the exponent is cut to an integer`); (b) `slot#1`: a form that holds exactly one item of a list slot does not match more (`.four 1k v(a) v(b)` → spectre is an error; why-text `more than one '<slot>'`); (c) a value followed by `)` in the pattern takes everything up to that `)` where parentheses are tokens: spectre `if ((a > 1)) {` reads as condition `a > 1` → ngspice `.if (a > 1)`; (d) a device whose model is of another kind with the same slots takes that kind (hspice `j1 out in 0 mm 2` + `.model mm njf level=3` reads as one mesfet); (e) a parameter value that starts like a number but is none (`version=3.3.0`) written for another dialect is error[invalid] `version=3.3.0 is not a number; <dialect> does not read it`; (f) schema: pz has an output signal and a source (hspice `.pz v(out) vin` → spectre `pz1 (out 0) pz iprobe=vin`), noise has `interval` | "HSPICE: .pz, .noise interval, .lin, .sn, MESFETs, model before value, pow" (a,d,f); "Spectre: conditionals, functions, xf, pz, sens, fourier, hb, nested dc, switches" (b: hasErrors only, c); "b4: controlled sources in POLY, TABLE, LAPLACE, POLE, VCR and VCCAP form" (b: `more than one 'cpos'`); "fixes from the load check: Spectre globals, dotted versions, Spectre pow" (a,e) | PINNED |
| 04b5199f | 2026-11-14 | - | grammar:spectre,hspice | ngspice→spectre: (a) `.if/.elseif/.else` → `if ((a > 1)) {` … `} else if ((a < 0)) {` … `} else {` … `}` and back; (b) `.func f1(x,y) {x*2+y}` → `real f1(real x,real y) {\nreturn (x*2+y)\n}`; (c) `.tf v(out) V1` → `xf1 (out 0) xf freq=0` + warning `tf.src: xf gives the transfer function from every source`; (d) `.sens v(out)` → `sens1 dc\nsens (out) for (sens1)`; (e) `.four 1k v(out)` → `four1 (out 0) fourier fund=1k`, two signals an error; (f) hspice `.hb tones=1k nharms=5` → `hb1 hb fundfreqs=[1k] maxharms=[5]`; (g) a nested `.dc` → a `sweep` block around the dc and back; (h) `sw`/`csw` cards → `vswitch`/`iswitch` (`model wmod iswitch it=1m`, `S1 (out 0 in 0) smod region=on`, `W1 (out 0) wmod probe=V1`); (i) `pwr sgn nint` keep their names. HSPICE: (j) `.pz v(out) vin`, `.noise v(out) vin 10`, `.ac ... \n.lin` (sp), `.sn tone=1k nharms=5 trinit=1m` (pss) read and written; (k) ngspice `Z1 d g 0 zm` + `.model zm nmf` → hspice `.model zm njf level=3`; (l) ngspice `R1 a 0 1k rm` → hspice `R1 a 0 rm 1k` (model before value); (m) `limit()` → hspice error `function 'limit' has no spelling in hspice`; (n) `**`/`pow` crossing hspice → warning `the exponent is cut to an integer`; (o) `nint` crossing hspice → caveat `halves round away from zero`; (p) hspice noise interval → spectre error `noise.interval = 10 has no spelling in spectre` | "Spectre: conditionals, functions, xf, pz, sens, fourier, hb, nested dc, switches" (a–i; g by round trip); "corpus: more source and analysis forms" (g text); "HSPICE: .pz, .noise interval, .lin, .sn, MESFETs, model before value, pow" (j–n, p); "an analysis the target cannot express is an error naming who can, and why" | PARTIAL: (o) not pinned for hspice (the same caveat is asserted for ltspice and xyce only) |
| 33dfc935 | 2026-11-14 | - | grammar:hspice | hspice has `atan2 hypot fmod asinh` under their own names: an expression using them written for hspice keeps the call and reports no `function '...' has no spelling in hspice` (the rest of the commit is docs) | none (no test has atan2/hypot/fmod into hspice) | UNPINNED |
| 8ec3ca62 | 2026-11-14 | - | writer, engine, grammar:spectre,hspice | (a) the first node of a Spectre `global` is ground: ngspice `.global vdd` → spectre `global 0 vdd` (never `global vdd`); (b) lexer `numbers strict` (spectre, hspice): ngspice `.model n3 nmos(level=49 version=3.3.0)` → error `version=3.3.0 is not a number`; (c) spectre `differs pow`: `{pow(-1.75,2.5)}` → warning `a negative base with a fractional exponent stops the run` | "fixes from the load check: Spectre globals, dotted versions, Spectre pow"; "an ADE-style Spectre netlist" | PINNED |
| b855300c | 2026-11-14 | - | grammar:ngspice,hspice | (a) the summary interval of a noise analysis is `noise.interval` in both: hspice `.ac dec 10 1 1meg` + `.noise v(out) vin 10` → ngspice `.noise v(out) vin dec 10 1 1meg 10`; (b) ngspice reads the optional 6th number `.noise v(out) src dec 10 1 1meg 5` into `interval` (→ hspice `.noise v(out) src 5`); (c) hspice `.noise v(out) src` is against ground (`implied noise ref = 0`), as the other dialects read it | "HSPICE: .pz, .noise interval, .lin, .sn, MESFETs, model before value, pow" (a); "c4: ngspice .noise takes the summary interval" (a) | PARTIAL: (b) reading from ngspice and (c) not pinned (c only through the every-pair round trip) |
| b6567bf5 | 2026-11-14 | - | reader, grammar:ngspice,xyce | ngspice→ngspice and →xyce: (a) `.func g(x, y) {x+y}` is written `.func g(x,y) {x+y}` (never `g(x y)`); (b) a diode's bare area `D1 a 0 dm 2 pj=1m` is written `D1 a 0 dm area=2 pj=1m`; (c) `version=3.3.0` is read as a word and written `version=3.3.0`, not `{3.3.0}`; (d) xyce `.noise` takes one node: `.noise v(a,b) ...` → xyce is an error; (e) ngspice `SIN(0 1)` with no frequency → xyce is an error, not a line Xyce rejects | "parse check: forms ngspice and Xyce reject when they load the netlist" (a,b,c; d,e as `hasErrors` only); "#68: noise between two nodes into Xyce is a loss that says why; one node is not" (d: `noise.ref = b has no spelling in xyce: Xyce 7.10 takes one output node`) | PARTIAL: (e) WEAK (only `hasErrors`) |
| 074da563 | 2026-11-14 | - | grammar:ngspice | ngspice nmf/pmf/nhfet/phfet share a level switch (0–1 MESFET, 2–4 MESA, 5–6 HFET): `.model nm nmf level=2` → xyce error `model 'nm' (mesa n) cannot be written for xyce: Xyce's MESFET (Z) has one level`; `.model hm nhfet level=6` used by Z1 → error `xyce.spgrammar has no spelling for model family 'hfet n'`; a plain `.model zm nmf vto=-1` → xyce `.model zm nmf vto=-1`; a level is dropped as implied only when it names the kind's own family | "parse check: ngspice MESA and HFET cards are not plain MESFETs" | PINNED |
| ed4d2d96 | 2026-11-14 | - | writer | (a) a `.lib`/`.include` line is never wrapped onto a `+` line however long the path (ngspice→xyce, 90- and 180-char paths stay on one line); (b) a model parameter given twice keeps the last: hspice `.model p1 pmos level=54 toxref=1.26n vsat=69000 toxref=1.3n` → xyce `.model p1 pmos level=14 vsat=69000 toxref=1.3n` + warning `model 'p1': 'toxref' is given twice; the last value is kept` | "parse check: a long .lib or .include line is never wrapped"; "parse check: a model parameter given twice keeps the last, as SPICE does" | PINNED |
| 0b2454b6 | 2026-11-14 | - | grammar:xyce | ngspice `.options gmin=1e-3` and `.nodeset v(a)=1` → xyce each carry a warning[caveat]: `options.gmin: Xyce adds GMIN differently from ngspice ...`, `nodeset.values: Xyce and ngspice apply nodesets with different algorithms ...` | "sim check: Xyce gmin and nodeset differ from ngspice and say so" | PINNED |
| c7063348 | 2026-11-14 | - | engine, expr, grammar:xyce | `threshold family : on off = mid half`: a SPICE switch card's threshold and hysteresis become Xyce's on/off levels and back: ngspice `.model sw1 sw(vt=2.5 vh=0.5 ron=1 roff=1meg)` → xyce `.model sw1 vswitch von=3 voff=2 ron=1 roff=1meg`, `.model cw csw(it=1m ih=0.2m)` → `.model cw iswitch ion=1200u ioff=800u`, with warning `model 'sw1': the threshold and hysteresis are written as on and off levels`; xyce→ngspice gives `vt=2.5 vh=0.5` again; no hysteresis (`sw(vt=1)`) → error `model 's0': a switch with no hysteresis has no xyce form` | "sim check: a switch's threshold and hysteresis become Xyce's on and off levels"; "verification: Xyce VBIC levels and switch model types" (`von=600m voff=400m`, `ion=1100u ioff=900u`); "more devices: behavioural and controlled sources, coupling, switches, lines" | PINNED |
| 6f45950a | 2026-11-14 | - | python | The library cache under concurrent writers: a writer whose rename loses keeps another writer's valid copy and replaces only a stale one; nothing named `<key>.old-<pid>-*` or `.<key>-<pid>-*` is left behind; each call first sweeps leftovers whose writer pid is dead or that are older than `_STALE_AGE` (an hour), and keeps a live writer's recent temp dir | py: test_library_translated_on_the_fly (8 parallel writers → `os.listdir(libs) == [key]`; planted dead-pid and old leftovers swept, live recent one kept) | PINNED |
| 60c1eb72 | 2026-11-14 | - | python | IHP manifest (python/sprack/pdks/ihp-sg13g2.json) `load` lists the six OSDI objects IHP's .spiceinit loads, in order psp103, psp103_nqs, r3_cmc, mosvar, cap_cmomi, cap_cmomf → an ngspice netlist on the IHP PDK carries an hdl/pre_osdi line for each (before: `Unknown model type psp103va`); a load entry whose file is missing is skipped | py: `test_pdk_installed_ihp` | PINNED-ENV (needs SPRACK_TEST_PDKS_INSTALLED with an installed IHP tree + ngspice on PATH) |
| ce8ed481 | 2026-11-14 | 7.2, 7.6 | python | (a) a manifest `gf180mcuD` exists: `sprack.PDK("tsmc28")` error lists `known: ASAP7, FreePDK45, gf180mcuD, ihp-sg13g2, sky130A`; (b) GF180MCU corner = design.spice + sm141064.spice MOS section + bjt_/diode_/res_/mimcap_/moscap_ sections of the same corner (typical for sf/fs) + smbb000149.spice: ngspice netlist has `.include ".../design.spice"` then 7 `.lib` lines, `p.entries("sf")[1:3]` = (sm141064.spice, sf), (sm141064.spice, bjt_typical); (c) installed sky130A/IHP layouts are found by the manifests' first layout | py: `test_pdk_errors` (a), `test_pdk_gf180mcu` (b), `test_pdk_installed_sky130`, `test_pdk_installed_ihp` (c) | PINNED-ENV ((a) pinned without env; (b) needs SPRACK_TEST_PDKS + ngspice; (c) needs SPRACK_TEST_PDKS_INSTALLED + ngspice) |
| 2ddd4b02 | 2026-11-14 | b3 | grammar:hspice,spectre,vacask / schema | new analysis kinds pac, pnoise, pxf, psp, xf, dcmatch, trannoise, phasenoise, envelope, qpss, with `engine=hb` for the HB form: (a) HSPICE `.snac/.snnoise/.snxf` and `.hbac/.hbnoise/.hbxf` ↔ Spectre `pacN pac ...`, `pnoiseN (out 0) pnoise iprobe=Vin refsideband=0 ...`, `pxfN (out in) pxf ...`, `hbac/hbnoise/hbxf`, and back with the engine kept; (b) HSPICE `.dcmatch v(out)` → Spectre `dcmatch1 (out 0) dcmatch`; `.ac` + `.lstb mode=single vsource=Vp` ↔ Spectre `stb1 stb start=1 stop=1M dec=10 probe=Vprobe` (merge ac -> stb); (c) Spectre `xf` → VACASK `analysis xf1 acxf out="out" from=1 to=1k mode="dec" points=10`; VACASK `pac tper=` round-trips; Spectre pss+pac → VACASK error `pac: no vacask form of this statement can say a statement without 'fund'`; (d) HSPICE `.trannoise v(out) samples=2 seed=1` round-trips, → Spectre error `Spectre runs transient noise as parameters of the tran analysis`; (e) Spectre `envlp`, `qpss`, `xf` lines read as analysis kinds, not instances; (f) HSPICE `.phasenoise v(out) dec n f1 f2` read/written; Spectre `psp`/`hbsp`; VACASK `pnoise`; (g) every other dialect: error[unsupported] with the grammar's `no <kind> : reason` | `b3 analyses: periodic small-signal, mismatch, transient noise, loop stability`; py: `test_periodic_analyses`; `every `no` line: the kind is an error in that dialect, and the reason is the grammar's` (g); `#45: HSPICE .lin parameters, .hblin POI and a positional .hb` (hbsp) | PARTIAL: (e) asserted only as a kind count (written envlp/qpss text not asserted); (f) HSPICE .phasenoise, Spectre psp (shooting), VACASK pnoise have no assertion |
| fc64e233 | 2026-11-14 | - | engine / writer / grammar:xyce | `rule kind[family]`: a device form applies only when the instance's model card (in the same file) is of that family. ngspice `q1 c b 0 0 hm` + `.model hm npn level=8` (HICUM/L2) → Xyce `q1 c b 0 0 dtq1 hm` with warning[synthesized] `xyce needs 'tj' but the source gave none; wrote dtq1`; a Gummel-Poon `q2 c b 0 gp` is unchanged; with no card in the file the plain form `q1 c b 0 0 hm` is written | `a rule that depends on the model's family: Xyce HICUM's thermal node` | PINNED |
| 50285205 | 2026-11-14 | - | engine / reader, writer, lexer | (a) `slot#other` / `( ... )#other`: a list has exactly as many items as the count slot says (`e1 o1 0 poly(2) a 0 b 0 0 1 1`), count unset = one item; a mismatch refuses the form with `N items where '<slot>' says M`; (b) numbers after one open-ended key are its matrix: ngspice `.model pline cpl r=0.2 0 0.2 l=9.13n 3.3n 9.13n length=10` round-trips; (c) a tagged literal stands for a number: `i1 e 0 ac` → `i1 e 0 ac 1`; (d) `raw "open" "close" : reason`: a VACASK `embed` block written elsewhere is error[unsupported] `... cannot be written for ngspice: VACASK embeds a file...` + comment `[sprack] not written:`; (e) `convert a = a * c` / `a / c` exact by powers of ten (HSPICE AM `val0 = val0 / ampl`: ngspice `am(0 0.5 1 100k 1meg)` → HSPICE `am(1 500m 100k 1meg)`); (f) signals: `db(i(vm))` → Xyce `idb(vm)`, `-i(vc)` → Xyce `{-i(vc)}` / HSPICE `par('-i(vc)')`, `%2` template (Xyce `id(m1)` ↔ ngspice `@m1[id]`), `v(c)=0.5` keeps a signal before `=`; a dialect with no expr template and bare expressions refuses a signal expression (`the signal expression <e>`); (g) lexer: after `=`, parentheses with a top-level comma are a list: `table {v(a)} = (0,0) (1,2) (2,2)` → Xyce `table {v(a)} =(0,0)(1,2)(2,2)`; (h) model table values compare caselessly where the dialect folds case (HSPICE `modeltype=RLGC` → family rlgc) | `b4: controlled sources in POLY, TABLE, LAPLACE, POLE, VCR and VCCAP form` (a,g); `b4: lossy and coupled lines take their letter from the model` (b,h); `b4: source forms` (c,e); `b4: Spectre relay and port, VACASK control commands` (d); `b4: output forms and measurements` (f) | PARTIAL: not pinned: (a) the count-mismatch refusal; (f) the refusal of a signal expression in a dialect without an expr form (Spectre/VACASK) |
| a7cdc5c8 | 2026-11-14 | - | reader / writer | (a) a caveat on a text slot (a measure carried as text) is reported as code ambiguous, not caveat [code later replaced: error[invalid] `measure.spec: carried as text: ...; it is <src> text, written as it was` by 2768ed66]; (b) a matrix after a key extends only the parameter just read, never one read before a fixed `k==lit` entry (no out-of-bounds, no numbers glued onto an earlier parameter); (c) parameters move into slots only through rules whose required keys the statement has: a Spectre `vsource ... r=50` is not a port's z0 (only `port ... num=1 r=50` gives `port=1 z0=50`); (d) an expression recorded as a signal reads back from the dialect's own form: HSPICE `par('-i(vc)')` reads as the expression `-i(vc)` | `the report says what crosses: a dropped block's statements, text in another syntax, a block's lines` and `b4: output forms and measurements` (a, in its 2768ed66 form); `b4: Spectre relay and port, VACASK control commands` (c, port side only) | PARTIAL: (a) SUPERSEDED(2768ed66) and pinned there; (b), (c: the plain-source side), (d: reading par('...') back) not pinned |
| c9ba088a | 2026-11-14 | b4 (4.3-4.5, 4.7) | grammar:ngspice,hspice,xyce,spectre,vacask,ltspice,cdl / schema | new kinds lossyline, ctlsrc, relay, simctl and source/output forms: (a) lossy lines by model family: ngspice O(ltra)/Y(txl)/P(cpl) round-trip; → Xyce only `o1 a 0 b 0 lline`, errors `no xyce form of this statement can say a model of family 'txl'` and `no spelling for model family 'cpl'. Defined by: ngspice`; HSPICE `W1 ... RLGCmodel=pline N=2 l=10` round-trips, → ngspice error `... family 'rlgc'`; (b) ctlsrc: POLY E/G/F/H copied to Xyce/HSPICE; TABLE → Xyce; one-input POLY G → Spectre `g2 (0 o2 a 0) pvccs coeffs=[0 1m]`, two-input → error `more than one 'cpos'`; HSPICE LAPLACE/POLE/VCR round-trip, → ngspice error `no ngspice form of this statement can say form = laplace`; (c) Spectre `relay` read; → Xyce error `Xyce has no relay element`; (d) VACASK `print stats`, `postprocess(...)` in the control block round-trip as simctl; → ngspice error `simctl: 'print stats' is a command of vacask's control language`; (e) sources: ngspice pulse count, trnoise, AM in ngspice's argument order (`am(0 0.5 1 100k 1meg 1u 30 45)`), HSPICE AM offset relative to amplitude (HSPICE `am(2 0.5 100k 1meg)` → ngspice `am(0 1 2 100k 1meg)`), `ac` with no magnitude → `ac 1`, `dc=0 sin 0 50 100k` → `dc 0 sin(0 50 100k)`; into HSPICE errors `vsource.count = 2 has no spelling in hspice`, `vsource.wave = trnoise has no spelling in hspice`; HSPICE PAT → ngspice error `vsource.wave = pat has no spelling in ngspice`; (f) Spectre `p1 (b 0) port r=50 num=1` → Xyce `p1 b 0 port=1 z0=50`; (g) outputs: `.print ac db(i(vm)) ph(i(vm))` → Xyce `.print ac idb(vm) ip(vm)`; `vids#branch` → `i(vids)`; `-i(vc)` → Xyce `{-i(vc)}`, HSPICE `par('-i(vc)')`; Xyce `id(m1)` / Spectre `save m1:d` → ngspice `@m1[id]`; (h) `.measure` common forms read into slots: → Xyce `.measure tran tb trig v(b)=0.2 rise=1 targ v(b)=0.4 rise=1`, `param={tb*2}`; any other form stays text and is an error `measure.spec: carried as text`; (i) minor forms: ngspice trrandom, VACASK abort/elaborate, HSPICE VCCAP, Spectre pvcvs | `b4: lossy and coupled lines take their letter from the model`; `b4: controlled sources in POLY, TABLE, LAPLACE, POLE, VCR and VCCAP form`; `b4: source forms`; `b4: output forms and measurements`; `b4: Spectre relay and port, VACASK control commands` | PARTIAL: (i) trrandom, abort/elaborate, written VCCAP and pvcvs have no assertion; (a)-(h) pinned |
| b1c81f8d | 2026-11-14 | b4 | grammar:hspice,spectre / schema | (a) HSPICE `K1 L1 L2 k=0.5` is read as a coupling and translates exactly as the positional `K1 L1 L2 0.5` (0 untranslated); (b) Spectre source `pacmag=` and `fundname=` are slots of vsource/isource (and port), so a dialect without them reports a loss (`vsource.pacmag = ... has no spelling in <t>`) instead of copying the parameter | `gap: HSPICE coupling written with k=` (a) | PARTIAL: (b) not pinned (no test names pacmag or fundname) |
| 47a1ccba | 2026-11-14 | - | engine | bag entry `k==lit!@s:a`: a fixed key=value pair stands for an atom slot. Spectre `dc param=temp` sets var=temp (the temperature) on reading and is written only when var is temp; `param=rv` stays a parameter sweep: ngspice `.dc temp -40 125 5` → Spectre `dc1 dc param=temp start=-40 stop=125 step=5`; HSPICE `.dc rv 1k 10k 1k` → `dc1 dc param=rv start=1k stop=10k step=1k` | `more devices: behavioural and controlled sources, coupling, switches, lines`; `sweeps: what a .dc sweeps decides how it is written` | PINNED |
| 7e4e7073 | 2026-11-14 | - | engine / expr | `convert kind a==b : l = [a]`: when slot a equals slot b, a is written as the one item of list l, and a one-item l with no a reads back as a. ngspice `.dc V1 1 1 0.25` / `.ac lin 1 1k 1k` / `.noise v(b) V1 dec 4 100 100` → Spectre `dc1 dc dev=V1 start=1 step=0.25 values=[1]`, `ac1 ac start=1k lin=0 values=[1k]`, `noise1 (b 0) noise iprobe=V1 start=100 dec=4 values=[100]` and reads back as the same circuit | `sweeps: a sweep whose stop is its start` | PINNED |
| f182921e | 2026-11-14 | - | engine / writer | `$+list` in a default is the number of items of a list slot: HSPICE `.dc V1 poi 3 0.5 -1 2 I1 lin 2 0 1m` is written back with the count 3 computed from the points (the read count is discarded by `_`) | `sweeps: ranges by points, lists, keywords and tables`; `#45: an HSPICE .ac POI list of frequencies is the ac's values` | PINNED |
| fa412a94 | 2026-11-14 | - | writer | (refactor) the statement list is copied for convert lines only when one applies; output unchanged; bound to keep: translating a large ngspice netlist to Spectre/Xyce (both have converts) peaks under 0.8x the input size | `translation memory stays a small multiple of the input` | PINNED |
| 269c3d7b | 2026-11-14 | 5.1 | grammar:all / ir, schema | sweeps: (a) `.dc` of a netlist parameter: HSPICE `.dc rv 1k 10k 1k` → Spectre `dc1 dc param=rv ...`, VACASK `sweep sweep1 instance="__topinst__" parameter="rv" from=1k to=10k step=1k`, Xyce `.dc rv 1k 10k 1k`, ngspice error `no ngspice form of this statement`; (b) `.dc R1 ...` (an instance's own value) → Spectre `dc1 dc dev=R1 ...` (no param=dc), VACASK `sweep sweep1 instance="R1" ...` (no parameter=); Spectre `dev=V1 param=mag` → ngspice error `dc.devparam = mag`; (c) temperature as the outer loop: ngspice `.dc V1 0 1 0.5 temp 0 50 25` → Spectre `sweep1 sweep param=temp start=0 stop=50 step=25 {\ndc1 dc dev=V1 ...\n}`, VACASK `sweep outer1 option="temp" ...`, and a step around one dc folds back into the dc's outer loop; (d) DEC/LIN/POI/list/START= forms: HSPICE `.dc V1 dec 2 1 100` → Xyce `.dc dec V1 1 100 2`; LIN counts points in HSPICE, intervals in Spectre/VACASK (`lin 5 0 1` → `lin=4` / `points=4`); POI → Spectre `values=[0.5 -1 2]`; Spectre `values=[1 5 7]` → Xyce `.dc list V1 1 5 7`; `start=0 stop=1 step=0.25` → positional; (e) new kinds step and data: LTspice `.step param rv list 1k 3k` + `.step temp list -40 85` → Spectre nested `swp1 sweep param=rv values=[1k 3k] {\nswp2 sweep param=temp values=[-40 85] {...}}`, Xyce `.step rv list 1k 3k`; HSPICE `.temp -55 25 125` → Xyce `.step temp list -55 25 125`; a Spectre sweep around one of several analyses → Xyce error `a xyce sweep applies to every analysis of the netlist`; → VACASK error `VACASK has no sweep of the whole netlist`; HSPICE `.data rows rl V1 ... .enddata` + `.dc data=rows` → Xyce `.data rows rl V1 1k 1 3k 2\n.enddata\n.dc data=rows`; (f) Spectre stop=start → `values=[f]` (see 7e4e7073) | `sweeps: what a .dc sweeps decides how it is written`; `sweeps: ranges by points, lists, keywords and tables`; `sweeps: a sweep whose stop is its start`; `sweeps: a step repeats the analyses it holds`; py: `test_sweeps` | PINNED |
| e700e490 | 2026-11-14 | - | writer / grammar:vacask | (a) a step with no analysis to repeat, crossing dialects (HSPICE `.temp -40 85` in a deck with no analysis → Xyce): error[invalid] `step: the netlist has no analysis for the xyce sweep to repeat`; (b) VACASK: warning[caveat] on dc.step, ac.points and noise.points that VACASK counts sweep points with ceil() and no rounding tolerance | `sweeps: a step repeats the analyses it holds` (a) | PARTIAL: (b) the three VACASK point-count caveats are not asserted anywhere |
| 4b11f9ab | 2026-11-14 | - | engine | a .spgrammar directive line holding an empty quoted word (`bjt npn = npn ''`, `pow ""`) is refused: error.BadGrammar with `f.spgrammar:<line>: empty string` (was a panic in parseModels / a reader that looped without moving) | `fuzz: mutated grammars are refused with a diagnostic` | PINNED |
| f9ea7cf1 | 2026-11-14 | - | engine | grammar lists grow geometrically at run-time compile: a rule pattern of 3000 words and 100 lines of 20 function names each compile inside a 4 MiB fixed buffer (memory linear in grammar size, was O(n^2)) | `fuzz: long grammar lists compile in linear memory` | PINNED |
| a8436bc2 | 2026-11-14 | - | engine | the wildcard `_` is accepted only as a plain capture: `_...`, `_:"a"`, `{ ..._ }`, `-_` in a rule are error.BadGrammar `f.spgrammar:4: unknown slot '_'` (were compiler/writer panics) | `fuzz: mutated grammars are refused with a diagnostic` (the four `_` entries of `fuzzed_grammars`) | PINNED |
| 70fb1771 | 2026-11-14 | - | writer | a model or device statement without a name (from a broken grammar or from JSON) is not written by any dialect: error `model: a statement without a name cannot be written` / `mosfet: a statement without a name cannot be written`, statement kept as a comment (was a panic on `st.get("name").atom`) | `fuzz: a model or device without a name is reported, not written` | PINNED |
| e8f29c25 | 2026-11-14 | - | reader | a match may use at most 1 MiB of stack: `.hb tones=` followed by 20,000 words does not overflow in any reader; in HSPICE the statement too long to match is kept as an opaque line and the next `.hb tones=1k 2k nharms=3 3` still reads as kind hb | `fuzz: a statement of thousands of repeated words does not overflow the stack` | PINNED |
| 012fa25e | 2026-11-14 | - | engine | grammar patterns nested more than 100 deep (5000 `[`, or a chain of 5000 `define dN = <dN-1>`) are error.BadGrammar `groups nested more than 100 deep` (was a stack overflow) | `fuzz: deeply nested grammar groups are refused, not a stack overflow` | PINNED |
| 3f47bcf0 | 2026-11-14 | - | engine | a pattern of more than 10000 nodes with defines expanded (`define dN = <dN-1> <dN-1>` over 40 levels) is error.BadGrammar `f.spgrammar:45: more than 10000 nodes, defines expanded` (was out of memory) | `a define that doubles at each level is refused, not expanded` | PINNED |
| 26ac2ce9 | 2026-11-14 | 8.3 | writer | model cards whose parameters are copied by name between dialects give ONE warning[caveat] per file, naming the first card and counting the rest: ngspice (3 cards) → Xyce `model 'nch' (bsim4) and 2 more model cards: ngspice and xyce ship different implementations and versions ...`, and countCode(caveat) == 1 | `model cards: level numbers and master names are mapped, with a warning` | PINNED |
| e2d0d41d | 2026-11-14 | 7.3 | engine / writer / grammar:ngspice,xyce,hspice,spectre / python | `params kind ... end` tables: an instance parameter crossing dialects is checked against the target's table: (a) renamed to the target's spelling: ngspice `R1 a b 1k ... tc=1m` → Xyce `tc1=1m`; → Spectre `isnoisy=0`, `tc1=1m`; Spectre `isnoisy=0 trise=2` → ngspice `noisy=0 dtemp=2`; (b) a parameter the target's device lacks is error[loss]: `resistor: 'ac=2k' has no spelling in xyce, whose resistor takes no such instance parameter`, `isource: 'm=2' has no spelling in xyce`, `diode: 'w=1u' has no spelling in xyce`, and it is not written (`R1 a b 1k m=-2 tc1=1m`, `I1 a 0 dc 1m`); (c) `m>0` in a table: `resistor: m=-2: xyce refuses m of zero or less`; (d) a bare word naming a declared model is no flag: `Q1 c b e s1 t qm dtemp=1` → Spectre `Q1 (c b e s1 t) qm dtemp=1`; (e) Python: a PDK model-card device takes only the instance parameters of its dialect's table: `TypeError ... nmos_rvt is a mosfet of a hspice model card, which takes no parameter 'nfins'`; (f) the HSPICE table as a target (rename `noisy` → `noise`, losses, m>0) [the ESPice table: SUPERSEDED(d875ee84)] | `instance parameters: renamed for the target, a loss where its device lacks one` (a-d); py: `test_pdk_asap7` (e, env) | PARTIAL: (f) HSPICE as the target is not asserted; (e) PINNED-ENV (needs SPRACK_TEST_PDKS); the info[rename] entry itself is not asserted (only the renamed output) |
| dc1035a5 | 2026-11-14 | - | engine / writer / grammar:spectre,vacask | `default kind slot[=0] [cond] : kind.slot`: a value the source leaves to SPICE's default is written from another statement. ngspice `V1 a 0 pulse(0 1 0 0 0 10n 20n)` / `pulse(0 1 1n)` + `.tran 2n 50n` → Spectre `... rise=2n fall=2n ...` with warning[synthesized] `vsource.rise is 0: ngspice means the tran.step by that, and spectre needs it said; wrote 2n`; → VACASK also `width=50n` (tran.stop); with no .tran → error[invalid] `vsource.rise is 0: Spectre refuses a zero rise time` [the exp tau1/tau2 defaults: SUPERSEDED(de07dfb3, 284f713a)] | `a zero or missing pulse rise is SPICE's .tran step, written out where the target needs it` | PINNED |
| ba6f84d1 | 2026-11-14 | 8.5 | reader | the first-pass spelling table learns names only (name, node, model, reference slots, signal nodes, .ic keys), not keywords: ngspice `V1 a 0 DC 1` + `R1 a dc 1k` → Spectre `R1 (a dc) resistor r=1k` (node dc not respelled DC); a name is still spelled the way it is first capitalised: `R2 dc Out 1k` + `C1 out 0 1p` → `C1 (Out 0) capacitor c=1p` | `the spelling table holds names only: a keyword DC does not respell a node dc` | PINNED |
| ae35fa60 | 2026-11-14 | gap 4, 5 | lexer / grammar:hspice | (a) HSPICE: a single trailing `\` continues the line (the marker was spelled `\\` and never matched a single one); (b) a doubled `\\` continues too, joining with no blank; a quote or expression left open at the end of a continued line stays open on the next, so a `$` comment after its close is a comment: `.param a='(b == 1 ? c : \\` / `(b == 2 ? 3 : 4))' $ note (x), y` → Spectre `a=((b == 1 ? c : (b == 2 ? 3 : 4)))`, 0 untranslated; (c) HSPICE `.param sq(a,b)='(a+b)**2'` → ngspice `.func sq(a,b) {(a+b)**2}` (commas between arguments) | `gap: a $ comment after a backslash-continued HSPICE expression` (b); `gap: ngspice .func with several arguments needs commas` (c) | PARTIAL: (a) no test continues an HSPICE line with a single backslash (both tests use the doubled form) |
| e48768eb | 2026-11-14 | gap 8, 9 | engine / writer / grammar:spectre | (a) `unique param : why`: a parameter given twice in one scope crossing into Spectre is error[invalid] `parameter 'vt0' is defined twice in one scope; Spectre stops on a redefinition where SPICE keeps the last value`; (b) `unique master : why`: a device whose model name is also a subcircuit name was error[invalid] into Spectre [SUPERSEDED(68c96bb2): the model is renamed `<name>__m` with info[rename], pinned by `a subcircuit named like the model its transistor uses`] | `gap: a parameter defined twice` (a: asserts only that some report message contains `vt0`); `HSPICE dev/gauss= and names Xyce keeps for itself` (asserts error `parameter 'a' is defined twice`, ngspice source with dev/gauss between) | WEAK: (a) the plain HSPICE→Spectre case is asserted by a bare substring `vt0` with no severity, code or text; the stricter assertion exists only on the dev/gauss path |
| 3cdf3fdc | 2026-11-14 | 8.4, gap 10 | project / python / engine | (a) `sprack project --section tt` (option `sections`) follows only the named library sections and those that followed `.lib` lines name; each section not followed is logged `info[cosmetic]: section 'ff' not followed: ...`; (b) the Python PDK translates only its corner's sections, cached per corner (cache dir tag `<dialect>-<corner>`); (c) a `.lib file name` line is written with the section spelled as the defining file spells it: HSPICE `.lib 'w.lib' typ` where w.lib has `.lib Typ` → Spectre `include "w.lib" section=Typ`; (d) Verilog-A files named by `.hdl` are copied into the translated tree and the path rewritten like an include; (e) a caveat may hold for a path suffix (`caveat hdl path=*.osdi`): the compiled-OSDI warning is not attached to a `.va` source | project.zig: `a small project: includes followed, declarations shared, tree copied` (a); cli: `project ... --section tt` cases in build.zig (a); py: `test_tiny_pdk_corner_must_be_there` (b); `gap: a project keeps Verilog-A sources and section spellings` (c, e; d weakly) | PARTIAL: (d) the test passes if EITHER the .va file was copied OR the include line no longer says `"./cap.va"`: neither the copy nor the rewritten path is asserted on its own; (b) the per-corner cache directory name is not asserted |
| 3f81c5a6 | 2026-11-14 | 8.2 | expr / writer / grammar:ngspice,xyce,hspice,spectre,vacask,ltspice | (a) a choice is written in the form the target has: ngspice `ternary_fcn(x > 1, 3, 4)` → HSPICE `'(x > 1 ? 3 : 4)'`; `{x>1 ? 1 : 0}` → LTspice `{if(x>1, 1, 0)}`; a target with neither (CDL) → error `operator 'ternary' has no spelling in cdl`; an info[oneway] says the choice reads back in that shape; (b) `differs` lines become warnings when the function/operator is used: `pwr in ngspice: in .param the sign of a negative base is dropped`, `nint in xyce: halves round away from zero`, `negpow in ngspice`, `ln in hspice: a negative argument gives -ln\|x\|`; (c) the other measured rows: ngspice `**` with a negative base (pow), ngspice int() in .param only, Xyce pwr is pow, Xyce log10 of a negative, HSPICE log10 signed | expr.zig: `a choice is written in the form the target has`; `expression semantics: a choice in the target's form, and what evaluates differently` | PARTIAL: the info[oneway] of (a) and the rows of (c) are not asserted |
| 79a57dfa | 2026-11-14 | b2 | engine / reader, writer, schema | new kinds statistics, statgroup, vary, correlate, montecarlo, library, subckt.inline and engine pieces: (a) `spread kind`: a block written by adding its rule to each statement of its body and read back from the end of an analysis line (HSPICE `.tran 1n 1u sweep monte=30` ↔ Spectre `montecarlo numruns=30 variations=all {\ntran1 tran step=1n stop=1u\n}`); (b) a block kind with only a rule writes header then body; (c) model cards `nch.1`, `nch.2` are grouped under one model for a dialect with a model block (Spectre `model nch bsim4 {\n1: ...\n2: ...\n}`) and a binned model block is flattened back to `nch.1`, `nch.2`; an instance of `nch` resolves to the bins; (d) a Monte Carlo statement without a body takes the netlist's analyses (Xyce `.sampling` → Spectre montecarlo block) | `Monte Carlo: Spectre montecarlo, HSPICE monte=, Xyce .sampling` (a, d); `Spectre structure: binned models, inline subcircuits, libraries` (b, c); `gap: binned HSPICE models become one Spectre model group` (c) | PINNED |
| 472d4b47 | 2026-11-14 | - | stats | random functions ↔ statistics blocks: (a) into Spectre (no agauss, has statistics): top-level `.param p1 = agauss(1k, 100, 1)` → `parameters p1=1k` + `process {\nvary p1 dist=gauss std=100\n}`; a call inside a subcircuit (`r1 a b {agauss(1k, 100, n0)}`) → a new parameter `sprack_rv_rr_r1=0` varied per instance in `mismatch { vary sprack_rv_rr_r1 dist=gauss std=1 }` and the value `((1k + ((n0) == 0 ? 0 : (100)/(n0))*sprack_rv_rr_r1))` (ngspice's sigma-0 case kept); warning `written as spectre statistics variations`; (b) into a dialect with agauss(): a process `vary x dist=gauss std=0.1` of a parameter defined in the same list → `.param x={agauss(1, 0.1, 1)} y={aunif(2, 0.2)}` with warning `vary x: written as a random function` | stats.zig: `random calls are found with their arguments`; `statistics: Spectre blocks, SPICE random functions, HSPICE variation` | PINNED |
| b9dde6ee | 2026-11-14 | b2 | grammar:spectre,hspice,xyce + all | (a) Spectre statistics/process/mismatch/vary/correlate round-trip verbatim; → ngspice error `statement 'statistics' cannot be written for ngspice`, → HSPICE error `statement 'correlate' cannot be written for hspice`; (b) HSPICE `.variation` with `.global_variation`/`.local_variation` (absolute or `%`) round-trips; → Spectre error `vary.model = rm has no spelling in spectre`; (c) Monte Carlo: Spectre `mc1 montecarlo numruns=30 seed=1 {...}` → HSPICE `.tran '1u/1000' 1u sweep monte=30` + warning `HSPICE takes the Monte Carlo seed from .OPTION SEED`; → Xyce `.sampling useexpr=true\n.options samples numsamples=30 seed=1\n.tran {1u/1000} 1u`; → ngspice error `ngspice has no Monte Carlo statement`; (d) binned SPICE cards ↔ Spectre model group and back (`.model nch.1 nmos level=14 ...`); (e) Spectre `inline subckt` round-trips; → ngspice `.subckt cell a b` + warning `ngspice has no inline subcircuits`; (f) Spectre `library mylib ... endlibrary mylib` round-trips; → ngspice `* library mylib\n.lib tt\n...\n.endl tt\n* endlibrary` | `statistics: Spectre blocks, SPICE random functions, HSPICE variation`; `Monte Carlo: Spectre montecarlo, HSPICE monte=, Xyce .sampling`; `Spectre structure: binned models, inline subcircuits, libraries`; `expressions: functions, operators and variables are mapped`; py: `test_pdk_ihp` (env) | PINNED |
| 616e975f | 2026-11-14 | - | reader / lexer | (a) a line whose keyword starts rules of two kinds and that no rule reads whole is read as the shortest runs some rule reads, the keyword put back before each rest: HSPICE `.param` + `sq(x,y)='(x+y)**2'` + `k0 = 1` + `cu(x)='x**3'` (one continued line) → ngspice with `.param k0=1`, 0 untranslated, no errors; (b) an undelimited value after `=` holding braces the dialect does not delimit with stays a word and is flagged: HSPICE `X1 a b sub w={wn}` → warning `not a number, a name or a delimited expression in hspice` | `gap: function definitions and values in one HSPICE .param` (a); `corpus: things that would otherwise change meaning without a word` (b) | PINNED |
| 2425e6f1 | 2026-11-14 | - | grammar:hspice | HSPICE lexer `expr after-equals`: a bare call after `=` is one value: `.param dvt=agauss(0,1,3) du=aunif(0,1) wr = wmin*max(nf,2)/2` → Xyce keeps `agauss(0,1,3)` and `wmin*max(nf,2)/2`, 0 untranslated; HSPICE `nch.1`/`nch.2` cards → Spectre `model nch bsim4 {\n1: type=n lmin=50n lmax=200n vth0=0.4` | `gap: an unquoted function call is a value in an HSPICE .param`; `gap: function definitions and values in one HSPICE .param`; `gap: binned HSPICE models become one Spectre model group` | PINNED |
| 46ebf5c8 | 2026-11-14 | - | engine | grammar directive `reserved name ... : reason`: a parameter of that name crossing into the dialect was an error giving the reason [SUPERSEDED(c82c47e2): the parameter is renamed `<name>__p` where defined and used, with info `parameter 'vt' is written as 'vt__p'`; ba6a0908 extends it to sweeps, data columns and alters] | `HSPICE dev/gauss= and names Xyce keeps for itself`; `r1: a parameter named like a variable Xyce keeps is renamed where it is defined and used` (both assert the rename) | SUPERSEDED(c82c47e2) |
| 9ba3ead4 | 2026-11-14 | - | stats / grammar:xyce | (a) HSPICE-style `.param p=nom dev/gauss=s` (also `lot/` and `/unif`) is written as agauss()/aunif() in the definition for every target but HSPICE and the source dialect, with a warning naming `dev/gauss=`: ngspice `.param czero=1p dev/gauss=0.1p` → Xyce `.param czero={agauss(1p, 0.1p, 1)}`; → Spectre `vary czero dist=gauss std=0.1p`; → HSPICE keeps `dev/gauss=0.1p`; (b) Xyce's reserved parameter names vt, temp, time, freq, gmin were an error [SUPERSEDED(c82c47e2): renamed, `.param vt__p=3.5m`] | `HSPICE dev/gauss= and names Xyce keeps for itself` | PARTIAL: `lot/gauss=` and `dev/unif=` / `lot/unif=` are not asserted (only dev/gauss); (b) superseded and pinned in its new form |
| 5488267e | 2026-11-14 | - | engine / reader | grammar directive `switch "<words>" -> <dialect>`: from a line starting with those words the reader uses the named grammar until the next switch; each run is read on its own with the other lines blanked so line numbers stay the file's; statements carry their dialect; a file whose only switch names its own language reads as before | `Spectre: a simulator lang=spice section is read as HSPICE` | PINNED |
| bd8c7d2e | 2026-11-14 | - | grammar:spectre | Spectre `simulator lang=spice` sections are read with the HSPICE grammar: `r0 (a 0) resistor r=1k` / `simulator lang=spice` / `.param rv=2k` / `R1 a b 'rv*2'` / `simulator lang=spectre` / `r2 (b 0) resistor r=3k` → ngspice `r0 a 0 1k\n.param rv=2k\nR1 a b {rv*2}\nr2 b 0 3k`; → Spectre `parameters rv=2k\nR1 (a b) resistor r=rv*2` with `simulator lang=spectre insensitive=yes`; an unread line in the spice section is error `no hspice rule understood this line` at the file's line number (3) | `Spectre: a simulator lang=spice section is read as HSPICE` | PINNED |
| 8dfb488a | 2026-11-14 | - | writer | VACASK runs its control block in order, so options and saves are written before the analyses: ngspice `.noise v(in) V1 dec 4 10 10k` / `.options temp=0` / `.save v(in)` → VACASK `control\noptions temp=0\nsave v(in)\nanalysis noise1 noise ...` | `VACASK: options and saves come before the analyses in the control block` | PINNED |
| f8a16163 | 2026-11-14 | - | engine / writer / grammar:vacask | bag entry default `k=slot?$other`, written only for a statement from another dialect: ngspice `.tran 1u 1m` → VACASK `analysis tran1 tran step=1u stop=1m maxstep=1u` with warning[synthesized] `tran: vacask needs 'maxstep' to behave as ngspice does without it; wrote 1u`; a given maxstep is kept (`.tran 1u 1m 0 5u` → `maxstep=5u`); a VACASK deck is left as it was (no maxstep added) [refined by d6a25691: none is made up when step >= stop] | `VACASK tran: SPICE's step cap is written as maxstep`; `every pair of dialects: write, read back, same circuit, no errors`; cli: `translate --from ngspice --to vacask` warning | PINNED |
| 308545c3 | 2026-11-14 | - | grammar:vacask | ngspice `.nodeset v(q)=5` + `.op` → VACASK `analysis op1 op nodeset={"q",5}` with warning[caveat] `op.nodeset: VACASK pulls toward a nodeset only during its first Newton iteration ...` | `VACASK nodeset: a caveat, since it holds for one Newton iteration only` | PINNED |
| a3ecebbe | 2026-11-14 | - | engine / writer / grammar:vacask | grammar directive `noparam family key[=value] : text`: a model parameter so named is not written and is reported. VACASK: bsim3 `version`, bsim4 `version`, jfet `level`: ngspice `.model n3 nmos level=8 version=3.3 vth0=0.4` → `model n3 sp_bsim3v3 (type=1 vth0=0.4)`; `.model nj njf level=2 vto=-1` → `model nj sp_jfet1 (type=1 vto=-1)` + error `model 'nj': level not written: sp_jfet1 is the level 1 JFET` [severity later split by f2b17e4d: a dropped version / level=1 is a warning, one per file; JFET level 2 stays an error per card] | `VACASK model cards: a refused version is a warning, a refused JFET level 2 an error` (renamed from `VACASK model cards: parameters the shipped modules refuse are a loss` by f2b17e4d); `VACASK model cards: a refused version is one warning per file, a refused level an error per card`; `model cards: level numbers and master names are mapped, with a warning` | PINNED |
| 2f0d2eb2 | 2026-11-14 | - | grammar:vacask | a noise analysis written for VACASK carries warning[caveat] `noise.out: VACASK writes the output noise as a power density with the power gain ...` (no input-referred spectrum, no integrated noise) | `VACASK: options and saves come before the analyses in the control block` | PINNED |
| 9df73320 | 2026-11-14 | - | grammar:vacask, python | ngspice/built circuit, BSIM4 card with a numeric `version=4.5` → VACASK writes `model nch sp_bsim4v8 (type=1 vth0=0.4)` (version left out) and reports "version not written: VACASK ships BSIM4 4.8 only … takes version as a string" (an error in this commit; a warning, once per file, since f2b17e4d); the built tran is `analysis tran1 tran step=10p stop=8n maxstep=10p icmode="uic" ic={"out",0}` | py: test_build_every_dialect; "VACASK model cards: a refused version is one warning per file, a refused level an error per card" | PINNED |
| 137d6f02 | 2026-11-14 | - | grammar:vacask, writer | (a) ngspice→VACASK instance `m=2` is written `$mfactor=2` (tables for R, C, L, I, D, Q, J; the MOSFET table is open (`same ...`): it renames m and copies the rest, `M1 (d g 0 0) nm w=1u l=1u $mfactor=3 sa=1u`); (b) resistor `ac=2k` → error[loss] "resistor: 'ac=2k' has no spelling in vacask"; (c) VACASK→ngspice `$mfactor=` reads back as `m=`, also for a kind the target has no table for; (d) `sprack info` JSON offers no instance-parameter list for a dialect/kind whose table is open (so Python's PDK device call checks nothing there); the capacitor `ic=` loss of this commit is SUPERSEDED(5feb4d93: a series DC source `C1 (a C1__ic) capacitor c=1n`) | "VACASK instance parameters: m is $mfactor, resistor ac has no place" (renamed by 5feb4d93 from "…ic and resistor ac have no place") | PARTIAL (d unpinned) |
| ce7b69d6 | 2026-11-14 | - | grammar:vacask | ngspice `PULSE(0 1 0 1n 1n 0 0)` (PW given as 0, same as left out) with `.tran 10n 1u` → VACASK `width=1u period=0` and warning "vsource.width is 0: ngspice means the tran.stop by that" (VACASK's width=0 would mean no flat top) | "VACASK pulse: a width given as 0 is SPICE's TSTOP, as a missing one" | PINNED |
| 44cb89d2 | 2026-11-14 | - | grammar:spectre, reader | (a) any case-folding source (ngspice, HSPICE, …) → Spectre header `simulator lang=spectre insensitive=yes` then `global 0`, in every file of a project tree (the setting is per file); (b) Spectre→Spectre keeps what the source had: a plain header stays plain; `insensitive=yes` on the first line, on a later `simulator lang=spectre insensitive=yes` switch, or a `simulator lang=spice` section gives the folded header; (c) names the folding merges → error "'r1' and 'R1' are different names in the source but the same name in spectre"; (d) Spectre(insensitive=yes)→ngspice writes nothing of it (`t\nr1 a 0 1k\n.end`); the reader records `Netlist.folds_case`, carried in JSON as `folds_case` | "Spectre: insensitive=yes from a source that folds case, kept from Spectre"; "Spectre: a simulator lang=spice section is read as HSPICE"; project.zig: "a small project: includes followed, declarations shared, tree copied"; py: test_read_then_write_is_translate | PINNED |
| 168c6032 | 2026-11-14 | c2 | alter, reader | (a) HSPICE `.alter name` blocks are cumulative reruns of every analysis, written back as `.alter one\n.param ra=3k\n.alter two\n.temp 75`; (b) →Spectre `one altergroup {\nparameters ra=3k\n}` with the analyses written again after each (`op1 dc … op2 dc … op3 dc`), a temperature as `sprackOptionsN options temp=75`; Spectre `alter dev=/mod=/param=` and `altergroup` read back as alters (one-change alters with no analysis between are one rerun: →HSPICE `.alter a1\nr2 b 0 3k\n.model dm d is=1p`); analyses after an altergroup that are not the netlist's → error "the analyses after it are not those of the netlist"; (c) →Xyce `.data alters ra temp 1k 25 3k 25 3k 75\n.enddata\n.step data=alters`; (d) →VACASK `alter instance("__topinst__") ra=3k` / `options temp=75` between `analysis opN op` lines; (e) →ngspice one `.control` block per run: `alterparam ra=3k\nreset\nrun`, `reset\noption temp=75\nrun`; (f) an alter that changes a device → Xyce error[unsupported] "… changes only parameters and the temperature, not a resistor"; Spectre altergroup adding an instance → error "resistor 'R3' is not in the netlist"; (g) the same refusal for a device-changing alter into ngspice and VACASK; (h) an alter into LTspice or CDL (`no alter`) is error[unsupported] with the grammar's reason and its body is not written as the netlist's own lines; (i) HSPICE `SWEEP …` at the end of an analysis line is a `step` around that analysis: →Spectre `swp1 sweep param=rl start=1k stop=10k step=1k {\ntran1 tran step=1n stop=1u\n}`, HSPICE round trip `.tran 1n 1u sweep rl 1k 10k 1k`, `.op sweep data=rows`, one loop around a DC sweep becomes its outer loop `.dc V1 0 1 0.1 Vdd 1 2 0.5`; a `.temp -55 25 125` list around the only analysis stays a `.temp` line | "c2 alter: reruns with cumulative edits, in each dialect's form"; "c2 alter: Spectre alter and altergroup read back as alters"; "c2 sweep: HSPICE SWEEP at the end of an analysis line is a step around it"; py: test_sweeps, test_to_python | PARTIAL (g,h unpinned; the "every `no` line" test skips kind alter) |
| 1e288c33 | 2026-11-14 | c2 | grammar:espice | HSPICE `.alter` blocks → ESPice `.alter` written and read as HSPICE's | - | SUPERSEDED(d875ee84) |
| 70be96f3 | 2026-11-14 | - | topology, engine | (a) a translated netlist (e.g. ngspice→VACASK) with a node reached only by capacitors, MOS gates, controlled-source inputs or current sources → [invalid] "node 'x' has no DC path to ground: only C1, C2 reach it" (group form "nodes 'm', 'i' have no DC path to ground: only C3, C4 reach them"; cutset form "…which conduct no DC there, and the currents of the sources into it must balance"); nothing when every analysis is a UIC transient; (b) loops → "V1, V2, E1 form a loop of voltage sources through 'b' and '0'", "V1, L1 form a loop of voltage sources and inductors through 'a' and '0'", "L1, L2, L3 form a loop of inductors through 'q' and '0'"; an `.if/.else` pair defining the same element is no loop; with UIC only a V loop stays; (c) each subcircuit is summarized and checked on its own: instances carry its DC paths ("node 'mid1' …: only X1, X2 reach it"), its own island is "subcircuit 'bad': node 'f' has no DC path to ground: only C1 reaches it", an unknown cell joins its terminals, `.global` nodes and ground inside are paths; (d) severity comes from each grammar's `requires` lines: VACASK error on all four; Spectre and HSPICE warning on islands, error on V, V+L and L loops; Xyce warning on islands and L loops, error on V and V+L loops; ngspice warning on islands and V+L loops, error on V loops, no L-loop rule | "topology: capacitor islands, series capacitors and current cutsets have no DC path"; "topology: loops of voltage sources and inductors"; "topology: subcircuits carry their DC paths to the instance, and are checked on their own"; py: test_pdk_inverters_solvable (needs PDK checkouts) | PARTIAL (d: asserted only for VACASK (all), Spectre island + L loop, Xyce V loop + L loop, ngspice L loop, HSPICE cutset; HSPICE island and its three loops, Spectre V and V+L loops, Xyce island and V+L loop, ngspice island, V loop and V+L loop are unpinned) |
| 22ed612f | 2026-11-14 | - | topology | no topology entry (ngspice→VACASK) where the netlist does not say enough: (a) a scope holding a line no rule understood is not checked; (b) a Verilog-A module (`N1 y pm`), an XSPICE `A` device or a cell defined elsewhere is taken to reach ground inside; (c) a source with `portnum` (RF port, z0 in series) across an inductor is no loop; (d) a source an `.alter` defines again by name is one source; (e) the branches of a conditional make no loop | "topology: no alarm where the netlist does not say enough"; "topology: loops of voltage sources and inductors" (the conditional case) | PARTIAL (b: the XSPICE A-device case unpinned) |
| e30a214b | 2026-11-14 | c4 | reader, writer | (a) default TNOM/TEMP per dialect: HSPICE (TNOM 25, TEMP = TNOM)→ngspice writes `.options tnom=25` (deck sets `.temp`) or `.options temp=25 tnom=25` with warning[caveat] "options: hspice assumes other defaults for temp, tnom than ngspice does; they are written out"; HSPICE `.option tnom=50` → `.temp 50`; ngspice→HSPICE `.option tnom=27` and no `.temp`; equal defaults (ngspice→Xyce) write no `.options`; (b) SFFM order: HSPICE/Xyce `sffm(vo va fc mdi fs)` ↔ ngspice `sffm(vo va fm mdi fc)`: `sffm(0 1 10meg 0.5 1meg)` → ngspice `sffm(0 1 1meg 0.5 10meg)`, →Xyce unchanged; MDI and FM left out are written 0 (`sffm(0 1 0 0 10meg)`) with warning "limits the SFFM modulation index"; (c) HSPICE `.option gshunt=1m cshunt=1n delmax=50n` → ngspice `rshunt=1k cshunt=1n` and `.tran 1u 8u 0 50n` with info "options.delmax is written as tran.maxstep"; (d) `.dcvolt v(a)=1` and `.dcvolt b 2` → `.ic v(a)=1`, `.ic v(b)=2`; (e) HSPICE `.pz v(out) vin` → ngspice `.pz in 0 out 0 vol pz` (current source `.pz 0 in in 0 cur pz`), →Spectre `iprobe=vin`; unknown source → error "no voltage or current source 'vx'"; (f) multi-segment `.tran 0.1n 10n 1n 40n` → `.tran 0.1n 40n` with warning[caveat] "tran: a multi-segment .tran is one run to its last stop at its smallest step"; (g) `.option search='dir'`: `sprack project` resolves `.include`/`.lib` through it (`.include "dir/div.inc"`, `.lib "dir/c.lib" tt`) and drops the option; a single-file translation → error "options.search"; (h) `.parameters a=2 b=3` → `.param a=2 b=3`; (i) a `.measure` naming no analysis measures the last one (`.measure tran t50 when v(out)=0.5`), `derivative` → `deriv` (Xyce); (j) operators by dialect: HSPICE `%` read → error "% is not an operator the hspice grammar lists", unary `!` → Xyce error "operator 'not' has no spelling in xyce", ngspice `%` → Spectre error "operator 'mod' has no spelling in spectre", `!=` is no `!`; (k) HSPICE `.noise v(out) vin 1` after `.ac dec 10 1 1meg` → ngspice `.noise v(out) vin dec 10 1 1meg 1` (ESPice's form SUPERSEDED d875ee84); (l) HSPICE→ngspice `.measure … deriv` is an error (ngspice 45 measures no derivative); (m) extra `.tran` numbers that are neither rising pairs nor start+ceiling are an error | "c4: a dialect's default TNOM and TEMP are written where the target's differ"; "c4: SFFM argument order, HSPICE and Xyce against ngspice" (renamed by 2f837502); "c4: gshunt, cshunt and delmax"; "c4: .dcvolt in both spellings is the initial condition"; "c4: HSPICE .pz output and source as ngspice node pairs"; "c4: a multi-segment .tran runs to its last stop at its smallest step"; "c4: .option search finds includes in sprack project"; "c4: .parameters is .param in HSPICE"; "c4: unary ! and % are written only where the target has them"; "c4: a .measure that names no analysis measures the last one"; "c4: ngspice .noise takes the summary interval" (was "c4: ESPice .noise …") | PARTIAL (l,m weak: asserted only as `count(.error) > 0`, no message) |
| b0382fd6 | 2026-11-14 | c4 | reader, grammar:hspice | (a) HSPICE `.tran` numbers after step and stop are segments only when the stops rise (`.tran 1n 10n 2n 40n uic` → ngspice `.tran 1n 40n uic`); otherwise the first is SPICE's start time (`.tran 1n 100n 90n` → `.tran 1n 100n 90n`); (b) ngspice→HSPICE a step ceiling at or above the stop is not written (`.tran 0.1n 10n 1n 40n` → `.tran 0.1n 10n start=1n`, it would be a segment there); (c) this commit's carrying of the ceiling as HSPICE's fourth number is SUPERSEDED(284f713a): read from HSPICE it is left out with info "tran: HSPICE takes a fourth .TRAN number that is no second segment as nothing…" (`.tran 10n 1m 0 10n uic` → `.tran 10n 1m 0 uic`), written into HSPICE it is `.option … delmax=0.5n` + `.tran 1n 100n start=5n uic` | "c4: a multi-segment .tran runs to its last stop at its smallest step"; "nothing is dropped: a value with no place in the target is an error" | PINNED |
| 3c8d51ed | 2026-11-14 | c4 | reader, writer | (a) HSPICE `.tran 1n 1u SWEEP rl 1k 10k 1k` is a step around the tran, not `.tran` segments (segments are numbers and a trailing UIC only); (b) the source's assumed options are put in before the alters are laid out: HSPICE alters→Xyce base row at 25 (`.data alters ra temp 1k 25 3k 25 3k 75`) with warning "hspice assumes other defaults for temp, tnom than xyce does", →Spectre the alter's options are `sprackOptions2` (the defaults took 1); (c) an option set inside an `.alter` body is that run's, not the netlist's: `.temp 75` in an alter does not stand in for the netlist's default | "c2 alter: reruns with cumulative edits, in each dialect's form"; "c2 sweep: HSPICE SWEEP at the end of an analysis line is a step around it" | PINNED |
| 353e097d | 2026-11-15 | c5 | grammar:hspice, engine | (a) HSPICE `absv=1e-6 absi=1e-12` → ngspice `.options abstol=1p vntol=1u` (plain); (b) `relv=1e-3` → `.options reltol=1m` with warning "options.reltol: HSPICE's RELTOL (RELV) bounds node voltages only"; ngspice `reltol` → HSPICE `.option reltol=1m reli=1m …`; `relv=1e-3 reltol=2e-3` → error "options.reltol is given twice with different values"; `reltol=1m reli=1e-2` → error "options: 'reli=0.01' has no spelling in ngspice"; `reltol=1m reli=1m gmin=1n gmindc=1n` reads back as `.options reltol=1m gmin=1n`; (c) `gmindc=1e-9` → ngspice `.options gmin=1n` with warning "options.gmindc: HSPICE's GMINDC acts in DC"; different gmin and gmindc → Spectre error "options: gmin = 1n and gmindc = 1p are both 'gmin' in spectre"; ngspice `gmin=1e-9` → HSPICE `.option gmin=1n gmindc=1n`; HSPICE→HSPICE keeps `gmindc=1n`; (d) `method=bdf` → ngspice `.options method=gear`, Spectre `method=gear2`, with warning "options.method: HSPICE's BDF is not its GEAR" (none for GEAR); (e) `post` → info "options: 'post' is not written"; HSPICE→HSPICE keeps `.option method=bdf post` | "c5: HSPICE ABSV, ABSI and RELV are vntol, abstol and reltol"; "c5: HSPICE GMINDC and GMIN are one gmin elsewhere"; "c5: HSPICE METHOD=BDF is gear elsewhere, with a caveat; POST is dropped"; "c5: HSPICE RELI and GMINDC that repeat reltol and gmin read back as one value"; "options: one vocabulary, five ways of filing it" | PINNED |
| ec4c9ae5 | 2026-11-15 | - | reader | case-folding source (ngspice)→Spectre: a name an expression refers to but that is defined elsewhere keeps the spelling the source gives it, one spelling per name (`dc {VCM}` → `dc=VCM`, `{2*Rval}` → `r=2*Rval`, pulse/sin/pwl values too; source `VDD`, node `vdd` and parameter `VDD` stay three names); subcircuit-instance parameter keys keep one spelling (`Wn=1u`, `wn=2u` → `Wn=1u`, `Wn=2u`); a device's own keys are lower case (`W=1u L=1u` → `w=1u l=1u`) | "a name an expression refers to keeps its spelling when its definition is elsewhere"; py: test_code | PINNED |
| 08b441a9 | 2026-11-15 | d1 | topology | (a) a loop of V, V+L or L that closes through subcircuit instances at any depth is found without flattening and named by them: "V1, X1(in,0) form a loop of voltage sources through 'in' and '0'", "V1, Xw(a,b), V2 form a loop of voltage sources through 'b' and '0'", "V1, X1(a,0) form a loop of voltage sources and inductors …", "L2, X2(p,0) form a loop of inductors …"; a loop inside a subcircuit is reported once as "subcircuit 'dbl': V1, V2 form a loop of voltage sources", not per instance; a behavioural source, Verilog-A module, unknown cell or unread body adds no edge; (b) the ESPice `requires` lines are SUPERSEDED(d875ee84) | "topology: a loop through subcircuit instances, one and two levels down"; "topology: no alarm where the netlist does not say enough" | PINNED |
| 08b1fb58 | 2026-11-15 | d2 | writer, grammar:spectre | ngspice `.pz in 0 out 0 vol pz` → HSPICE `.pz v(out) vin` and Spectre `pz1 (out 0) pz iprobe=vin`: the input pair becomes the one V (vol) or I (cur) source across it, either way round (info "the reverse of the input pair; the transfer function changes sign, its poles and zeros do not"); no source or several → error "no voltage sources connect nodes in and 0" / "several current sources connect nodes in and 0"; a differential output → Spectre `pz1 (a b) pz iprobe=vin`, HSPICE error "hspice takes the poles and zeros of v(a) alone for v(a,b)"; HSPICE `.pz v(a,b) vin` → ngspice `.pz in 0 a b vol pz` with warning "hspice took the poles and zeros of v(a) alone for v(a,b)"; `pol` alone → HSPICE warning "pz: hspice finds both poles and zeros; only the poles were asked for" | "d2: ngspice .pz node pairs as HSPICE and Spectre output and source" | PINNED |
| 68c96bb2 | 2026-11-15 | c6 | lexer, writer | (a) every dialect with delimited expressions: a delimited expression joined to more by an operator outside the delimiters is one expression, delimiters dropped: ngspice `.param b = {2}*{cf} c = 1 + {cf} d={1+1}*3` → `.param b={2*cf} c={1 + cf} d={1+1*3}` (HSPICE `b='2*cf' c='1 + cf' d='1+1*3'`), no untranslated line; (b) writing Spectre, a model whose name a subcircuit also defines (same file or another file of the project) is renamed `<name>__m` together with every device using it by its SPICE letter (`m0 (d g s b) nch__m`, `model nch__m bsim4 {`), X instances keep the subcircuit (`X1 (d g 0 0) nch`), report info "'nch' names both a model and a subcircuit: the model is written as 'nch__m'", no error; (c) Python applies the library's renames to the circuit's own devices (`D2 (a 0) dm__m`) | "c6: a delimited expression joined to more by an operator is one expression"; "a subcircuit named like the model its transistor uses" (was "gap: …"); "c6: a model renamed for Spectre across the files of a project"; py: test_netlist_leaves_the_circuit_as_it_is, test_tiny_pdk_names_are_known_to_the_writer; py: test_pdk_gf180mcu (needs PDK checkout) | PINNED |
| fe08b98a | 2026-11-15 | c6 | lexer | where a bare expression may follow `=` (ngspice, HSPICE): a value with blanks around its operators is one expression (`.param p = 0.0 + mc*agauss(0,1.0,1)` → `.param p={0.0 + mc*agauss(0,1.0,1)}`), a sign alone is a number (`q = 1 r=-2 s = -3` → `q=1 r=-2 s=-3`); a stray `+` inside a line between two parameters is a blank (`.param x = '-1*y' + z = '0 - 2.5'` → `.param x={-1*y} z={0 - 2.5}`), not a function named + | "c6: a delimited expression joined to more by an operator is one expression"; py: test_pdk_installed_sky130_combined (needs installed sky130) | PINNED |
| 6a6c84b8 | 2026-11-15 | c6 | lexer | in a list of values a `+` or `-` with a blank before and none after starts the next value: ngspice `.model cm cpl c = 100p -60p 100p` keeps `c=100p -60p 100p` (no subtraction) | "c6: a delimited expression joined to more by an operator is one expression" | PINNED |
| dcc4c7d7 | 2026-11-15 | e1 | topology, engine | (a) a netlist with no analysis gets no topology entry at all (a cell netlisted on its own); (b) `requires X sev [analysis …] : reason` gates a rule on the analyses present, `tran` meaning one without UIC: ngspice→VACASK with `.op` or a plain `.tran` → error "node 'A' has no DC path to ground: only MMN, MMP reach it" / "node 'x' has no DC path to ground"; a loop rule with no list needs only some analysis (Xyce `.tran` → "V1, V2 form a loop of voltage sources"); (c) a netlist of dialect "sprack" whose tagged statements are all of the target's dialect is not a translation and is not checked; one statement tagged with another dialect makes it one (warning "node 'x' has no DC path to ground") | "e1: a deck with no analysis reports no topology; the analyses a rule lists gate it"; "e1: statements all read in the target's dialect are not translated: no topology report"; py: test_topology_needs_an_analysis | PINNED |
| 971f28c4 | 2026-11-15 | d3 | reader, engine | HSPICE (`quotes '"' expr-in-values except rlgcfile tstonefile`): a double-quoted token in a value slot is an expression — `.param t2="a^3" n="4"` → ngspice `.param a=2 t2={a**3} n=4`, `r1 n1 0 "2*a"` → `{2*a}`, `r="2 * a"`, `.temp "a*2"` → `.temp {a*2}`, subckt default, instance, model (`rsh={a/10}`), source and `.meas … param=` values — while `.include "dir/inc-a.sp"`, `.option search="sub"`, the label of `.meas dc "ia"` (→ `ia`) and `tstonefile="m.s1p"` stay strings; ngspice, Xyce and Spectre (`quotes '"' string`) keep `.param t="a*3"` a string | "d3: a double-quoted HSPICE value is an expression; a path or label stays a string" | PINNED |
| 90e7eb32 | 2026-11-15 | g1 | expr, grammar:spectre | (a) →Spectre `!=` is written with blanks (`(a!=b)` → `(a != b)`, `(a)!=-b` → `((a) != -b)`), every other operator unspaced (`a&&!b`); every dialect's expression reader ends a name before `!=` (Spectre `t=a!=b u=(a != b)` → ngspice `t={a!=b} u={a != b}`); (b) `preamble unless global`: a netlist with `.global vdd` → Spectre has the single line `global 0 vdd` and no separate `global 0`; with no global statement the preamble `global 0` stays | "g1: Spectre's != is written with blanks; one global line" | PINNED |
| bb7e3d2b | 2026-11-15 | h1 | topology, engine | an unbalanced current cutset (current source into a node only capacitors otherwise touch) follows the grammar's own `requires cutset` line where it has one (at HEAD LTspice: error under `.op` or a plain `.tran`, nothing under a UIC transient alone, reported when `.op` stands beside the UIC transient); a grammar with no cutset line reports it under its dc-path rule (HSPICE warning "…the currents of the sources into it must balance; HSPICE solves it"); the ESPice line this was written for is SUPERSEDED(d875ee84) | "h1: a current cutset follows its own requires line: not under a UIC transient" (ESPice cases rewritten on LTspice by 2f837502); "e1: a deck with no analysis reports no topology; the analyses a rule lists gate it" | PINNED |
| a4349767 | 2026-11-15 | t1 | json, ir | (a) `sprack read` then `sprack write` equals `sprack translate`: JSON keeps a dotted version a word (`"params":{"version":"3.3.0"}`), a parameter given twice as pairs (`[["toxref","1.26e-9"],["vsat","69000"],["toxref","1.3e-9"]]`), a negated signal (`"-i(vc)"`), an expression tagged (`{"expr":"13"}`), quotes/backslashes/control characters escaped; malformed JSON is error entries ("not valid JSON", "'10PF' is not a number", "'params' must be an object of name: value pairs" …), never fatal; (b) a grammar loaded from a file stays that grammar after `simulator lang=` switches back (was replaced by the built-in of its name); (c) Spectre pz output pair written as an HSPICE signal carries info "pz: the output nodes out 0 are the signal v(out), as hspice names it" (the audit was SILENT); (d) blanks in an expression are not a difference between two circuits; (e) every `no <kind>` line of every grammar gives error[unsupported] with that grammar's reason (CDL's `no model` too); (f) out of memory at any allocation returns OutOfMemory/WriteFailed with no leak and, when it returns, no lost report entry; (g) every translation in tests.zig also holds: same bytes twice, JSON reads back as the same statements, run-time grammar behaves as the built-in, the target reads its output as the same circuit or the report says why; `zig build test-cli` runs the command (exit 0/1/2, stdout and stderr text) | "JSON is the netlist: what a plain string would not read back as is tagged"; "Spectre: a simulator lang=spice section is read as HSPICE"; "d2: ngspice .pz node pairs as HSPICE and Spectre output and source"; ir.zig: "the same circuit: blanks in an expression are not content, anything else is"; "every `no` line: the kind is an error in that dialect, and the reason is the grammar's"; "out of memory at any allocation comes back as that: no crash, no leak"; "every kind, every slot, every dialect: written without a crash, and the JSON is the statement"; "each grammar file compiled at run time is the grammar compiled into the binary"; "caps: every kind has a rule, a place or a reason in every dialect"; cli: cliTests in build.zig | PINNED |
| f4b98c5d | 2026-11-15 | - | python | (a) `sprack.to_python`, `Circuit.python` and `python -m sprack --from D file` write any netlist as a flat script of builder calls (no def/class, no `.code(` except for a line no rule understood) whose circuit every dialect writes exactly as from the netlist — e.g. `c.model("nch", "bsim4", "n", version=4.5, vth0=0.4)`, `with c.alter("hot") as s:\n    s.param(rv="2k")\n    s.options(temp=85)`; every kind with every slot is rebuilt by a call (`with` blocks, params-typed slots, repeated parameter names, inline subcircuits, trailing comments, `sprack.word/quoted/expr`); (b) `Circuit.read` keeps Spectre's `insensitive=yes`; (c) the `model` alias does not hide the `model` slot of a `vary` | py: test_to_python, test_everything_has_a_function, test_read_then_write_is_translate, test_utf8_and_lf_on_every_platform | PINNED |
| f5562cc6 | 2026-11-15 | - | python | a PDK model card called as a device is the device's model, not its value: `c.rmod("R1", "a", 0, w="1u", l="10u")` → ngspice `R1 a 0 rmod w=1u l=10u`, Spectre `R1 (a 0) rmod w=1u l=10u` (same for a capacitor card); a card of a kind with no model slot → TypeError "… is a model card for kind 'vsource', which takes no model" (this commit's refusal of an inductor card is SUPERSEDED(59389682): `L1 a 0 lmod 2n tc1=0.01`) | py: test_tiny_pdk_model_cards | PINNED |
| 2750ce0b | 2026-11-15 | - | python | a PDK circuit's lib/include/hdl statements are tagged with the dialect of the file they name (the PDK's own file for its dialect, the translated copy otherwise), so `netlist(target)` writes `.lib "<root>/m.lib…` (ngspice) or `.lib "<cache>/tiny…` (xyce) with no "translate that file too" caveat, also for a circuit declared in another dialect (`dialect="hspice"`) | py: test_tiny_pdk_library_is_not_foreign | PINNED |
| a0250214 | 2026-11-15 | - | python | a manifest that lacks keys → SprackError "the manifest for PDK 'tiny' lacks dialect, corners, probe (of a layout); a manifest needs: name, dialect, layouts, corners"; a manifest with no `env` reads the root from `$PDK_ROOT` ("tiny: give root=, or set $PDK_ROOT"; with `env: ["TINY_ROOT"]` the message says "set $TINY_ROOT") | py: test_tiny_pdk_manifest | PINNED |
| 27abcb20 | 2026-11-15 | - | python | the PDK catalogue and the translated-tree cache are kept only while every file read (through includes too: size, mtime, sha1) is unchanged, and are keyed on the manifest's dialect, corners, define and variables: appending a subcircuit to an included file, or pointing `define` at another directory, shows the new devices and translated text, nothing of the old reading | py: test_tiny_pdk_cache_is_not_stale | PINNED |
| 89b8cb17 | 2026-11-15 | - | python, project | (a) choosing a corner whose file is not there → SprackError "tiny: corner 'ss' names … gone.lib, which is not there" (a corner not asked for may be incomplete); a corner naming a section no file defines → "tiny: corner 'ff' names section 'ff' of … m.lib, which defines: tt" when the files are read, for every target; (b) `sprack project --section typ` naming a section no file read defines → `top.sp: error[invalid]: section 'typ' is asked for, but no file read defines it`, summary `3 files, 1 error, 0 warnings`, exit 1; the project catalogue JSON lists `"sections":[{"file":…,"name":…}]` | py: test_tiny_pdk_corner_must_be_there; cli: project --section typ (build.zig `nosec`); project.zig: "a small project: includes followed, declarations shared, tree copied" | PINNED |
| 9b4d220c | 2026-11-15 | - | python | `Circuit.netlist()` leaves `c.statements` deep-equal to what it was while the written netlist carries the translated library copies (`include "<cache>/libs/…`) and the renamed models (`D1 (a b) dm__m`, `D3 (a 0) pm__m`); (refactor) the circuit is encoded once and only the statements it changes are copied | py: test_netlist_leaves_the_circuit_as_it_is | PINNED |
| 9a91157f | 2026-11-15 | l2 | grammar:ltspice, expr | (a) ngspice→LTspice (whole output compared): no `.options` for the shared 27-degree defaults; `pulse(0 1 1m)` gets the four values LTspice needs `pulse(0 1 1m 10u 10u 6m)` with warning "vsource.width is not given: ngspice means the tran.stop by that, and ltspice needs it said; wrote 6m"; `nint` → `round` (warning "nint in ltspice: halves round away from zero"), `pwr`, a minus before `**`, `&&`/`!`/`%` written with `differs` warnings ("pwr in ltspice: the sign of a negative base is dropped", "minuspow in ltspice: …", "andor in ltspice: LTspice has no && and \|\|"); `z0=50` → `zo=50`; `.lib 'f.lib' tt` → `.lib "f.lib" tt`; `.print tran v(a)` kept with warning "print.style: LTspice reads the line and prints nothing"; `.meas … find … at=` and `param={m1*2}`; (b) refused: `sin(0 1)` without a frequency → error "vsource.wave = sine has no spelling in ltspice" (line written `V1 a 0`), `hertz` → error "variable 'hertz' has no spelling in ltspice", `.probe` → error "no ltspice form of this statement can say style = probe"; (c) LTspice→ngspice: `B1 c 0 V=v(a) * 2 + 1` → `v={v(a) * 2 + 1}`, `.param s = 2 * 3 t = 5` → `.param s={2 * 3} t=5`, `Z0=75` → `z0=75`, `E1 … value={2*v(a)}` → `vol={2*v(a)}`, `.tran 1m` → `.tran {1m/1000} 1m`; a pulse rise of 0 → error "vsource.rise is 0: LTspice takes a tenth of the pulse width"; (d) LTspice `requires`: parallel V sources error "LTspice stops on voltage sources in parallel", cutset error, island / V+L loop / L loop warnings | "verification: LTspice 26.0.2, what running it showed"; expr.zig: "a choice is written in the form the target has" | PINNED |
| ded3032f | 2026-11-15 | - | lexer, reader | (refactor) logical lines are joined on demand and released once read, the reader's top level reads one statement at a time (`Reader.step`), report entries record their pass (`Report.phase`, so a streamed translation can sort them into the whole-netlist order); output and report unchanged for every input (line joining, comments, continuations, Spectre tokens as before) | lexer.zig: "lines, comments, continuation", "spectre tokens"; "a stream writes what the whole netlist does"; "translation memory stays a small multiple of the input" | PINNED |
| d7bf89c1 | 2026-11-15 | - | stream, writer | (refactor) (a) any streamable netlist translated one statement at a time gives byte-identical output and the same report entries (msg, line, severity, order) as the whole-netlist path, ngspice → spectre/xyce/hspice/vacask/ltspice; (b) ngspice 120x120 RC mesh → spectre/xyce: peak allocation <= 0.8x the input bytes (was 11.6x whole); (c) a netlist with an alter, a Monte Carlo of the whole netlist, a pole-zero analysis, a sweep, a statistics block, a binned model into a block dialect, an unlisted model type or a conditional block in a subcircuit (target without one) is read whole and `stream.translate` returns the reason; CLI env `SPRACK_WHOLE=1` forces the whole path, `SPRACK_STREAM_WHY=1` prints `sprack: read whole: <reason>` on stderr | "a stream writes what the whole netlist does"; "translation memory stays a small multiple of the input" | PARTIAL: (c) no test asserts a fallback reason or either env variable |
| ddd12030 | 2026-11-15 | - | stream, topology | (refactor) ngspice deck with two `.option` lines, a subcircuit instantiated before its definition (and the one it instantiates in turn) and `.param r0=1k dev/gauss=10` is still streamed (`why == null`) and gives the same text and report as the whole path (merged options in place of the first line, topology entries in the same order, dev/gauss rewritten per statement); into spectre the stream also writes the target's preamble (`global 0`) | "a stream writes what the whole netlist does"; cli: translate ngspice → spectre expects `global 0` | PINNED |
| 82ecaa9e | 2026-11-15 | - | stream, stats, cli | (refactor) (a) ngspice `.param w=agauss(1u, 0.1u, 3)` or `dev/gauss=` → spectre is streamed (`why == null`): variations gathered as statements are written, the statistics block written after the last, same text and report as whole; (b) the CLI reads its input (file or stdin) into one buffer of the file's size (measured peak RSS 1.5x input on a 111 MiB mesh, README) | "a stream writes what the whole netlist does" | PARTIAL: (b) no assertion (py test_memory measures the Python path, not the command) |
| a063a34c | 2026-11-15 | - | stream, reader | every allocation of a streamed translation failing in turn (ngspice → ltspice/spectre/vacask, `stream_deck`) comes back as error.OutOfMemory (or WriteFailed) with nothing leaked (source lines/tokens, writer case tables, topology scopes, `unique param` names freed on every way out) | "out of memory at any allocation comes back as that: no crash, no leak" | PINNED |
| f2b17e4d | 2026-11-15 | - | engine, grammar:vacask | (a) grammar line is `noparam family key[=value] warning\|error : text`; without a severity the grammar is refused: "noparam needs a model family, a parameter and a severity"; (b) ngspice `.model n3 nmos level=8 version=3.3 vth0=0.4` → vacask `model n3 sp_bsim3v3 (type=1 vth0=0.4)` + warning "model 'n3': version not written: sp_bsim3v3 implements BSIM3 3.3.0 only", no error; two bsim4 cards with `version=` in one file → ONE warning "model 'b.0' and 1 more card in this file: version not written: VACASK ships BSIM4 4.8", whole and streamed alike; (c) `.model n1 njf level=1` → warning "level not written: sp_jfet1 is the level 1 JFET"; `level=2` → error per card ("model 'j.0': level not written", "model 'j.1': ...") | "VACASK model cards: a refused version is a warning, a refused JFET level 2 an error"; "VACASK model cards: a refused version is one warning per file, a refused level an error per card"; grammar.zig: "a broken grammar at run time names the file and line" | PINNED (severity and text asserted; the code `loss` itself is not) |
| 462d1aae | 2026-11-15 | - | python, json | (a) the JSON `env` of a netlist (models, functions, subcircuits that files it names declare) round-trips through `parseNetlist`/`writeEnv` unchanged; (b) with it, writing for hspice/spectre/vacask gives no warning "'rmod' on R1 ... no model of that name is declared" and no error "function 'twice' has no spelling in hspice", while an undeclared master still warns "'nowhere' on R2 is a model name in sprack, but no model of that name is declared here; <target> will read it as a parameter"; (c) Python `Circuit(pdk=...).code("M1 (a a 0 0) nch w=1u l=1u\nR3 (a 0) rmod w=2u\n", "spectre")` reads devices of the PDK's models → ngspice `M1 a a 0 0 nch w=1u l=1u` / `R3 a 0 rmod w=2u`; (d) the netlist includes what only the libraries use (vacask `load "spice/diode.osdi"`) | json.zig: "a netlist says what the files it names declare"; py: test_tiny_pdk_names_are_known_to_the_writer | PINNED |
| cb8baf8a | 2026-11-15 | - | python, project | a PDK catalogue, its translated copy and an on-the-fly library copy are reused only while every `$NAME` their include paths expanded has the same value: changing or unsetting `$TINY_CELLS` re-reads all three, a variable no include path names leaves the cache files untouched; a project run reports the expansions as JSON (`{"MODELS":"<dir>"}`, `vars` in the summary) | py: test_cache_follows_include_variables; project.zig: "a small project: includes followed, declarations shared, tree copied" | PINNED |
| 5d1ac5a3 | 2026-11-15 | - | python | Python: `.lib "x.lib" tt` in text read with a grammar-file dialect (a `.spgrammar` path) → xyce netlist names the translated copy `<cache>/libs/<key>/tree/x.lib` with no "translate that file too" entry, the copy holds `.model nch nmos level=14`; the dialect's own netlist keeps the original path; a changed grammar file is another cache key (2 entries) | py: test_library_of_a_grammar_file_dialect | PINNED |
| e053e123 | 2026-11-15 | - | python | PDK manifest `"dialect": "NGSPICE"` resolves to `ngspice` (any case); an unknown name raises ValueError "unknown dialect 'pspice'"; a relative `g/mine.spgrammar` is looked for beside the manifest file | py: test_tiny_pdk_dialect_is_resolved | PINNED |
| 31b798ca | 2026-11-15 | - | writer | ngspice `.model rm r rsh=10` + `.subckt rm a b` + `R9 a 0 rm w=1u` → spectre `R9 (a 0) rm__m w=1u` with NO warning "is a model name in ..." (a model renamed for the target is declared under its new name) | "a subcircuit named like the model its transistor uses"; py: test_tiny_pdk_names_are_known_to_the_writer | PINNED |
| 59389682 | 2026-11-15 | - | grammar:ngspice,xyce,vacask, schema | inductor gets a `master` slot: (a) ngspice `L1 a 0 lmod 1m tc1=0.03` + `.model lmod l tc1=0.01` → xyce the same two lines; → vacask `L1 (a 0) lmod l=1m tc1=0.03` / `model lmod sp_inductor (tc1=0.01)`; no report entry; (b) xyce `L1 a 0 1m lmod` \| `L1 a 0 lmod 1m` \| `L1 a 0 lmod l=1m` with `.model lmod ind tc1=0.01` → ngspice `L1 a 0 lmod 1m` / `.model lmod l tc1=0.01`; (c) `L1 a 0 lmod` (value on the card) → vacask `L1 (a 0) lmod`, → xyce error "inductor.master = lmod has no spelling in xyce"; (d) → ltspice / hspice: `L1 a 0 1m tc1=0.03` and error "inductor.master = lmod has no spelling in <t>" (ltspice also "ltspice.spgrammar has no spelling for model family 'inductor'"); (e) Python: a PDK inductor card makes a device (`c.lmod("L1","a",0,"2n",tc1=0.01)`), a vsource/isource card raises TypeError "... takes no model: such a model holds no parameter". The "loss for Spectre" part was replaced by 7124d40e (master form); ESPice was removed in d875ee84 | "verification: an inductor's model between ngspice, Xyce and VACASK; a loss where no form is measured"; py: test_tiny_pdk_model_cards | PINNED |
| a1afc9a4 | 2026-11-15 | s1 | cond, writer | ngspice subcircuit whose `.if/.elseif/.else` branches (nested too) hold the same statements with other values → xyce: one statement with a nested choice `R1 a b {(sw == 0) ? ((floor(n/2)*2 != n) ? (1k*n) : (2k*n)) : ((sw == 1) ? (5k) : (7k+n))} tc1=0` + exactly one info[oneway] "cond_if: xyce has no conditional blocks; every branch holds the same statements, so they are written once"; → ltspice `{if(sw == 0, if(...), if(sw == 1, 5k, 7k+n))}`; → cdl error; a block that is not the same statements (no else, statement in one branch only, other kind/node/name/model, parameter in one branch only, a model card, a `.param`) stays error[unsupported] with that reason and the line `* [sprack] not written: statement 'cond_if' has no xyce form` | "s1: a conditional block of the same statements is written once, with conditional values" | PINNED |
| de07dfb3 | 2026-11-15 | s2 | writer, engine | an EXP source's left-out values are written where the target means otherwise: ngspice `V1 a 0 EXP(0 1)` + `.tran 1n 20n` → xyce `V1 a 0 exp(0 1 1n)` + warning[synthesized] "vsource.td1 is not given: ngspice means the tran.step by that, and xyce needs it said; wrote 1n"; → ltspice `exp(0 1 1n 1n 2n 1n)`; → vacask `type="exp" val0=0 val1=1 delay=1n td2=1n tau1=1n tau2=1n`; xyce → ltspice `exp(0 1 0 1n 1n 1n)`; ltspice → ngspice error "vsource.tau1 is not given: LTspice's default rise time constant is 0, an instant rise"; no `.tran` → error "... this netlist has no tran to take it from" (the xyce → ngspice direction was redone by 284f713a/51c48de6: `1a`) | "s2: an EXP source's left-out values are written out where the target means others" | PINNED |
| da5b074c | 2026-11-15 | - | ir, reader | a report entry that cannot be allocated sets `Report.lost`, and `reader.read`, `writer.write`, `json.parseNetlist` and `stream.translate` then return error.OutOfMemory instead of success with the entry missing; a run that does come back has as many entries as the run with memory | "a report entry that finds no memory fails the reading or the writing, whatever else succeeded"; "out of memory at any allocation comes back as that: no crash, no leak" | PINNED |
| 40420079 | 2026-11-15 | - | stats, writer | one info[oneway] per file where a variation is written the other way: (a) ngspice `.param vth={agauss(0.4, 0.01, 3)} tox={aunif(2n, 0.1n)}` + `R1 a b {gauss(1k, 0.1, 1)}` in a subckt → spectre: "3 parameters varied in a statistics block in place of a random function; spectre reads back the block, not the function"; (b) spectre `statistics { process { vary vth dist=gauss std=0.01 / vary tox dist=unif N=0.1n } }` → ngspice `.param vth={agauss(0.4, 0.01, 1)} tox={aunif(2n, 0.1n)}` + "2 parameters varied by a random function in the definition, in place of a variation given separately; ngspice reads back the function, not the variation"; (c) ngspice `dev/gauss=0.1p` → xyce "1 parameter varied by a random function ..."; (d) nothing varied → no entry | "statistics: a variation said the other way reads back that way, and one note for the file says so" | PINNED |
| 2b8503cc | 2026-11-15 | - | stats | JSON `{"kind":"statistics","params":[["k1",1],["flag",null]]}` written for ngspice/xyce/vacask/hspice/spectre → two error[loss] "statistics: 'k1=1' has no spelling in <t>" and "statistics: 'flag' has no spelling in <t>"; a statistics block with no parameters and no body writes nothing and reports nothing | "statistics: the block's own parameters are a loss where its variations are random functions"; "every kind, every slot, every dialect: written without a crash, and the JSON is the statement" | PINNED |
| d6a25691 | 2026-11-15 | - | writer | ngspice `.tran 101 20n` or `.tran 20n 20n` (step at or above the stop) → vacask `analysis tran1 tran step=101 stop=20n` with no made-up `maxstep` and no report entry; `.tran 101 20n 0 101` → `... stop=20n start=0` + info "tran.maxstep at or above the stop time limits nothing and is not written", no synthesized entry | "VACASK tran: SPICE's step cap is written as maxstep" | PINNED |
| 7e898c16 | 2026-11-15 | - | cli, json | `sprack write --to ngspice` on stdin `{"stmts":` → stdout empty, stderr `error[invalid]: not valid JSON: UnexpectedEndOfInput`, exit 1; on `[]` → stdout empty, `error[invalid]: the top level must be an object with 'stmts'`; a document with a problem inside (`{"title":"t","stmts":[{"kind":"zener"}]}`) → `error[invalid]: line 1: unknown statement kind 'zener'` and stdout `t\n.end\n`; `json.parseDocument` is null for the first two | "JSON that is not a document reads as nothing; a problem inside one leaves the rest"; cli: `write` cut / list / inside cases | PINNED |
| 644173cd | 2026-11-15 | s4 | reader | spectre `if (a == 1) { ... } else if (a == 1) { ... } else { ... }` with any of `a != 1`, `a <= b`, `a >= b`, `a > 1 && b < 3`, `a > 1 \|\| b < 3`, `a==1`, `a<=b&&a>=b\|\|a==b`, `(a == 1) && (b != 2)` → the condition is read exactly as written (no `a = = 1`), → ngspice `.if (a == 1)` / `.elseif (a == 1)` / `.else` with no untranslated entry; vacask `@if a==1&&b<=2\|\|b>=3` / `@elseif (a != 1) && (b >= 2)` → ngspice `.if (a==1&&b<=2\|\|b>=3)` / `.elseif ((a != 1) && (b >= 2))` | "s4: a Spectre condition keeps its two-character operators, whatever its first token" | PINNED |
| ec87e566 | 2026-11-15 | s3 | engine, writer | grammar line `computes resistor narrow short : formula` (kept at HEAD); a resistor card with NARROW or SHORT crossing ngspice/vacask ↔ xyce was copied with a warning stating both formulas — replaced by 9b8f8e6b (y2): the values are converted (xyce `narrow=1u` → ngspice `narrow=500n short=500n`; ngspice `narrow=1u short=1u` → xyce `narrow=2u`) or the card is an error when narrow and short differ | successor: "y2: Xyce's NARROW is ngspice's NARROW and SHORT at twice the number, or the card has no Xyce form" | SUPERSEDED(9b8f8e6b) |
| ece9d9a8 | 2026-11-15 | u1 | writer, grammar:xyce | ngspice/ltspice subcircuit with `.param` lines inside → xyce: all of them on the header in order, derived ones too (`.subckt rr a b params: r0=1k k={2*r0}`), instances `X1 1 0 rr params: r0=4k`, one info[oneway] per file "subckt 'rr' and 1 more in this file: the parameters defined inside are written on the header ..."; a name on the header and inside → the inner value is the default (`params: r0=3k w=2`); back to ngspice they are header parameters (`.subckt rr a b r0=1k k={2*r0}`); ngspice/ltspice targets and xyce → xyce keep `.param` inside with no entry; hspice → xyce keeps them inside + warning[ambiguous] "... what hspice does with one defined inside is not measured" | "u1: a subcircuit's inner parameters are written on the header where an instance sets only those" | PINNED |
| 1d6edd7a | 2026-11-15 | - | stats, writer | ngspice/hspice `.param a=1 dev/gauss=0.1 b=2 dev/gauss=0.2` → spectre: no "defined twice" error, `vary a dist=gauss std=0.1` / `vary b dist=gauss std=0.2`; inside a subckt `parameters x=((1k + 10*sprack_rv_s_x)) y=((2 + 0.2*sprack_rv_s_y))` + `mismatch { vary sprack_rv_s_x dist=gauss std=1 ... }`; → xyce `.subckt s p n params: x={agauss(1k, 10, 1)} y={agauss(2, 0.2, 1)}`; a real repeat `a=1 dev/gauss=0.1 a=2 dev/gauss=0.2` is still error "parameter 'a' is defined twice" | "HSPICE dev/gauss= and names Xyce keeps for itself" | PINNED |
| 9a38cfa6 | 2026-11-15 | r1 | writer, grammar:ngspice | (a) ngspice `.model nm psp103va type=+1 level=103.6 tr=27` + `N1 d g 0 0 nm w=1u l=0.13u nf=1 mult=1 dta=0` → xyce `.model nm nmos level=103 tr=27` + `MN1 d g 0 0 nm ...` + warning "model 'nm': its own 'level' is not written: in xyce that parameter names the model"; → spectre `model nm psp103 type=n level=103.6 tr=27` / `N1 (d g 0 0) nm ...`; → vacask `load "psp103v4.osdi"` + `model nm psp103va (type=1 level=103.6 tr=27)`; ngspice → ngspice unchanged, no entry; (b) `pspnqs103va` → xyce error "model 'nq' is of the Verilog-A module 'pspnqs103va'"; (c) xyce `.model nm nmos level=103` + `M1` → ngspice `.model nm psp103va type=1 tr=27` / `NM1 d g 0 0 nm ...` + warning "the deck must load psp103.osdi with pre_osdi"; (d) a model declared in another file of a project decides the instance's form: `N1 d g s b nm w=w l=l` → xyce `MN1 d g s b nm w={w} l={l}`, ngspice `N1 ...` | "r1: ngspice's psp103va is PSP103; its N instances are transistors"; "r1: a model in another file of a project decides its instances' form" (py: test_pdk_ihp needs SPRACK_TEST_PDKS) | PINNED |
| c82c47e2 | 2026-11-15 | r1 | writer, expr | ngspice `.param vt=3.5m Temp=2 vt__p=1` → xyce `.param vt__p2=3.5m temp__p=2 vt__p=1` (`vt__p`, or `vt__p2` when that is taken), renamed in `.func f(vt,b) {vt*b}`, the subckt header `params: vt__p2=1`, instance `params: vt__p2=2 w={vt__p2}` and every expression, with info[rename] "parameter 'vt' is written as 'vt__p2', where it is defined and wherever it is used: Xyce keeps this name" (2 rename entries); the node in `v(vt)` and a model's `vt=` are left; `.param time=1` stays error "parameter 'time': Xyce keeps this name for a variable of its own and refuses a parameter called so; rename it"; → hspice nothing renamed; in a project both files get `vt__p` | "r1: a parameter named like a variable Xyce keeps is renamed where it is defined and used"; "HSPICE dev/gauss= and names Xyce keeps for itself" | PINNED |
| 2f496077 | 2026-11-15 | r1 | writer, grammar:ngspice,xyce | (a) ngspice `C1 a 0 cm l=10u w=10u scale=3` → xyce `C1 a 0 cm l=10u w=10u m=3` + info "capacitor: the instance parameter 'scale' is spelled 'm' in xyce"; `m=2 scale=3` → `m=2` + error "capacitor: 'scale=3' is 'm' in xyce, which the instance gives as well" (and the mirror for `scale=3 m=2`); (b) ngspice `D1 k 0 dm off area=2` → spectre/vacask `D1 (k 0) dm area=2` + info "diode: 'off' is not written: OFF only sets where ngspice starts the operating-point iteration", no error; → xyce `D1 k 0 dm area=2 off`. (The commit's "a capacitor's ic=/q= stay errors for VACASK" was replaced by 5feb4d93 #28: `VC1__ic (C1__ic 0) vsource dc=0.5`) | "r1: an instance parameter the target says under another name, or that changes no result"; "instance parameters: renamed for the target, a loss where its device lacks one" | PINNED |
| c6e51fc1 | 2026-11-15 | r1 | grammar:xyce,hspice | (a) ngspice `.model nm psp103va type=1 ctgo=0 thecso=1.2 tr=27` → xyce `.model nm nmos level=103 tr=27` + error "model 'nm': thecso not written: Xyce's PSP103 has no such parameter and ignores it" + warning "model 'nm': ctgo not written: Xyce's PSP103 has no such parameter; at 0 it changes nothing"; (b) ngspice `N1 d g 0 0 nm w=1u l=0.13u dta=5 factuo=1` → hspice `MN1 d g 0 0 nm w=1u l=0.13u dtemp=5 factuo=1`, no error; (c) the same warning-at-the-neutral-value / error-otherwise pair for st2vfbo=0, ctbo=0, stcto=1, stthecso=0, nsubedgelexp=1 and thecso=2 | "r1: ngspice's psp103va is PSP103; its N instances are transistors" (py: test_pdk_ihp / test_pdk_sky130 count errors, need SPRACK_TEST_PDKS) | PARTIAL: (c) only thecso (off neutral) and ctgo=0 are asserted; the other five names and the neutral values 1 and 2 are read by no test |
| 0167eeb0 | 2026-11-15 | - | expr | `expr.eval` decides a condition over known parameters: numbers with scale suffixes, `+ - * /`, comparisons, `&& \|\| !`, parentheses, names (case-insensitive) bound to numbers or to such expressions (`xds<0.8e6 && !(XD == 0) \|\| 1 > 2` → 1; `-(1+2*3) + 4/2` → -5); anything else is not decided (null) and the token it stopped at is named: `floor`, an unknown name (`vdd`), a parameter with no value (`ic`), `?`, `*` of `**`, a self-reference (`loop`), `/` on a zero divisor, `)` missing, `its end` | expr.zig: "a condition over known parameters" | PINNED |
| d583b921 | 2026-11-15 | v1 | cond, writer | ngspice subcircuit with a conditional block its own (header or body) parameters decide, not mergeable as s1 → xyce (and cdl): the subcircuit is written once per branch under `* [sprack] 'msel' where (rfmode == 0)` / `* [sprack] 'msel' where !(rfmode == 0)` as `msel`, `msel__1`, ... (the defaults' branch keeps the name; several blocks multiply, up to 8), an instance is written with the one its parameters select (`X3 1 0 msel__1 params: r0=2k rfmode=1`), one info[oneway] per subcircuit "... so the subcircuit is written once for each branch of the block at line 14: 'csel' where (tc>1e9), 'csel__1' where !(tc>1e9); ... it reads back as 2 subcircuits"; an instance whose deciding value is not a number → `* [sprack] not written: instance 'X1'` + error "instance 'X1': subcircuit 'msel' is written once for each branch ..., and which of them this instance is depends on parameter 'rfmode', which is not a number here"; not decided (a global, a function), a branch holding something other than devices, more than 8, a taken name (`q__1`), or a block outside any subcircuit stays error[unsupported] with the reason appended ("nor is its subcircuit written once for each branch: ...") | "v1: a subcircuit is written once for each branch of a conditional block"; "v1: where a subcircuit is not written once for each branch, the error says why" | PINNED |
| e05a0076 | 2026-11-15 | v1 | json, writer | the environment carries the subcircuits that hold a conditional block (`conditional` in its JSON form, byte-identical through parse and write; 3 for the test library): an instance in another file of a project, in a stream with that env, or in a JSON netlist with that `env` is written with the subcircuit its parameters select → xyce `X7 1 0 dsel__1 params: xd=1u` | "v1: a subcircuit is written once for each branch of a conditional block" | PINNED |
| 009bbd04 | 2026-11-15 | - | python | (a) a PDK's catalogue/translated-copy stamp covers the build of the core (path, mtime and size of `_core`): another `_core.__file__` gives another stamp; a circuit on a tiny PDK names the branch its parameters select (`X2 a 0 msel__1 params: w=2u rfmode=1`) and the PDK's xyce copy holds `msel` and `msel__1`; (b) the key of a library translated on the fly covers the core's build too | py: test_tiny_pdk_subcircuit_for_each_branch | PARTIAL: (b) the library key is not asserted |
| 9ca39691 | 2026-11-15 | - | project | (a) Windows paths: `C:/` and the `//` of a share are roots and `\` separates: `C:\pdk\lib\..\models\x.lib` → `C:/pdk/models/x.lib`, `inc\sub.sp` under `C:/work` → `C:/work/inc/sub.sp`, `..` stops at the drive; on other hosts a backslash is a character of a name; (b) every path reported back (root, files, sections, the log) and the include lines of a translated copy use `/`, and the common directory of a project's files stops at the drive root | project.zig: "paths as Windows has them, on any host: a drive or a share is a root, a backslash a separator" (added by c98724b5 #55) | PARTIAL: (b) `commonDir`/`dirname` with a drive root and the reported paths are checked on no host but Windows (Python tests in the Windows CI job) |
| ed0f1db0 | 2026-11-15 | - | python | (a) Python writes a netlist file as UTF-8 with LF and reads files and stdin as UTF-8 on every platform (`Circuit("10 k\u03a9 divider").write(path)` bytes == `netlist.encode()`; `python -m sprack --from ngspice` reads it from a file and from stdin); (b) on Windows the cache sweep asks whether a writer's process is alive with OpenProcess, never `os.kill(pid, 0)` (CTRL_C_EVENT there); the cache directory is normalized and a path the core reports is compared after `os.path.normpath` | py: test_utf8_and_lf_on_every_platform; cache tests (test_library_translated_on_the_fly, test_tiny_pdk_*) on Windows | PINNED-ENV: needs a Windows host to tell (on POSIX the platform defaults already pass, and (b) runs only there) |
| 284f713a | 2026-11-15 | y1 | writer, engine | (a) each grammar says what an EXP source means by a value left out and a crossing writes it with warning[synthesized]: ngspice `EXP(0 1)` + `.tran 2n 50n` → hspice `exp(0 1 2n 2n 4n 2n)`, → spectre `vsource type=exp val0=0 val1=1 td1=2n tau1=2n td2=4n tau2=2n`; xyce → hspice `exp(0 1 0 2n 2n 2n)`; hspice `EXP(0 1)` → xyce `exp(0 1 0 25n 50n)` (TAU1 = (stop - td1)/2, TD2 = stop, TAU2 = (stop - td2)/2; `EXP(0 1 3n)` → `exp(0 1 3n 23500p 50n)`), → spectre `tau1=25n`; spectre → xyce `exp(0 1 0 500p 50n)` (TAU = stop/100), → hspice `exp(0 1 0 500p)`; no `.tran` → error "vsource.tau1 is not given: hspice means (tran.stop - td1) / 2 by that and xyce does not, and this netlist has no tran to take it from"; (b) a 0 in an ngspice EXP is a value left out: ngspice `EXP(0 1 0 0.5n 0 0)` → xyce `exp(0 1 2n 0.5n 4n 2n)` + warnings "vsource.td1 is 0: ngspice means the tran.step by that ..."; xyce `EXP(0 1 3n 0 0 0)` → ngspice errors "vsource.tau1 is 0: ngspice reads a 0 there as not given ...; a 0 cannot be said" and the same for td2; (c) HSPICE's step cap is `.option delmax`: ngspice `.tran 2n 50n 0 0.05n` → hspice `.option tnom=27 delmax=0.05n` + `.tran 2n 50n start=0` (an options statement is made where there is none: `.option delmax=50p`); hspice `.option delmax=0.05n` → xyce/ltspice `.tran 2n 50n 0 0.05n`, spectre/vacask `maxstep=0.05n`, info "options.delmax is written as tran.maxstep"; hspice `.tran 2n 50n 0 0.05n` → xyce `.tran 2n 50n 0` + info "tran: HSPICE takes a fourth .TRAN number that is no second segment as nothing"; several trans: a `.tran` without a cap gets warning "tran.maxstep is not given: hspice says it once for the whole netlist (options.delmax) ...", another cap → error "tran.maxstep = 1n has no spelling in hspice"; (d) expr: `a / b` is exact when b has no prime factor but 2 and 5 (`23500p`, `25n`) | "y1: an EXP source crossing into or out of HSPICE and Spectre says what was left out"; "y1: a 0 in an ngspice EXP source is a value left out"; "y1: HSPICE's step cap is .OPTION DELMAX, and a fourth .TRAN number is nothing"; "s2: an EXP source's left-out values are written out where the target means others"; "c4: a multi-segment .tran runs to its last stop at its smallest step"; "nothing is dropped: a value with no place in the target is an error" | PINNED |
| 51c48de6 | 2026-11-15 | y1 | writer, grammar:ngspice | a delay of 0 crossing into ngspice is written as the smallest delay ngspice takes as given: xyce `EXP(0 1)` + `.tran 1n 20n` → ngspice `V1 a 0 exp(0 1 1a)`; hspice `I2 0 b EXP(0 1)` + `.tran 2n 50n` → ngspice `I2 0 b exp(0 1 1a 25n 50n)`, each with warning[synthesized] "<kind>.td1 is 0: ngspice reads a 0 there as not given and would take the tran.step; wrote 1a, which it takes as given"; a TAU1 or TD2 of 0 stays an error | "s2: an EXP source's left-out values are written out where the target means others"; "y1: a 0 in an ngspice EXP source is a value left out" | PINNED |
| be7bbaac | 2026-11-15 | z2 | engine, grammar:ltspice | grammar line `unique analysis dc ac tran noise tf beside op : reason`; ngspice deck with `.dc` and `.ac` → ltspice: both still written, error[invalid] naming them (form since 291ce19b: one entry on each analysis at its own line, "dc: one of 2 analyses in this netlist (dc, ac); LTspice refuses a deck with more than one analysis (\"More than one analysis specified.\"), unless there are two and one is .op, which it then does not run on its own"); `.op` + `.tran` + `.op` → 3 errors; `.tran` + one `.op` → both written, warning "op beside tran; ..."; `.four`, `.meas`, two `.op` alone, ltspice → ltspice and ltspice → ngspice say nothing | "z2: more analyses than LTspice loads in one deck are an error on each that names them" (renamed by 291ce19b); "every pair of dialects: write, read back, same circuit, no errors" | PINNED |
| b824243c | 2026-11-15 | z2 | reader, engine | ltspice `.lib f.lib` / `.lib "g.lib"` in a deck (one word, no `.endl` after it) → ngspice `.include "f.lib"` / `.include "g.lib"`, no "block not closed" entry; `.lib "s.lib" slow` stays `.lib "s.lib" slow`; in a file of sections `.lib fast` ... `.endl fast` is a section and a bare `.endl` closes → `.endl slow` (grammar: a block's opening line opens it only where a line starting with its closing word follows) | "z2: an LTspice .lib with no section loads the whole file; a section is one an .endl closes" | PINNED |
| f23e7426 | 2026-11-15 | z2 | lexer | ltspice or ngspice `B1 a 0 I=v(c) > 0.5 ? 1m : 2m`, `B2 b 0 V=v(c) != 2 ? v(c) * 2 : 0`, `.param p = 1 >= 0 ? 5 : 6 q = 2` → xyce `B1 a 0 i={v(c) > 0.5 ? 1m : 2m}`, `B2 b 0 v={v(c) != 2 ? v(c) * 2 : 0}`, `.param p={1 >= 0 ? 5 : 6} q=2`, no entry (an expression after `=` goes on across a blank next to `?`, `:`, a comparison, `&`, `\|`; the `=` of a comparison starts no parameter); `.param x = 2 * 3 y = 4` → `.param x={2 * 3} y=4` | "z2: a choice with blanks around its operators is read after an equals sign, in LTspice and in ngspice" | PINNED |
| 42c1435a | 2026-11-15 | z2 | grammar:ltspice | LTspice sources have a params table (`params vsource same rser cpar`, `params isource same load`): ngspice `I1 0 b pwl(0 0 1m 1m 2m 0) td=1m m=2` → ltspice `I1 0 b pwl(0 0 1m 1m 2m 0)` + error[loss] "isource: 'td=1m' has no spelling in ltspice, whose isource takes no such instance parameter"; ltspice → ltspice keeps `rser=1 cpar=1p` with no entry. (The commit's "`r=` repeat is a loss" was replaced by 21aef6d1 #73: `r=0` → `pwl repeat forever (...) endrepeat`; a repeat from another point is the loss) | "z2: a PWL's repeat into LTspice: from the first point REPEAT FOREVER, from another a loss (#73)" (successor of the removed test) | PINNED |
| ff60377b | 2026-11-15 | z2 | grammar:ltspice | LTspice `sine(0 1 1k 0 0 0 3)` (7th value = number of cycles) is read into slot `count` and written back unchanged LTspice→LTspice with an empty report; LTspice→ngspice writes `V1 a 0 sin(0 1 1k 0 0 0)` plus error[loss] `vsource.count = 3 has no spelling in ngspice` (isource likewise); ngspice `pulse(0 1 0 1u 1u 0.5m 1m 2)` (8th value = number of pulses) → LTspice the same eight values, no error | `z2: the cycles of an LTspice sine have a slot, and are a loss where a sine has none` | PINNED |
| 291ce19b | 2026-11-15 | z2 | writer | ngspice→LTspice deck with more than one analysis: every analysis is still written, and EACH gets its own error (invalid) at its own line, naming all of them: `dc: one of 2 analyses in this netlist (dc, ac); LTspice refuses a deck with more than one analysis ("More than one analysis specified."), unless there are two and one is .op, ...` (2 errors at lines 4 and 5; 3 errors for op,tran,op); one `.op` beside one other analysis → no error, warning `op beside tran; ...` with no line number in its text; `.four`, `.meas`, two `.op`, and LTspice→LTspice say nothing; LTspice→ngspice says nothing | `z2: more analyses than LTspice loads in one deck are an error on each that names them`; `every pair of dialects: write, read back, same circuit, no errors` (counts one error per analysis) | PINNED |
| 7124d40e | 2026-11-15 | y2 | grammar:spectre | ngspice `L1 a 0 lmod 1m tc1=0.03`, `L2 b 0 lmod`, `.model lmod l tc1=0.01` → Spectre `L1 (a 0) lmod l=1m tc1=0.03`, `L2 (b 0) lmod`, `model lmod inductor tc1=0.01` with no error, and Spectre→ngspice gives the three ngspice lines back; →HSPICE the instance is written without its model (`L1 a 0 1m tc1=0.03`) and error[loss] `inductor.master = lmod has no spelling in hspice` stays (LTspice likewise) | `y2: an inductor's model in Spectre, and its IND` (the commit's test `y2: a Spectre inductor names its model as its master`, renamed by 9b8f8e6b); `verification: an inductor's model between ngspice, Xyce and VACASK; a loss where no form is measured` | PINNED |
| 9b8f8e6b | 2026-11-15 | y2 | engine, writer (grammar:hspice,ngspice,spectre,vacask,xyce) | `modelparams family ... end` tables: (a) a resistor card's NARROW/SHORT is written under the target's first spelling with info[rename] `the parameter 'narrow' is spelled 'dw' in hspice`: ngspice `narrow=1u short=0.5u` → HSPICE `.model rm r rsh=1000 dw=1u dlr=0.5u`, Spectre `etch=1u etchl=0.5u`, VACASK unchanged (ngspice and VACASK also read dw/dlr); a card with neither (`tc1=`) crosses with no rename/loss entry; (b) Xyce `narrow=1u` → ngspice/VACASK `narrow=500n short=500n` (an expression: `narrow={(a)/2} short={(a)/2}`), HSPICE `dw=500n dlr=500n`, Spectre `etch=500n etchl=500n`, info `each half its value`; ngspice `narrow=x short=x` → Xyce `narrow=2x` (HSPICE `DW='a' DLR='a'` → `narrow={(a) * (2)}`), info `twice the value`; (c) NARROW ≠ SHORT (one left out is 0) into Xyce → neither written (`.model rm r rsh=1000`) and an error stating both formulas (`... not written: xyce has the one parameter 'narrow' for narrow and short, and they are not equal here (one left out is 0): xyce computes R = RSH (L - NARROW) / (W - NARROW), with no SHORT; ngspice computes R = RSH (L - 2 SHORT) / (W - 2 NARROW)`); `narrow=0` alone → `narrow=0`, nothing said; (d) inductor card `ind=3m` ↔ Spectre `l=3m` (info rename both ways), VACASK `ind=3m`, Xyce: not written + warning `model 'lmod': ind not written: Xyce's inductor model has no IND`; (e) a name the SOURCE's own model ignores (HSPICE card `narrow=3u`, Xyce card `short=0.3u`) is not handed on: warning `model 'rm': narrow not written: the resistor model of hspice does not take it; that parameter is 'dw' there` | `y2: a resistor model's NARROW and SHORT are written by the target's names`; `y2: Xyce's NARROW is ngspice's NARROW and SHORT at twice the number, or the card has no Xyce form`; `y2: an inductor's model in Spectre, and its IND`; py: `test_tiny_pdk_model_cards`; py: `test_pdk_sky130` (env: sky130 checkout) | PINNED |
| d36f98fc | 2026-11-15 | z1 | reader, schema | a name has one spelling among the names of its KIND (node, device, model, parameter, subcircuit), not across kinds: (a) ngspice `Vdd vdd 0 1`, `.print dc v(vdd) i(vdd)`, `.ic v(vdd)=1` → ngspice/Xyce `Vdd vdd 0 dc 1`, `R1 vdd out 1k`, `.print dc v(vdd) i(Vdd)`, `.ic v(vdd)=1`; Spectre `Vdd (vdd 0) vsource dc=1`, `save vdd Vdd:p`, `ic vdd=1`; (b) a node written `vdd` and `VDD` is one node, spelled `VDD` everywhere including `.ic v(VDD)=1` and `v(VDD)` in expressions; (c) a model, parameter, node and subcircuit of the same letters each keep their own spelling (`.param Out=2`, `.model Out nmos`, port `OUT`, `M1 OUT in 0 0 Out w={nch} l={Out*1u}`, `X1 a OUT VDD Inv`); (d) a device named in a list takes the device's spelling (Xyce `F1 c 0 poly(2) v1 V2 0 1 1` → `poly(2) V1 V2`), while node `v1` stays and a terminal (`ID(m1)`) is no name; (e) a swept parameter is spelled as its definition: Xyce `.param vcm=1` + `.dc VCM 0 1 0.1` → VACASK `parameter="vcm"` while node `VCM` stays `VCM` | `a name has one spelling among the names of its kind: a source Vdd leaves the node vdd`; `a name an expression refers to keeps its spelling when its definition is elsewhere`; py: `test_a_node_is_not_the_source_on_it`; py: `test_to_python` | PINNED |
| d875ee84 | 2026-11-15 | e2 | grammar:espice, cli | (removal) the ESPice dialect no longer exists: `sprack dialects` prints exactly `cdl`, `hspice`, `ltspice`, `ngspice`, `spectre`, `vacask`, `xyce` (one a line), `info` and `caps` have those seven, an unknown dialect is exit 2 with `unknown dialect 'pspice'. Built in: cdl hspice ltspice ngspice spectre vacask xyce; or a path to a .spgrammar file`, and no "Dialects that define it:" / "Defined by:" list names espice (pz into Xyce: `Dialects that define it: hspice, ngspice, spectre`) | `cli: dialects`, `cli: info`, `cli: caps`, `cli: unknown dialect 'pspice'`, `cli: pz into xyce stderr`; py: `test_vocabulary_is_closed`; py: `test_translate`; `an analysis the target cannot express is an error naming who can, and why` | PINNED |
| fa7180a9 | 2026-11-15 | e2 | schema | (removal) the kind `verilog` (`.verilog <path>`) and the slot `points` of `pss` (`.pss fund [points]`) are gone from the schema, and the seven `no verilog : ...` lines from the grammars: a `.verilog top.v` line is read by no rule (untranslated across dialects) and no JSON statement has `pss.points` | none asserts the absence; indirect only: `caps: every kind has a rule, a place or a reason in every dialect` would fail if the kind came back without its `no` lines | WEAK |
| 5765a544 | 2026-11-15 | m2 | grammar:xyce, engine | (a) ngspice `.options gmin=1e-10 reltol=1e-5` → Xyce `.options timeint reltol=1e-5`, `.options nonlin reltol=1e-5`, `.options nonlin-tran reltol=1e-5`, `.options device gmin=0.1n`, no error (abstol likewise under the three packages); (b) grammar form `k=slot+`: Xyce→ngspice the three lines read back as the one `.options reltol=1e-5`, Xyce→Xyce the text is identical with an empty report, and a reltol under nonlin alone that differs from timeint's is kept apart (→ngspice error[loss] `options: 'reltol=1u' has no spelling in ngspice`); (c) `vntol`, `trtol`, `chgtol` into Xyce are error[loss] ending in the grammar's `no options <slot> : reason` text (`options.vntol = 10n has no spelling in xyce: Xyce has no voltage tolerance: the ABSTOL of each package bounds node voltages and branch currents alike`; trtol `Xyce has no factor on the truncation error`; chgtol `Xyce's step control bounds the error of each unknown, not of a charge`), exactly 3 errors, plus warning `options.abstol: Xyce's ABSTOL bounds node voltages as well as branch currents`; (d) every slot-level `no <kind> <slot> : reason` line of every grammar ends the loss error of that slot; (e) HSPICE `.option absv=1u absi=1p` → Xyce `.options nonlin abstol=1p` + the vntol error | `xyce: a tolerance is three options, and vntol, trtol and chgtol are none`; `options: one vocabulary, five ways of filing it`; `every `no` line: the kind is an error in that dialect, and the reason is the grammar's` | PINNED |
| 5feb4d93 | 2026-11-24 | #28 | writer, grammar:vacask | (a) ngspice capacitor `C1 a b 1n ic=0.5` → VACASK `C1 (a C1__ic) capacitor c=1n` + `VC1__ic (C1__ic b) vsource dc=0.5` + `model vsource vsource`, info `capacitor 'C1': vacask's capacitor takes no initial voltage (ic=0.5); it is written to node C1__ic`, no error; the same inside a subcircuit and inside each branch of an `.if` block; stream output equals whole-netlist output; (b) an `.ic` on one of that capacitor's nodes (top level `v(b)`, or a hierarchical name ending in the node, `v(x1.a)`) → error `capacitor 'C1': ic=0.5, and an .ic sets node b too` (one error); (c) `Cg b 0 q='1p*v(b)+min(v(b),0)*1f' m=2` → VACASK `Cg (b 0) i=2*ddt(1p*v(b)+min(v(b),0)*1f)` with info `capacitor 'Cg': vacask's capacitor takes no charge (q=)`; VACASK→ngspice `BCg b 0 i={2*ddt(...)}`; (d) `ddt` is a canonical function of ngspice and VACASK only: ngspice→Xyce error `function 'ddt' has no spelling in xyce` | `VACASK capacitor: ic= is a DC source in series, q= a behavioural source of ddt(q)`; `VACASK instance parameters: m is $mfactor, resistor ac has no place`; `r1: an instance parameter the target says under another name, or that changes no result` | PINNED |
| 9ac764e9 | 2026-11-24 | #30 | grammar:xyce | ngspice `.model dd d level=3.0 is=1e-15 mj=0.3` → Xyce `.model dd d is=1f mj=0.3` (the level is not written) and exactly one error `model 'dd': level not written: Xyce 7.10's diode has levels 1, 2, 200 and 2002 ...` (grammar line `noparam diode level=3 error`); a `level=1` card → no error | `Xyce: a diode card of ngspice's level 3 is an error, a level 1 card is not`; py: `test_pdk_sky130`, `test_pdk_gf180mcu` (env: PDK checkouts; error counts) | PINNED |
| 3cf2965a | 2026-11-24 | #31 | engine, writer (grammar:xyce) | a models-table spelling may end in `when` conditions (`key=value` on the card, `nodes>=n` on every instance in the file naming the card); the first spelling whose conditions hold is written: (a) ngspice VBIC card `level=4` named by a 5-terminal `Q1 c b e s t q1` → Xyce `.model q1 npn level=12 ...`, by a 3-terminal Q → `level=11`; named by instances of both counts → `level=11` + warning[ambiguous] `model 'q3' (vbic): instances with 3 and with 4 terminals name it`; no instance in the file → `level=11` + warning `model 'q4' (vbic): xyce writes another model by its conditions, and no instance in this file names it`; (b) HSPICE `level=72 version=107` → Xyce `.model nfet nmos level=107` with version NOT written, info[oneway] `model 'nfet': version=107 is said by the xyce nmos level=107 spelling and is not written`; `version=109` → `level=111 version=109` + warning `version=109 is none of the values the spellings name`; no version → `level=111` + warning `it gives no version`; (c) reading is unchanged: any listed level is the family (Xyce `level=107` → HSPICE `level=72`) | `a model card's level by its version or by its instances' terminals (when)`; `model cards: level numbers and master names are mapped, with a warning`; py: `test_pdk_asap7` (env: ASAP7 checkout) | PINNED |
| 9d810cc3 | 2026-11-24 | #32 | engine, writer (grammar:ngspice,xyce) | (a) ngspice's other names of a resistor/capacitor card parameter cross into Xyce's one spelling with info[rename] (`model 'rnd': the parameter 'tc1r' is spelled 'tc1' in xyce`): `.model rnd r rsh=120 tc1r=1.422e-3 tc2r=6.569e-7 tnom=30 w=1u` → `.model rnd r rsh=120 tc1=1.422m tc2=0.6569u tnom=30 defw=1u`; `.model cm c cox=1m capsw=1n w=1u` → `.model cm c cj=1m cjsw=1n defw=1u`; (b) `modelparams <family> only` (Xyce resistor, capacitor): a name the card does not take is not written and is an error[loss] naming what it does take: `model 'rk': kf=1e-25 not written: the resistor card of xyce takes no such parameter; it takes narrow, defw, r, rsh, tc1, tc2, tce, tnom` (also `af`, capacitor `cap`); from a dialect with no table for the family (HSPICE) each name is checked as written (`cox=2m` → error); (c) a card's own `res=`/`r=` into Xyce → error `model 'rr': r not written: Xyce lists R among its resistor card's parameters ...` (`noparam resistor r`); (d) a target without `only` (HSPICE) gets the name AS WRITTEN (`tc1r=1.422m tc2r=0.6569u ... w=1u`), not the canonical spelling | `resistor and capacitor cards: ngspice's other names, and Xyce's cards take only theirs`; py: `test_pdk_sky130`, `test_pdk_gf180mcu` (env) | PINNED |
| b8c048f7 | 2026-11-24 | #33 | grammar:xyce,ngspice, writer | (a) Xyce's diode, bjt, vbic, bsim3, bsim4 and psp103 `modelparams` tables are `only`: a card name not listed is not written, error `model 'd1': tlev=1 not written: the diode card of xyce takes no such parameter` (also diode `cta`, bjt `trc`); (b) ngspice's other names cross in Xyce's spelling with info[rename]: `.model d1 d is=1e-14 mj=0.3 ik=1m tref=25` → `.model d1 d is=1e-14 m=0.3 ikf=1m tnom=25`, bjt `tref` → `tnom`, BSIM4 `level=54 version=4.5 vth0=0.4` → `level=14 version=4.5 vth0=0.4`; (c) a `noparam` line of a name decides over `only`: safe-operating-area names (VBIC `vbe_max`..., PSP103 `swsoa`, `vds_max`...) are not written with a WARNING (`vbe_max not written: Xyce's VBIC has no safe-operating-area check`), no error; (c2) BSIM3 `rd rs rdc rsc hdif ldif nqsmod` at 0 and BJT `iss=0`, `ns=1` are a warning (`at 0, ngspice's default, it changes nothing`) and an error at any other value; (d) `level` is never refused, and a card Xyce refuses by one value (a `level=3` diode) is another model: none of its other names is checked (exactly 1 error) | `card parameters into Xyce: every name its device declares, ngspice's other names, the rest a loss` ((a) for diode and bjt, (b), (c), (d)); `r1: ngspice's psp103va is PSP103; its N instances are transistors` (value-conditioned noparam, PSP103 only); py: `test_pdk_sky130`, `test_pdk_gf180mcu` (env; error counts) | PARTIAL: (c2) not asserted for any BSIM3 or BJT row; (a) not asserted for the vbic, bsim3, bsim4 tables |
| ba6a0908 | 2026-11-24 | #34 | expr, writer (grammar:xyce) | a parameter renamed for Xyce (`vt` → `vt__p`) is renamed everywhere it is named: (a) the swept parameter of `.dc`: ngspice `.dc vt 1m 5m 1m` → `.dc vt__p 1m 5m 1m`; (b) HSPICE `.tran 1n 10n sweep vt 1m 5m 1m` → `.step vt__p 1m 5m 1m`, and `.data d1 vt` columns → `.data d1 vt__p 1m 2m`; (c) the parameters an alter sets (`alter.param`, `alter.keys`); (d) `reserved shadowed temper hertz`: Spectre `parameters temper=4 hertz=3` with `r=1k*temper+hertz+temp` → Xyce `.param temper__p=4 hertz__p=3`, `R1 a 0 {1k*temper__p+hertz__p+temp}`, info `parameter 'temper' is written as 'temper__p'`; Spectre→Spectre unchanged; (e) into a dialect that takes the word for its variable (ngspice, HSPICE) → error[invalid] `the parameter 'temper' is a variable of ngspice under that name` (and `hertz`); `time` stays the error it was | `Xyce's reserved names: renamed in sweeps, data columns and alters; temper and hertz are shadowed` ((a),(b),(d),(e)); `r1: a parameter named like a variable Xyce keeps is renamed where it is defined and used` (`time` error) | PARTIAL: (c) an alter's parameter is not in any assertion, despite the test's name |
| 88e29b3f | 2026-11-24 | #35 | project (engine, grammar:ngspice) | `sprack project --section tt` into a target whose grammar says `libsections opened : reason` (ngspice): a section not followed is written with each include and library line inside it as a comment (`.lib ff` / `* [sprack] not in this copy: include "ff.mod"` / `* [sprack] not in this copy: lib "corners.lib" tt` / `.endl ff`), the followed section keeps `.include "tt.mod"`, and the log has `warning[caveat]: section 'ff' is not followed, and ngspice opens the includes of every section of a library`; into Xyce the copy keeps `.include "ff.mod"` and nothing is said | `project.zig: one section for a target that opens every section: the others' includes are comments` | PINNED |
| 2768ed66 | 2026-11-24 | #36 | writer, reader | (a) a block the target has not (HSPICE `.variation` → ngspice): its error counts what it held (`statement 'statistics' cannot be written for ngspice: ngspice has no statistics block ... The 3 statements it holds are not written either, and are in the output as comments`) and each statement is a `* [sprack] not written: ...` comment; (b) text a rule carries verbatim (HSPICE `.meas tran pn1 find phnoise at=1m`) is an ERROR (invalid) between two dialects: `measure.spec: carried as text: the probes, expressions and numbers in it were not translated; it is hspice text, written as it was`; (c) a multi-line raw block names its first line and says how many more lines it has (`... only as a comment: .control (and 3 more lines of it)`); (d) written back in its own dialect, lines no rule understood get one info[oneway] a file with their count (`1 statement no ngspice rule understood is written back as it was`), no error; (e) a word ending in a colon is no node and no model/subcircuit name: HSPICE reading ngspice's `.subckt div a b params: rt=1k` is untranslated (`no hspice rule understood this line; it is in the output only as a comment: ...`) and Xyce output never has `params: params:`; (f) a device whose model no file read declares, written for a target that tells a device from an instance only by its model (Spectre, VACASK): warning[ambiguous] `mosfet 'M1': its model 'nch' is declared in no file read; spectre tells a mosfet from a subcircuit instance only by its model`; (g) an instance given parameters whose subcircuit is not in the file, into a target with no conditional blocks: ONE warning[ambiguous] a file (`instance 'X1' gives parameters to subcircuit 'msel', which is not in this file; xyce has no conditional blocks`), none when the subcircuit is in the file | `the report says what crosses: a dropped block's statements, text in another syntax, a block's lines` ((a),(b),(e),(g)); `lines no rule understands are errors across dialects and untouched within one` ((d)); `a name an expression refers to keeps its spelling when its definition is elsewhere` ((f)) | PARTIAL: (c) lost its assertion when 43466f7a (#50) made `.control` a typed script; the message code is still in writer.zig and is reachable only through a `raw` block of a grammar file |
| e0f46280 | 2026-11-24 | #37 | project, cli, reader, json, expr | (a) an included file that is no regular file (`.include /dev/zero`) is not read: `sprack project` counts 1 error and logs `/dev/zero: error[invalid]: not a regular file; not read`; (b) the command's own input that is no regular file or pipe → stderr `<name>: error[invalid]: not a regular file or a pipe; not read`, exit 1; (c) an input or include larger than 1 GiB (`ir.max_input`) → `error[invalid]: larger than 1024 MiB, the most an input may hold; not read`, exit 1; (d) text blocks nested more than 100 deep (`ir.max_depth`; ngspice `.subckt`, `.if`, Spectre `subckt`): the reader opens no further block and reports error `blocks nested more than 100 deep`, the translation has errors, no stack overflow; (e) JSON `body` or list nested more than 100 deep → error `nested more than 100 deep: what is deeper is not read`; (f) (perf) the reader converts each block level's own statements once (`expr.convertFlat`): 60,000 statements 100 blocks deep read in about 29 MiB, not 437 MiB | `project.zig: an include that is no regular file is refused, not read until memory runs out` ((a), Linux only: skipped on other hosts); `limits: blocks and JSON nested deeper than 100 are refused, not a stack overflow` ((d),(e)) | PARTIAL: (b), (c) and (f) have no test (no cli case for an unreadable input, no size case, no memory bound for deep nesting) |
| 46a1e047 | 2026-11-24 | #38 | grammar:vacask, engine | four former loss errors into VACASK are now forms: (a) `tran.start`: ngspice `.tran 1n 100n 5n 0.5n uic` → `analysis tran1 tran step=1n stop=100n start=5n maxstep=0.5n icmode="uic"`; `.tran 101 20n 0 101` → `... step=101 stop=20n start=0`; (b) pattern form `out=[out ref]`: `.noise v(a,b) V1 ...` → `analysis noise1 noise out=["a","b"] in="V1"`, `.noise v(a) ...` → `out="a"` (ground reference is not written), `.tf v(a,b) V1` → `analysis tf1 dcxf out=["a","b"]`, and either form reads back; (c) HSPICE/ngspice `.options gshunt=1m` → VACASK `gshunt=1m`, no error; (d) `.tf`'s source is not written (`-src`): warning[caveat] `tf.src: dcxf reports tf() and zin() for every independent source ...`, no error | `VACASK: a node pair in noise and dcxf, gshunt, and a transient's start`; `nothing is dropped: a value with no place in the target is an error`; `verification: VACASK behavioural sources, dcxf, subckt parentheses, val0/val1`; `VACASK tran: SPICE's step cap is written as maxstep` | PINNED |
| 8dfad872 | 2026-11-24 | #40 | expr, engine (grammar:ngspice,hspice,ltspice,spectre,xyce) | grammar line `means [kind] f(x, y) = <canonical expression>`: where the target has no spelling for a function, the writer writes what the SOURCE means by it, with info[oneway], instead of an unsupported error: ngspice `.param p={pwr(-2,3)}` → VACASK `parameters p=pow(abs(-2),3)` (info `expression 'pwr(-2,3)': vacask has no pwr; written as what ngspice means by it, pow(abs(x),y)`), ngspice B source `V={pwr(v(a),3)}` → `v=sign(pow(abs(v(a)),3),v(a))`, HSPICE `pwr(x,2)` → `sign(pow(abs(x),2),x)`, Xyce `pwr(x,2)` → `pow(x,2)`; a target that has pwr (HSPICE) gets `pwr(-2,3)` as it was | `a function the target lacks is written as what the source means by it (means)` | PINNED |
| 09d399a0 | 2026-11-24 | #41 | cond, writer | a subcircuit written once for each branch of its conditional block (target without conditionals, Xyce) also resolves: (a) a constant expression as the deciding value (`rfmode={1}`, `rfmode='2-1'`) → the instance names the variant: `X2 n2 0 msel__1 params: rfmode={1}`, `X3 n3 0 msel__1 params: rfmode={2-1}`; (b) a value passed down from the enclosing subcircuit's parameter (`.subckt wrap a b mode=0` / `X1 a b msel rfmode=mode`) → the parent is itself written once for each variant (`.subckt wrap ...` with `X1 a b msel ...`, `.subckt wrap__1 ...` with `X1 a b msel__1 ...`), an instance of the parent picks by its own value (`X1 n1 0 wrap__1 params: mode=1`, `X5 n5 0 wrap`), no error; (c) a GLOBAL parameter as the deciding value (can be swept or altered) stays an error: `depends on parameter 'rfmode', which is not a number here` | `a subcircuit written once for each branch: constant values, and values passed down from a parent`; `v1: where a subcircuit is not written once for each branch, the error says why` | PINNED |
| 31b01a3e | 2026-11-24 | #39 | writer, stream (grammar:ngspice) | (a) an option the source grammar marks `inert` is an info[loss], not an error: ngspice `.options klu noacct` → Spectre nothing written, info `options: 'klu' is not written: ngspice's KLU only picks the sparse solver` and `options: 'noacct' is not written: ngspice's NOACCT only leaves out the accounting printout`, 0 errors; ngspice→ngspice keeps `.options klu noacct` with an empty report; (b) an option every move of which goes onto an analysis the netlist has not (`.options method=gear` with no `.tran`, into Spectre) is not written, info `options.method = gear is not written: spectre says it on tran.method, and this netlist has no tran for it to act on`, 0 errors; the default (streamed) path says the same | `options: one vocabulary, five ways of filing it` | PINNED |
| 2060a289 | 2026-11-24 | #42 | project, python, cli | a PDK manifest may hold `errata` (`{file, was, read, why, issue}`): (a) where a file read ends in `file`, a whole line equal to `was` is read as `read` (ngspice→Xyce: `res a b rm r = 1k tc1r = 1m` read as `Rres a b rm r = 1k tc1 = 1m` → `Rres a b 1k rm tc1=1m`), with ONE `warning[caveat]: read through an erratum of the PDK: '<was>': <why>; read as '<read>'` at the file's line though both passes read the file, 0 errors; (b) an erratum whose file is read but whose text is not there → `info[cosmetic]: the PDK's erratum for this file no longer applies: 'gone a b 1k' is not in it`; (c) errata JSON that is no list or manifest → `error.BadErrata`; (d) `sprack project --errata FILE` reads a list or a manifest's `errata` from a file; (e) `sprack.PDK` passes its manifest's `errata` to `_core.project` | `project.zig: errata: a line the PDK's own simulator refuses is read as the manifest says, once` ((a),(b),(c)); py: `test_pdk_sky130` ((e); env: sky130 checkout) | PARTIAL: (d) has no cli case; (e) is asserted only with a PDK checkout |
| 7b4f8023 | 2026-11-24 | #43 | grammar:ngspice, lexer | ngspice reads forms ngspice 45 loads instead of keeping them as text: (a) `.opt` and `.opts` are `.options` (→Xyce `.options device temp=127 tnom=77`); (b) `.width in=72` is an `inert` option: info `options: 'in=72' is not written: ngspice's .width in= only sets the columns of printed input`, no error; (c) `.parameters c=4` is `.param c=4`; (d) a blank before `%` or `\` joins the expression when an operand follows (`.param p1=10 %3`, `p2=10 \ 3` are one value; ngspice→ngspice `.param p2={10 \ 3}`), `\` is the canonical operator `idiv`: →Xyce error `operator 'idiv' has no spelling in xyce. Dialects that have it: ngspice` (and `operator 'mod' has no spelling in xyce`), while `5 %` alone stays HSPICE's percent; (e) `dc` with no value before a waveform on V and I sources (`V1 a 0 dc pulse(...)` → Xyce `V1 a 0 pulse(0 1 1n 1n 1n 5n 10n)`), no statement is opaque | `ngspice forms ngspice 45 takes: .opt, .opts, .width, .parameters, % and \\ after a blank, dc before a waveform`; `statistics: Spectre blocks, SPICE random functions, HSPICE variation` (`rsh=5 %` alone stays a percent) | PINNED |
| 4a9bcc85 | 2026-11-24 | #44 | writer, grammar:xyce | (a) ngspice `.print tran all` → Xyce `.print tran v(*)`; (b) `.plot tran v(out)` → Xyce `.print tran v(out)` with warning[caveat] `print.style: Xyce has no .plot; the signals are printed instead`, no error; (c) HSPICE `.hb tones=1k nharms=2` → Xyce `.hb 1k` followed by `.options hbint numfreq=2`; (d) `maxord` into Spectre (no maximum order): `.options method=gear maxord=1` → `tran1 tran step=1u stop=2u method=euler` with info[oneway] `options.maxord = 1 is backward Euler: spectre has no maximum order, so it is written as the method euler`; `maxord=4` → not written, info[loss] `options.maxord = 4 is not written: spectre has no maximum order`, 0 errors | `small forms a target has: print all and .plot into Xyce, HB harmonics, maxord into Spectre` | PINNED |
| 603dda27 | 2026-11-24 | #45 | reader, schema (grammar:hspice) | HSPICE analysis forms are read into typed analyses: (a) `.ac poi 3 10 159.1549431 1k` → Spectre `ac1 ac values=[10 159.1549431 1k]`, HSPICE back `.ac poi 3 ...`; an `.ac` before an analysis that has no slot for what it says (`.lstb`) stays its own statement; (b) `.lin gdcalc=1 noisecalc=1` after `.ac` is one `sp` (HSPICE back `.ac dec 10 1 1g` / `.lin gdcalc=1 noisecalc=1`; →Spectre error[loss] `sp: 'gdcalc=1' has no spelling in spectre`; Spectre sp parameters → HSPICE error `whose sp takes no such parameter`), positional `.hb 1meg 4` is `.hb tones=1meg nharms=4` (Spectre `hb1 hb fundfreqs=[1M] maxharms=[4]`), `.hblin poi 2 1meg 2meg` is a `psp` (Spectre `hbsp values=[1M 2M]`); (c) `.sn tres=1n period=10n trinit=5n` is folded to `.sn tone=100000000 nharms=10 trinit=5n` (Spectre `pss1 pss fund=100000000 harms=10 tstab=5n`, VACASK `analysis pss1 pss tper=1e-8 tstab=5n maxharm=10`); an `.snnoise` band `0 1` is the default and not written, `1, -1` is `pnoise.band` (→Spectre error[loss] `pnoise.band = 1 -1 has no spelling in spectre`); (d) `.op 1n 5n` is `op.times` (JSON `["1e-9","5e-9"]`; →Spectre error), `.dc monte=30` → `.op sweep monte=30`, `monte=list 3` / `monte=list(2 5)` are `montecarlo.trials` (Spectre `montecarlo numruns=30 variations=all {`; trials → error[loss]) | `#45: an HSPICE .ac POI list of frequencies is the ac's values`; `#45: HSPICE .lin parameters, .hblin POI and a positional .hb`; `#45: HSPICE .sn by period and time resolution, and an .snnoise band`; `#45: HSPICE .op times, .dc monte= and a Monte Carlo trial list` | PINNED |
| b31b70ba | 2026-11-24 | #46 | reader, lexer, schema (grammar:hspice) | (a) a bracketed parameter value keeps its blanks as ONE value (HSPICE and ngspice `r1 a b 1k foo=[1, -1]` → JSON `"foo":"[1, -1]"`, written back unchanged); (b) an HSPICE P port takes a third node (`P1 a b 0 port=1 z0=50` → `vsource.portref`; →Spectre `P1 (a b) port num=1 r=50` + error[loss] `vsource.portref = 0 has no spelling in spectre`); (c) a PAT source keeps `r=` and `rb=` among its bit groups (`pat(1 0 1n 0.2n 0.4n 2n b1011 r=1 rb=2 b0m1)` round-trips), `.pat a2=[b10 b01] r=1` is the kind `pattern` (→Spectre error[unsupported] `statement 'pattern' cannot be written for spectre`), and `.param f(x)='x*2'` is still a function; (d) `.data rows LAM FILE='l1.dat' rl=1` keeps join and files (JSON `"join":"lam","files":"FILE='l1.dat' rl=1"`; HSPICE back `.data rows lam FILE='l1.dat' rl=1`; →Xyce unsupported); (e) `.element_variation` is a `statgroup scope=element` with two-word `vary` lines, a glued `10%` is 10 percent (`"std":"10","rel":"yes"`; HSPICE back `r r=10 %`); →Spectre ONE error[unsupported] `statgroup scope=element cannot be written for spectre: Spectre varies netlist parameters ...` and the body as `// [sprack] not written: ...` comments; (f) a lone HSPICE Monte Carlo is the ending of its analysis (`.tran 1n 10n sweep monte=10`), not a line of its own | `#46: a bracketed parameter value with blanks in it is one value, in HSPICE and ngspice`; `#46: a balanced HSPICE port, its legs against a third node`; `#46: HSPICE PAT sources: repeats between bit groups, and a named .pat`; `#46: HSPICE .data read from files`; `#46: an HSPICE element variation is read, and Spectre says it has no form for it`; `the report says what crosses: a dropped block's statements, text in another syntax, a block's lines` | PINNED |
| 57c9ee53 | 2026-11-24 | #47 | schema, engine (grammar:hspice,xyce) | (a) `.fft` is a kind with HSPICE and Xyce rules: HSPICE `.fft v(a) start=0 stop=8u np=256 format=unorm window=hann alfa=3 freq=1meg fmin=1meg fmax=5meg` → Xyce `.fft v(a) start=0 stop=8u np=256 window=hann alfa=3 format=unorm freq=1meg fmin=1meg fmax=5meg`; `window=kaiser` → error[loss] `fft.window = kaiser has no spelling in xyce`; Xyce `window=hanning` → HSPICE `window=hann`; →ngspice error[unsupported] `statement 'fft' cannot be written for ngspice: ngspice's spectrum is the fft command of its control language`; an unknown key on read → error (invalid) `fft: 'zzfoo' is not a key hspice takes there`; (b) `sweep optimize=opt1 results=vout model=optmod` is the spread kind `optimize` (HSPICE round-trips the `.dc ... sweep optimize=...` line); →Xyce errors `analysis 'optimize' cannot be written for xyce: Xyce has no optimizer statement` and `model 'optmod' of type 'opt' cannot be written for xyce: HSPICE's optimizer is set by a .MODEL of type OPT`, and the swept `.dc` body is NOT written after being reported; (c) grammar directive `own`: `.connect`, the S element, `.dcsens`, `.acmatch`, `.net`, `.power`, `.check`, `.dout`, `.biaschk`, `.mosra`, `.appendmodel`, `.ptdnoise`, `.sample`, `.acphasenoise`, `.load`, `.vec` are each exactly 1 error[unsupported] and 0 untranslated into Spectre, and HSPICE→HSPICE writes the line back with no info[oneway] | `#47: .fft is a statement of HSPICE and Xyce, its windows and keys checked`; `#47: an HSPICE optimization is the ending of its analysis, and nowhere else`; `#47: HSPICE statements of its own are unsupported elsewhere, with the reason` (asserts the codes and counts, not the reason text) | PINNED |
| 0522e2bd | 2026-11-24 | #48 | grammar:ngspice (all), engine, schema | (a) new families mos6, mos9, bsim1, bsim2, b3soifd, b3soidd, b3soipd, mesa: every grammar has a models row or a `no model <family> : reason` line for each; ngspice `level=6` → Xyce `.model m6 nmos level=6 vto=0.5`; ngspice `level=4` (bsim1) → Xyce error `model 'b1' (bsim1 p) cannot be written for xyce`, → HSPICE `level=13`; `level=5` (bsim2) → HSPICE `level=39`; (b) read-only spelling `key>=n`: an ngspice MOS card of level 99 or more reads as mos1 with a warning (`.model nx nmos level=1040` → Xyce `.model nx nmos level=1`, warning `with level=1040: ngspice takes it as the mos1 model`); an unknown level below that (`level=11 foo=1`) stays an error and is copied as written | `#48: each family ngspice gained has a row or a reason in every target`; `an unknown level is an error across dialects, not a guess`; `parse check: ngspice MESA and HFET cards are not plain MESFETs` | PINNED |
| c838d073 | 2026-11-24 | #49 | grammar:vacask | ngspice S-parameter ports `V1 in 0 dc 0 ac 1 portnum 1 z0 50` into VACASK stay loss errors (no resistor or node is synthesized), now carrying the manual rebuild: `vsource.portnum = 1 has no spelling in vacask: a VACASK acsp port is a voltage source and a series resistor ...` and `vsource.z0 = 50 has no spelling in vacask: the port impedance is a series resistor ...` (4 loss entries for two ports); slot-level `no` reasons are checked for every grammar, not only Xyce's | `#49: an S-parameter port into VACASK says how to rebuild it`; `xyce: a tolerance is three options, and vntol, trtol and chgtol are none` (the loop over every grammar's slot-level `no` lines) | PINNED |
| 43466f7a | 2026-11-24 | #50 | reader / writer / grammar:ngspice | (a) ngspice `.control … .endc` reads as one `script` block: op, dc, ac, tran, noise, save, meas, pre_osdi inside are typed statements, any other command a `simctl` (cmd + args); ngspice→ngspice writes the block back line for line, 0 oneway entries; (b) ngspice→xyce (any dialect with no script): the script's analyses and measures become the deck's own lines in order (`.op`, `.dc v1 0 1 0.1`, `.measure dc vmax max v(a)`) with info[oneway] "script: hspice has no control script; the ngspice script's analyses and outputs are written as the netlist's own"; `run`/`quit`/`reset` → info "simctl: 'run' is not written"; any other command → error[unsupported] "simctl: 'let vth = v(a)*2' is a command of ngspice's control language"; (c) a script of commands only → error[unsupported] "statement 'script' cannot be written for xyce", each command a comment (`// [sprack] not written: run`); (d) `.csparam` is a kind only ngspice has → error "statement 'csparam' cannot be written for xyce"; (e) the ngspice text SPRack writes for an HSPICE `.alter` reads back with 0 opaque statements; (f) a VACASK control command into ngspice → error "simctl: 'print stats' is a command of vacask's control language" | "#50: an ngspice .control block is a script of statements"; "lines no rule understands are errors across dialects and untouched within one"; "the report says what crosses: a dropped block's statements, text in another syntax, a block's lines"; "b4: Spectre relay and port, VACASK control commands"; "caps: every kind has a rule, a place or a reason in every dialect"; py:test_code; py:test_to_python | PINNED |
| 08cce97f | 2026-11-24 | #51 | reader / writer / python | (a) an HSPICE line its grammar marks `own` (`.acmatch v(d)`, `s1 p1 p2 mname=smod`) reads as kind `native` (dialect, first word, words, key=value pairs; 0 opaque), hspice→hspice written back as it was; hspice→spectre error[unsupported] "'.acmatch v(d)' is a hspice statement and cannot be written for spectre: HSPICE's .ACMATCH…"; (b) HSPICE `.meas … thd/snr/sndr/enob/sfdr` and `goal=` are typed (no "spec" text in the JSON); hspice→xyce `.meas fft s1 snr v(o)` → `.measure fft s1 snr v(o)`; (c) VACASK `embed "runme.py" <<<FILE … >>>FILE` is kind `embed` and round-trips; (d) Python: to_python emits `c.native("hspice", ".acmatch", "v(d)")` and `c.embed("runme.py", "print(1)\n")`, never `.code(`; netlist("xyce") raises Unsupported "is a hspice statement and cannot be written for xyce" | "#51: a statement only its dialect has is its words; HSPICE measure forms; VACASK embed"; py:test_no_code_for_dialect_only_statements | PINNED |
| 6b384c4d | 2026-11-24 | #52 | writer / reader / grammar:xyce | (a) ngspice `N1 a b c rmod w=1u l=2u` on `.model rmod r3_cmc rsh=100` → xyce with no plugin: error[unsupported] on the card "model 'rmod' is of the Verilog-A module 'r3_cmc': xyce takes it only from a plugin of the module" and on the instance "device: xyce instantiates the Verilog-A module 'r3_cmc' only through a plugin of it"; (b) with Env.provided r3_cmc=r3_cmc.so → `Yr3_cmc N1 a b c rmod w=1u l=2u`, warning[caveat] "the Verilog-A module 'r3_cmc' is the plugin r3_cmc.so: run xyce with -plugin r3_cmc.so", 0 errors; (c) xyce read: `Y<module> name nodes model` drops the module when the card is in the netlist (JSON has no "module"), keeps `"module":"rlc"` when the card is elsewhere; (d) Python: manifest `xyce_plugins`; `PDK.run_options("xyce") == ["-plugin", file]` only for a file that exists, `[]` for ngspice. (The CLI flag is judged under de7005fe.) | "#52: a Verilog-A instance into Xyce is a Y line of its module, with a plugin"; py:test_xyce_plugins | PINNED |
| de7005fe | 2026-11-24 | #53 | engine / writer / cli | (a) a `models` line marked `provided` is written only when Env.provided names the family's file: hspice `.model nmos_lvt nmos level=72 version=107` → ngspice without it: error[unsupported] "… has no built-in bsimcmg; it runs one as a compiled module given to the translation: --provide bsimcmg=FILE"; with bsimcmg=/m/bsimcmg.osdi: the card (`.model nmos_lvt bsimcmg devtype=1`), the grammar's `needs` block once with the file in place of {file} (`.control\npre_osdi /m/bsimcmg.osdi\n.endc`), one warning "written for the module /m/bsimcmg.osdi given to the translation", 0 errors; (b) CLI: `--provide NAME=FILE` (alias `--xyce-plugin`, repeatable, on translate and project) fills Env.provided; without `=` → exit 2 "--provide takes NAME=FILE" | "#53: a family a dialect has only as a module given to the translation" (a) | PARTIAL: (b) unpinned — no cliTests case passes --provide or --xyce-plugin |
| 7691f313 | 2026-11-24 | #54 | cli / project | (a) `sprack audit` exits 1 and prints "<file>: the circuit read back from <to> is not the one read, and the report does not say why" when the reread differs and no entry of code untranslated/unsupported/loss/synthesized/invalid/ambiguous/oneway/rename exists; 0 otherwise; 2 for a wrong flag; (b) an include path that starts with a `$NAME` defined by -D resolves from the directory sprack runs in, so one -D reaches the same file from every including file ("3 files, 0 errors, 0 warnings"); (c) a variable not at the start of the path (or not defined) still resolves against the including file's directory; `${NAME}` and `.option search='$NAME/…'` follow (b) | cli: audit with swap.spgrammar exits 1 with the message; cli: `audit … --frm` exits 2; cli: `project -D INC=common` from two directories; project.zig:"a small project: includes followed, declarations shared, tree copied" | PARTIAL: (c) unpinned |
| c98724b5 | 2026-11-24 | #55 | project | (a) with Windows rules (the platform is an argument, so every host checks them): `C:/`, `C:\` and `//server/share` are roots, `\` separates, `..` stops at the drive (`C:\pdk\lib\..\models\x.lib` in C:/work → `C:/pdk/models/x.lib`; `inc\sub.sp` → `C:/work/inc/sub.sp`); elsewhere `\` is a character of a name (`/work/inc\sub.sp`); (b) `$name` takes an environment variable of another case on Windows only, one spelled exactly winning | project.zig:"paths as Windows has them, on any host: a drive or a share is a root, a backslash a separator"; project.zig:"a $NAME of another case is the environment's on Windows only" | PINNED (unit tests on internal functions rootLenOn/resolveOn/normalizeOn/varValue: they must be ported, not kept) |
| 692d2f56 | 2026-11-24 | #61 | ir / writer | (a) Env.absorb records model name → Verilog-A module for a card whose type no family table lists (`Env.modules`, from every file of a project); (b) a device whose model card is in another file of the project, written for Xyce, is #52's plugin error (or `Y<module>` line with a plugin), not a "no form fits" error. (The rest of the commit is the tools/pdk_devices.py harness.) | json.zig:"every field of Env is in its JSON form, and back (#71)" (a only: `env.modules.get("rpoly") == "r3_cmc"`) | PARTIAL: (b) unpinned — no test writes a device whose card is only in Env.modules |
| a2c0a524 | 2026-11-24 | #64 | reader | any dialect: a signal call whose line ends before its `)` (reader signalAt read past the token window) is no signal and no panic; plus four fuzz targets (netlist text to 64 KiB, JSON through every writer, grammar files, include trees) and SPRACK_FUZZ_SEED for the 20,000 damaged netlists | "fuzz: any bytes in, no crash"; "fuzz: any bytes as JSON, no crash"; "fuzz: any bytes as a grammar, no crash"; "fuzz: any tree of includes, no crash"; "20,000 randomly damaged netlists, no crash" | WEAK: only no-crash runs over fixed corpora and one seed; the input that panicked is not recorded as a corpus entry or a test |
| 2a2e10c5 | 2026-11-24 | #67 | project / writer / python | (a) (refactor) Python `translate` streams a statement at a time: same output as the CLI, no whole netlist held; (b) project with no --section: a section of an included library is followed only when a followed `.lib` line names it, the others get info[cosmetic] "section 'ff' not followed: no followed .lib line names it, so the files it includes are not translated" (with --section the reason is "it is not among the sections asked for"); (c) `project --lib --section tt` on a library given itself writes section tt alone; (d) Python PDK.devices leaves out the devices of a section the corner does not follow (GF180 `cap_mim_2f0ff`), the catalogue cached per corner; (e) a missing slot that both the source dialect's and the target's `invalid` lines cover is reported once, in the source grammar's words (LTspice→VACASK: 3 errors, not 6); (f) a library given as a top file with no --section is followed whole | project.zig:"a small project: includes followed, declarations shared, tree copied" (b); cli: `project --lib --section tt` (c); py:test_translate (a, output only); py:test_pdk_gf180mcu (d) | PARTIAL: (e) and (f) unpinned; (d) only by a test that needs SPRACK_TEST_PDKS; (a) the streamed memory bound is not asserted |
| ea0de603 | 2026-11-24 | #68 | grammar:xyce | ngspice `.noise v(a,b) V1 dec 1 1k 10k` → xyce `.noise v(a) V1 dec 1 1k 10k` + error[loss] "noise.ref = b has no spelling in xyce: Xyce 7.10 takes one output node…"; `.noise v(a) V1 …` → 0 loss entries | "#68: noise between two nodes into Xyce is a loss that says why; one node is not"; "xyce: a tolerance is three options, and vntol, trtol and chgtol are none" (every `no` slot line of every grammar) | PINNED |
| a4e6005a | 2026-11-24 | #70 | schema / grammar:spectre,hspice,xyce / reader | (a) a Monte Carlo run from hspice (`.tran 1n 10n sweep monte=20`) or xyce (`.sampling`) → spectre `mc1 montecarlo numruns=20 variations=all {`; (b) spectre→spectre keeps what was written (`mc1 montecarlo numruns=5 {`, nothing added); (c) spectre `variations=all` → hspice 0 loss; `variations=process` → error[loss] "montecarlo.variations = process has no spelling in hspice"; (d) a sweep-suffix statement (HSPICE `monte=`) is canonicalized on read, so implied values are filled | "#70: a Monte Carlo run into Spectre varies the mismatch block too"; "Monte Carlo: Spectre montecarlo, HSPICE monte=, Xyce .sampling"; "#45: HSPICE .op times, .dc monte= and a Monte Carlo trial list" | PINNED (the `process`/`mismatch` loss into xyce is not asserted, only into hspice; same `no` line mechanism) |
| 4885e7a8 | 2026-11-24 | #71 | json / project | (a) Env's JSON form carries `params`, `family_of` and `modules` (every Env field but `provided`); parse then write gives the same text; (b) a catalogue (project with no target) collects the parameter names every built-in dialect reserves, so a Python circuit on a PDK whose library has `.param vt=0.4` writes `.param x={2*vt__p}` for Xyce, the same lines as `sprack project` on the same files | json.zig:"every field of Env is in its JSON form, and back (#71)" (a); py:test_pdk_env_reserved_params (b) | PARTIAL: (b) only by a Python test that is skipped unless SPRACK_TEST_PDKS is set — it builds a toy PDK and needs no checkout, but the runner skips every `test_pdk_*` name |
| 52e5c576 | 2026-11-24 | #72 | expr / reader | (a) in expressions and probes, v/vdb/vm/vp/vr/vi name nodes, i/idb/im/ip/ir/ii and id/ig/is/ib/ie/ic/i1–i4 and `@m1[gm]` name devices, any other call names parameters: ngspice `{f(1)*id(m1)*vdb(out)*@m1[gm]}` with device M1 and node OUT → case-sensitive spectre (no insensitive=yes) `id(M1)*vdb(OUT)`; ngspice→ngspice `@M1[gm]`; (b) `.func f(X) {X*2}` folded shares one spelling: spectre `real f(real x) {\nreturn (x*2)\n}`; (c) xyce `.print dc ID(M1) vdb(out)` → `.print dc id(M1) vdb(OUT)` (one spelling of the letter); (d) reserved-name parameter renames skip the arguments of every probe, not only v() and i() | "#72: names in probes and function arguments keep their own spellings"; expr.zig:"argSpace: probes name nodes and devices, other calls parameters" | PARTIAL: (d) asserted for `v(vt)` only (in "r1: a parameter named like a variable Xyce keeps is renamed where it is defined and used"), not for vdb/id/@dev |
| 21aef6d1 | 2026-11-24 | #73 | schema / grammar:ltspice,ngspice,xyce,hspice | (a) sources have a `repeat` slot (SPICE `r=`): ngspice `V1 a 0 pwl(0 0 1m 1 2m 0) r=0` → ltspice `V1 a 0 pwl repeat forever (0 0 1m 1 2m 0) endrepeat`; ltspice `PWL REPEAT FOREVER (…) ENDREPEAT` → ngspice `pwl(0 0 1m 1 2m 0) r=0`; `r=1m` → error[loss] "isource.repeat = 1m has no spelling in ltspice: LTspice repeats a PWL from its first point only"; `td=1m` → error "isource: 'td=1m' has no spelling in ltspice, whose isource takes no such instance parameter" (3 loss entries in all); (b) LTspice `Rser=`, `Cpar=`, `load` are slots: ltspice→ltspice `V1 a 0 pwl(0 0 1m 1) rser=1 cpar=1p` / `I1 0 b dc 1m load` with an empty report; → ngspice errors "vsource.rser = 1 has no spelling in ngspice", "isource.load = yes has no spelling in ngspice"; (c) LTspice `I1 0 b 1m r=1k` → ngspice `I1 0 b dc 1m` + error "isource: 'r=1k' has no spelling in ngspice" (never ngspice's repeat) | "z2: a PWL's repeat into LTspice: from the first point REPEAT FOREVER, from another a loss (#73)" (successor of "z2: a PWL's repeat has no place on an LTspice source…", whose `r=0` loss this commit replaced) | PINNED |
| 6d7d5ed6 | 2026-11-24 | #75 | writer | an HSPICE or Spectre EXP source with no TD2 (its `omitted tau2 … given td2` line) into a target with an `invalid` line for tau2 (LTspice, VACASK): tau2 is written as the run's step (a hundredth of the stop for a Spectre `tran stop=` with no step) with warning[synthesized] "vsource.tau2 is not given: without vsource.td2 hspice means it plays no part within the run, and ltspice needs it said; wrote 2n", 0 errors: hspice `.tran 2n 50n` → ltspice `V2 b 0 exp(0 1 3n 23500p 50n 2n)`; spectre `tran stop=50n` + `td1=3n tau1=0.5n` → ltspice `V1 a 0 exp(0 1 3n 0.5n 50n 500p)` | "y1: an EXP source crossing into or out of HSPICE and Spectre says what was left out" | PINNED (for VACASK only "0 errors" is asserted, not the line) |
| c91655cf | 2026-11-24 | #76 | engine / grammar:hspice,xyce / writer | (a) grammar line `edge family key : text`: a card with that key crossing into or out of the dialect gets a warning: ngspice `.model rm r rsh=1k narrow=1u` → hspice `.model rm r rsh=1k dw=1u` + warning "model 'rm': narrow: where W - 2 DW is 0, HSPICE takes a floor resistance…"; hspice→hspice none; (b) a Xyce inductor card's `l` is a multiplier (`lscale`): xyce `.model lmod ind l=3 tc1=0.01` → ngspice `.model lmod l tc1=0.01` + error[loss] "Xyce's inductor card L multiplies the line's inductance…"; xyce→xyce `.model lmod l l=3 tc1=0.01`; (c) (build) CLI cases that exit before reading get no stdin; Rule.line removed (refactor) | "#76: HSPICE's floor resistance and Xyce's inductor multiplier are said" | PINNED (the `edge` caveat is asserted into HSPICE only, not out of it) |
| cb2b3910 | 2026-11-25 | - | writer | an options statement none of whose values cross is not written: ngspice `.options klu noacct` → xyce output has no `.options` line (was a bare `.options timeint`), 0 errors, the "not written" info entries stay | "options: one vocabulary, five ways of filing it" | PINNED |
| f9d7b423 | 2026-11-25 | - | grammar:vacask | ngspice `.model qq npn level=1 bf=80` → vacask `model qq sp_bjt (type=1 bf=80)` + warning "model 'qq': level not written: sp_bjt is the level 1 (Gummel-Poon) BJT…", 0 errors | "VACASK model cards: a refused version is a warning, a refused JFET level 2 an error" | PINNED |
| 2c5c2b3f | 2026-11-25 | - | grammar:xyce | (a) more than one of dc/ac/tran/noise/sp/hb into xyce: every one is still written and each gets error[invalid] "dc: one of 2 analyses in this netlist (dc, tran); Xyce 7.10 runs one analysis a netlist…" ("noise: one of 3 analyses in this netlist (dc, ac, noise)"); (b) exactly two analyses of which one is `.op` → warning[caveat] "op beside tran; Xyce 7.10 runs one analysis a netlist…", no error | "VACASK control block and sweep"; "sweeps: a sweep whose stop is its start" (a); the `beside op` branch itself in "z2: more analyses than LTspice loads in one deck are an error on each that names them" | PARTIAL: (b) asserted for LTspice's line only, not for Xyce's |
| f2d3eb02 | 2026-11-26 | #31 | writer / json / python | (a) a netlist whose JSON says `"defaults":"<dialect>"` and sets no temp/tnom, written for a target whose defaults differ → error[ambiguous] "options: the circuit sets no temp or tnom; its PDK's simulator (hspice) assumes temp=25, tnom=25 and xyce assumes temp=27, tnom=27", and no temp line is written; no entry for the PDK's own dialect, when temp and tnom are set, or with no `defaults`; (b) Python: a Circuit on a PDK with no dialect of its own sends `defaults` = the PDK's dialect | "a circuit on a PDK that sets no temperature is an error where the PDK's simulator assumes another" (a); py:test_pdk_ihp, py:test_pdk_asap7, py:test_pdk_freepdk45 (b) | PARTIAL: (b) only by tests that need SPRACK_TEST_PDKS |
| 937a8bab | 2026-11-26 | #43 | schema / grammar:ngspice,vacask / engine | (a) ngspice `.tf i(Vmeasure) Vin` reads as tf with slot `iout` and round-trips; → vacask `analysis tf1 dcxf out="Vmeasure:flow(br)"` (0 errors; reads back iout=Vmeasure; a node output stays `out="a"`); → hspice error "tf.iout: this grammar has no HSPICE form for a current as the output of .TF" (ltspice and spectre have the same `no tf iout` line); (b) ngspice `U1 in out 0 umod L=100u N=10` + `.model umod URC(K=1.5 FMAX=1G RPERL=1000 CPERL=1p)` is a lossyline of family urc: ngspice→ngspice `U1 in out 0 umod l=100u n=10`, `.model umod urc k=1.5 fmax=1g rperl=1000 cperl=1p`, clean; → xyce error "…Xyce's U is a digital device" | "a current as the output of .tf: ngspice i(), VACASK's branch unknown, an error where it is not measured"; "the URC line: ngspice's U is a lossyline of family urc; Xyce's U is digital" | PINNED |
| a5aaafea | 2026-11-26 | #52 | writer / python | (a) a Xyce plugin's Y line has no m: ngspice `N1 … m=1` → `Ymosvar N1 g b w cv l=1u`; `m=2` or `m={k}` → the same line without m + error[loss] "device: 'm=2' not written: a xyce plugin has no device multiplier ($mfactor), so the module 'mosvar' is simulated as one device"; (b) a plugin's card is written without `level`: `.model cv mosvar level=1000 type=-1` → `.model cv mosvar type=-1` + warning[loss] "model 'cv': level not written: xyce takes a plugin's card only at the plugin's own level"; (c) Python PDK.translate("xyce") passes the manifest's plugins whose file exists to the core, and a plugin built since is another translation (`Yr3_cmc N1 a b c rmod w=1u` in the translated library); (d) the once-only key of the plugin caveat lives in the writer's permanent arena (it was freed between streamed groups) | "#52: a Xyce plugin's Y line has no m, and its card no level" (a, b); py:test_xyce_plugins (c) | PARTIAL: (d) unpinned — no test counts the caveat over several streamed groups |
| 9cec7da6 | 2026-11-26 | #53 | grammar:ngspice,vacask / reader / writer | (a) hspice `.model … nmos/pmos level=72 version=107` with bsimcmg provided → ngspice `.model pmos_rvt bsimcmg devtype=0`, `nm1 d g 0 0 pmos_rvt l=20n nfin=3`, `.control\npre_osdi FILE\n.endc`; → vacask `load "FILE"`, `model nmos_rvt bsimcmg (devtype=1)`, `m1 (d g 0 0) nmos_rvt l=20n nfin=3`; with nothing given error "vacask has no built-in bsimcmg; it runs one as a compiled module given to the translation: --provide bsimcmg=FILE"; (b) `version` is never written: 107 → warning, any other → error "version not written: the module given has no version parameter"; (c) reader: a `needs` block holding {file} is not boilerplate to drop, so ngspice `.control`/`.endc` lines are read as any block's; (d) `needs` lines are never wrapped: a long path stays whole on `pre_osdi <file>` (write and stream); (e) the provided-family caveat is said once a file and the second file of a project does not crash (key in the permanent arena); (f) Python: manifest `provide` per target through `$BSIMCMG_OSDI`, given to the library translation and to the netlist; (g) JSON env `"provided"` is read (never written) | "#27: a BSIM-CMG card into ngspice is an N device of the module given"; "#27: a BSIM-CMG card into VACASK loads the module given"; "#27: a BSIM-CMG card's version is dropped for the module given, and only 107 was measured"; "#27: a needs line keeps a long file given whole"; "#53: a family a dialect has only as a module given to the translation"; "#50: an ngspice .control block is a script of statements" (c); "#53: ASAP7 into ngspice and VACASK: 24 errors, or with the module given 0 and one caveat a file" (e; SkipZigTest without SPRACK_TEST_PDKS); py:test_pdk_bsimcmg_asap7 (f, g; needs SPRACK_TEST_PDKS, SPRACK_BSIMCMG_OSDI and ngspice) | PARTIAL: (e), (f), (g) only by tests that need a PDK checkout |
| 10d44925 | 2026-11-26 | #56 | grammar:hspice | an HSPICE source's bare `ac` is a magnitude of 1, not the DC value: `v1 a 0 ac` → ngspice `v1 a 0 ac 1`; `v2 b 0 dc 0 ac` → `v2 b 0 dc 0 ac 1`; `i1 c 0 ac sin(0 1 1k)` → `i1 c 0 ac 1 sin(0 1 1k)`; `v3 d 0 1 ac 2 90` → `v3 d 0 dc 1 ac 2 90`; clean report (it was written `dc {ac}`) | "#56: a bare ac in an HSPICE source is a magnitude of 1, not the DC value" | PINNED |
| 5bd9ba72 | 2026-11-26 | #57 | grammar:spectre | (a) ngspice `Cg b 0 q='1p*v(b)'` → spectre: no `q=` in the output, error[loss] "capacitor: 'q=1e-12*v(b)' has no spelling in spectre"; (b) ngspice `.options trtol=1 chgtol=1e-14` → spectre errors "options.trtol = 1 has no spelling in spectre: Spectre's truncation-error factor is lteratio…" and "options.chgtol = 1e-14 has no spelling in spectre: Spectre has no charge tolerance…" | "Spectre capacitor: q= is an error, not written"; "Spectre options: trtol and chgtol are errors that give the reason" | PINNED |
| 59288756 | 2026-11-26 | #47 | lexer / grammar:hspice | (a) in a SPICE dialect a comma at depth 0 ends a bare value after `=`: hspice `.dc v1 0 5 1 sweep optimize=opt2 results=va,vb model=optmod` reads as one `optimize` (0 opaque) and is written back the same; inside brackets or parentheses, and in a bare-expression dialect (VACASK `nodeset={"q",5}`), the comma stays in the value; (b) hspice `result=vout` (singular) is read and written back `results=vout` | "#47: a comma after = parts two values: an optimization's results=va,vb is two results"; "#47: an HSPICE optimization reads result= in the singular, written back as results=" | PINNED |
| 652fd5e4 | 2026-11-26 | #64 | json | any dialect: a byte ≥ 0x80 that is not valid UTF-8 (a Latin-1 µ, a lone continuation byte, an overlong form, a surrogate, a sequence cut short) is written to JSON as `\u00XX`; valid UTF-8 is kept; parseNetlist reads the JSON back with an empty report and the same number of statements | "a byte that is not UTF-8 is written to JSON as its Latin-1 character" | PINNED |
| c6a9e5fa | 2026-11-26 | #25 | python | sky130A manifest: the two errata for lines FOSSi's sky130_fd_pr (29b5515) corrected are removed; the special_pfet_pass erratum names its file by basename so it applies to both layouts; sky130 tt → xyce is 312 report entries, all `loss` (13 dw, 18 level-3 diodes, 10 `r`, 10 resistor-card names, 261 BJT-card names); `.include "corners/tt.spice"` in the translated library | py:test_pdk_sky130 | PINNED-ENV: needs SPRACK_TEST_PDKS holding sky130_fd_pr at 29b5515 |
| 29f8d9a1 | 2026-11-26 | #33 | grammar:vacask | into vacask every name on a diode, BJT, VBIC, BSIM3, BSIM4 and PSP103 card is checked against the module's OSDI parameter list: ngspice `.model d1 d is=1e-14 mj=0.3 ik=1m tref=25 tlev=1 foo=1` → `model d1 sp_diode (is=1e-14 m=0.3 ikf=1m tnom=25 tlev=1)`, info "model 'd1': the parameter 'ik' is spelled 'ikf' in vacask", error[loss] "model 'd1': foo=1 not written: the diode card of vacask takes no such parameter"; `.model q1 npn tref=25 trc=1m tnf1=1e-4` → `model q1 sp_bjt (type=1 tnom=25 trc1=1m tnf1=1e-4)`; BSIM4 `rgeomod=0` a warning and `rgeomod=1` an error; PSP `thecso=2`, `swsoa=1`, VBIC `vbe_max` warnings, `thecso=1` an error | "card parameters into VACASK: every name its module's OSDI descriptor lists, the rest a loss" | PINNED (samples of the tables; the 301 grammar lines are data, and no BSIM3 name is asserted) |
| 35d5a78f | 2026-11-26 | #73 | grammar:ltspice | (a) into ltspice an instance parameter LTspice 26.0.2 refuses is a loss: ngspice `R1 a b 1k tc=1m dtemp=2 m=2` → `R1 a b 1k tc=1m m=2` + error[loss] "resistor: 'dtemp=2' has no spelling in ltspice"; likewise capacitor `tc1=1m`, diode `l=1u`, bjt `areab=2`, jfet `l=1u` (5 loss entries; `ic=0`, `off`, `m=2`, inductor `tc1` are kept); (b) LTspice's own (resistor `noiseless`, capacitor `Rser`/`Lser`, inductor `Rpar`, diode `n`) are kept ltspice→ltspice with a clean report (`R1 a b 1k noiseless`, `C1 b 0 1p rser=1 lser=1n`) and are a loss into ngspice ("resistor: 'noiseless' has no spelling in ngspice", "capacitor: 'rser=1' …", "diode: 'n=2' …"); a resistor's bare `noiseless` is read | "#73: an instance parameter LTspice 26.0.2 does not take is a loss into it, and its own are a loss out" | PINNED |

## UNPINNED / WEAK — fixtures needed

Index of the 55 commits that are not fully pinned in a default test run (UNPINNED 1, WEAK 5, PARTIAL 45, PINNED-ENV 4). The letters refer to the lettered invariants of the commit's ledger row. A fixture block for each follows the index (a PINNED-ENV row has a block only where an env-free check is possible).

| hash | issue | subject | status and what is not pinned |
|---|---|---|---|
| a57bbdce | - | vacask: nharm=[harms], so multi-tone .hb reads back; new audit baseline | WEAK — none asserts it: "fuzz: a statement of thousands of repeated words does not overflow the stack" writes `.hb tones=1k 2k nharms=3 3` to every dialect but checks nothing of the text; no test contains a VACASK `hb` line |
| cc1a6e08 | - | Python: every dialect argument may be a path to a .spgrammar file | PARTIAL: (c) not pinned for PDK.translate |
| 0d842dba | - | Libraries translated on the fly: a lib/include written in another dialect points at a c... | PARTIAL: (g) only PINNED-ENV |
| e4d1269f | - | Grammar and README wording: no vendor or product names; reasons in our own words | WEAK — "Schemify decks: paths, scopes, control blocks and XSPICE survive the JSON trip" asserts only the prefix `XSPICE code models are ngspice's`, and only for target xyce |
| 872a7de6 | - | Stmt.dialect is a u8 index into a process-wide dialect table | PARTIAL: (b) not pinned |
| 63f08969 | - | Xyce: log is base 10, ^ is xor, VBIC 11/12, vswitch/iswitch, BSIM-CMG 111, .LIN, no pss... | PARTIAL: (f), (h), (k) not pinned |
| 68025e67 | - | Engine: per-family needs, convert, invalid checks, {pairs} lists, ic/nodeset on analyses | PARTIAL: (h) not pinned (cli caps asserts only the resistor row and the `none:` legend) |
| 062bcac0 | - | VACASK: apply docs/verification.md and close caps | PARTIAL: (d), (f), (j), (k) not pinned |
| 04b5199f | - | spectre, hspice: close caps, fixes from loading translations in the real tools | PARTIAL: (o) not pinned for hspice (the same caveat is asserted for ltspice and xyce only) |
| 33dfc935 | - | docs/verification.md: the 18 HSPICE and Spectre rows, settled by running the tools | UNPINNED — none (no test has atan2/hypot/fmod into hspice) |
| b855300c | - | ngspice .noise points-per-summary as noise.interval; HSPICE noise ref implied 0; audit | PARTIAL: (b) reading from ngspice and (c) not pinned (c only through the every-pair round trip) |
| b6567bf5 | - | ngspice, Xyce: write what the simulators load | PARTIAL: (e) WEAK (only `hasErrors`) |
| 60c1eb72 | - | IHP manifest: load every OSDI model IHP's .spiceinit loads | PINNED-ENV (needs SPRACK_TEST_PDKS_INSTALLED with an installed IHP tree + ngspice on PATH) |
| ce8ed481 | 7.2, 7.6 | PDK tests: installed sky130A and IHP trees, and a GF180MCU manifest | PINNED-ENV ((a) pinned without env; (b) needs SPRACK_TEST_PDKS + ngspice; (c) needs SPRACK_TEST_PDKS_INSTALLED + ngspice) |
| 2ddd4b02 | b3 | Analyses (b3): pac, pnoise, pxf, psp, xf, dcmatch, trannoise, phasenoise, envelope, qpss | PARTIAL: (e) asserted only as a kind count (written envlp/qpss text not asserted); (f) HSPICE .phasenoise, Spectre psp (shooting), VACASK pnoise have no assertion |
| 50285205 | - | Engine: counted lists, matrices, nested and negated probes, tagged numbers | PARTIAL: not pinned: (a) the count-mismatch refusal; (f) the refusal of a signal expression in a dialect without an expr form (Spectre/VACASK) |
| a7cdc5c8 | - | Engine: verbatim text crossing dialects is ambiguous; three reader fixes | PARTIAL: (a) SUPERSEDED(2768ed66) and pinned there; (b), (c: the plain-source side), (d: reading par('...') back) not pinned |
| c9ba088a | b4 (4.3-4.5, 4.7) | Devices, source forms, output forms, VACASK control commands (PLAN 4.3-4.5, 4.7) | PARTIAL: (i) trrandom, abort/elaborate, written VCCAP and pvcvs have no assertion; (a)-(h) pinned |
| b1c81f8d | b4 | HSPICE k= coupling, Spectre pacmag and fundname, PLAN b4 ticked; audit | PARTIAL: (b) not pinned (no test names pacmag or fundname) |
| e700e490 | - | Sweeps: a step with no analysis to repeat is an error; VACASK point-count caveats; audit | PARTIAL: (b) the three VACASK point-count caveats are not asserted anywhere |
| e2d0d41d | 7.3 | 7.3: per-dialect instance parameter tables (params kind ... end) | PARTIAL: (f) HSPICE as the target is not asserted; (e) PINNED-ENV (needs SPRACK_TEST_PDKS); the info[rename] entry itself is not asserted (only the renamed output) |
| ae35fa60 | gap 4, 5 | HSPICE: a single trailing backslash continues; a string open across lines | PARTIAL: (a) no test continues an HSPICE line with a single backslash (both tests use the doubled form) |
| e48768eb | gap 8, 9 | Spectre: report a parameter defined twice and a model/subcircuit name clash | WEAK: (a) the plain HSPICE→Spectre case is asserted by a bare substring `vt0` with no severity, code or text; the stricter assertion exists only on the dev/gauss path |
| 3cdf3fdc | 8.4, gap 10 | project: corner-aware (8.4); Verilog-A sources copied, section spellings kept (gap 10) | PARTIAL: (d) the test passes if EITHER the .va file was copied OR the include line no longer says `"./cap.va"`: neither the copy nor the rewritten path is asserted on its own; (b) the per-corner cache directory name is not asserted |
| 3f81c5a6 | 8.2 | 8.2: expression semantics: a choice restructured, measured differences as caveats | PARTIAL: the info[oneway] of (a) and the rows of (c) are not asserted |
| 9ba3ead4 | - | HSPICE dev/gauss= as agauss(); Xyce's reserved parameter names reported | PARTIAL: `lot/gauss=` and `dev/unif=` / `lot/unif=` are not asserted (only dev/gauss); (b) superseded and pinned in its new form |
| 137d6f02 | - | VACASK instance parameter tables: m is $mfactor, ic and resistor ac a loss | PARTIAL (d unpinned) |
| 168c6032 | c2 | Alters and HSPICE SWEEP tails | PARTIAL (g,h unpinned; the "every `no` line" test skips kind alter) |
| 70be96f3 | - | Report circuits a target cannot solve: no DC path, V/L loops | PARTIAL (d: asserted only for VACASK (all), Spectre island + L loop, Xyce V loop + L loop, ngspice L loop, HSPICE cutset; HSPICE island and its three loops, Spectre V and V+L loops, Xyce island and V+L loop, ngspice island, V loop and V+L loop are unpinned) |
| 22ed612f | - | Topology check: no alarm where the netlist does not say enough | PARTIAL (b: the XSPICE A-device case unpinned) |
| e30a214b | c4 | HSPICE reader gaps reported by ESPice (c4) | PARTIAL (l,m weak: asserted only as `count(.error) > 0`, no message) |
| d7bf89c1 | - | Translate as a stream: survey the netlist, then read and write one statement at a time | PARTIAL: (c) no test asserts a fallback reason or either env variable |
| 82ecaa9e | - | Lower random functions as a stream; read the input at its size | PARTIAL: (b) no assertion (py test_memory measures the Python path, not the command) |
| c6e51fc1 | r1 | PSP103 between dialects: what Xyce's lacks is said by name; HSPICE takes factuo, and dt... | PARTIAL: (c) only thecso (off neutral) and ctgo=0 are asserted; the other five names and the neutral values 1 and 2 are read by no test |
| 009bbd04 | - | Python: what is kept in the cache follows the build of the core | PARTIAL: (b) the library key is not asserted |
| 9ca39691 | - | A project's paths on Windows: a drive or a share is a root and a backslash separates; i... | PARTIAL: (b) `commonDir`/`dirname` with a drive root and the reported paths are checked on no host but Windows (Python tests in the Windows CI job) |
| ed0f1db0 | - | Python on Windows: a writer's process is asked for, not signalled; a netlist is written... | PINNED-ENV: needs a Windows host to tell (on POSIX the platform defaults already pass, and (b) runs only there) |
| fa7180a9 | e2 | e2: the kind `verilog` and the slot `points` of `pss` go: no remaining dialect reads or... | WEAK — none asserts the absence; indirect only: `caps: every kind has a rule, a place or a reason in every dialect` would fail if the kind came back without its `no` lines |
| b8c048f7 | #33 | card parameters into Xyce: every name its device declares, the rest a loss (#33) | PARTIAL: (c2) not asserted for any BSIM3 or BJT row; (a) not asserted for the vbic, bsim3, bsim4 tables |
| ba6a0908 | #34 | Xyce's reserved names in sweeps, data columns and alters; temper and hertz shadowed (#34) | PARTIAL: (c) an alter's parameter is not in any assertion, despite the test's name |
| 2768ed66 | #36 | the report says what crosses: dropped blocks, text in another syntax, lines written bac... | PARTIAL: (c) lost its assertion when 43466f7a (#50) made `.control` a typed script; the message code is still in writer.zig and is reachable only through a `raw` block of a grammar file |
| e0f46280 | #37 | limits: inputs that are no regular file or too large, and blocks nested over 100 deep (... | PARTIAL: (b), (c) and (f) have no test (no cli case for an unreadable input, no size case, no memory bound for deep nesting) |
| 2060a289 | #42 | pdk: errata in a manifest for lines the PDK's own simulator refuses (#42) | PARTIAL: (d) has no cli case; (e) is asserted only with a PDK checkout |
| de7005fe | #53 | models: a family a dialect has only as a module given to the translation (#53) | PARTIAL: (b) unpinned — no cliTests case passes --provide or --xyce-plugin |
| 7691f313 | #54 | cli: audit's status says a silent difference; -D paths start where sprack runs (#54) | PARTIAL: (c) unpinned |
| 692d2f56 | #61 | tests: a harness that compares each PDK device across simulators (#61) | PARTIAL: (b) unpinned — no test writes a device whose card is only in Env.modules |
| a2c0a524 | #64 | fuzz: JSON, grammar and include-tree targets, 64 KiB inputs, a nightly run (#64) | WEAK: only no-crash runs over fixed corpora and one seed; the input that panicked is not recorded as a corpus entry or a test |
| 2a2e10c5 | #67 | leftovers: streamed Python translate, one test run directory, a deck's sections alone, ... | PARTIAL: (e) and (f) unpinned; (d) only by a test that needs SPRACK_TEST_PDKS; (a) the streamed memory bound is not asserted |
| 4885e7a8 | #71 | env: the JSON form holds every field, so a circuit on a PDK renames as its library (#71) | PARTIAL: (b) only by a Python test that is skipped unless SPRACK_TEST_PDKS is set — it builds a toy PDK and needs no checkout, but the runner skips every `test_pdk_*` name |
| 52e5c576 | #72 | reader: names in probes and function arguments keep their own spellings (#72) | PARTIAL: (d) asserted for `v(vt)` only (in "r1: a parameter named like a variable Xyce keeps is renamed where it is defined and used"), not for vdb/id/@dev |
| 2c5c2b3f | - | xyce: one analysis a netlist; the others are errors that say so | PARTIAL: (b) asserted for LTspice's line only, not for Xyce's |
| f2d3eb02 | #31 | python: a circuit on a PDK that sets no temperature is an error where the target assume... | PARTIAL: (b) only by tests that need SPRACK_TEST_PDKS |
| a5aaafea | #52 | xyce: IHP's Verilog-A plugins measured; m and level on a plugin device (#52) | PARTIAL: (d) unpinned — no test counts the caveat over several streamed groups |
| 9cec7da6 | #53 | models: BSIM-CMG 107 for ngspice and VACASK as a module the translation is given (#53) | PARTIAL: (e), (f), (g) only by tests that need a PDK checkout |
| c6a9e5fa | #25 | sky130: the sky130_fd_pr checkout is FOSSi Foundation's at 29b5515 | PINNED-ENV: needs SPRACK_TEST_PDKS holding sky130_fd_pr at 29b5515 |

Superseded (do not restore the old behaviour): 46ebf5c8 SUPERSEDED(c82c47e2); 1e288c33 SUPERSEDED(d875ee84); ec87e566 SUPERSEDED(9b8f8e6b). Parts of other commits that were superseded (the ESPice dialect, removed by d875ee84/fa7180a9; EXP defaults redone by 284f713a/51c48de6/6d7d5ed6; capacitor ic= into VACASK redone by 5feb4d93; reserved names renamed, not refused, since c82c47e2) are marked inside the invariant cell of their rows.

### Fixture proposals

Nothing was run to produce these (no build was allowed): every expected text was read from a commit message, a commit diff, or the code, grammars and tests at HEAD, and each block says what is INFERRED. Before freezing a fixture, generate its expected output once with the HEAD binary and compare it with the text given here.

### a57bbdce — vacask: nharm=[harms], multi-tone .hb reads back [WEAK]
- from: hspice   to: vacask (then vacask → hspice)
- input:
  ```
  t
  .hb tones=1k 2k nharms=3 3
  .end
  ```
- expect: output contains `analysis hb1 hb freq=[1k, 2k] nharm=[3, 3]`; reading that output as vacask gives one `hb` statement (no `opaque`) with `freqs` and `harms` lists of length 2; written back for hspice: `.hb tones=1k 2k nharms=3 3`.
- basis: commit diff (grammars/vacask.spgrammar: `nharm=harms` → `nharm=[harms]`), grammar at HEAD (grammars/vacask.spgrammar:197). INFERRED: the name `hb1`, the `, ` separator (taken from `wave=[0, 0, 1u, 1]` in "sources: every waveform…") and that no other parameter is written.

### cc1a6e08 — Python: a PDK translated into a grammar-file target is cached under the file's base name and content hash [PARTIAL: (c)]
- not a netlist fixture. Minimal check: with a tiny PDK (the `_tiny` helper of python/test_sprack.py) call `pdk.translate(mine)` where `mine` is a copy of grammars/ngspice.spgrammar renamed `dialect mine`; assert the returned directory's name starts with `mine-<sha1(file bytes)[:8]>`; append a comment line to the grammar file and translate again: a different directory.
- basis: commit diff (python/sprack/__init__.py `_dialect_tag`), HEAD python/sprack/__init__.py:150, 1366, 1492. INFERRED: the exact directory layout at HEAD (`f"{_dialect_tag(d)}-{self.corner}"` when sections are used).

### 0d842dba — a library's losses join the report with their file [PARTIAL: (g) only PINNED-ENV]
- from: ngspice (code block)   to: xyce, through `Circuit.netlist("xyce", strict=False)`
- input: a temp `top.lib` holding
  ```
  * lib
  .lib tt
  .model dx d level=3 is=1e-14
  .endl tt
  ```
  and a circuit `c.code('.lib "<dir>/top.lib" tt\nD1 a 0 dx\n.op\n')`
- expect: the report has at least one error, every error has `e.file` set to a path under the library (source or copy), and the netlist still names the cached copy.
- basis: commit message ("what the library cannot say joins the report with file:line"); test_pdk_sky130_library_on_the_fly (`all(e.file for e in first.report.errors)`). INFERRED: that a level-3 diode card is a loss into Xyce at HEAD (9ac764e9 says so) — any card Xyce cannot take will do.

### e4d1269f — the XSPICE reason for hspice and spectre [WEAK]
- from: ngspice   to: hspice (same for spectre)
- input:
  ```
  t
  AU2 [ A ] [ y ] dinv
  .model dinv d_cosim simulation="dinv.vvp"
  .end
  ```
- expect: report has `error[unsupported]` on line 2 whose text contains `cannot be written for hspice: XSPICE code models are ngspice's; this grammar has no form for them`.
- basis: commit diff (grammars/hspice.spgrammar, grammars/spectre.spgrammar `no xspice` lines), grammar at HEAD (hspice.spgrammar:292, spectre.spgrammar:244). INFERRED: the words before `cannot be written` (writer.zig:1758 prints `<class> '<kind>' cannot be written for <dialect>: <reason>. Dialects that define it: ...`) and what happens to the `.model dinv` line.

### 872a7de6 — more than 255 dialect names [PARTIAL: (b)]
- not a netlist fixture. Minimal check: intern names until the table is full (`sprack.internDialect("d<N>")` returns null / the limit), then (1) `sprack.resolve(a, io, "grammars/ngspice.spgrammar", &diag)` under a new dialect name fails with `error.TooManyDialects` and a message in `diag.msg`; (2) `json.parseNetlist` of `{"title":"t","dialect":"sprack","stmts":[{"kind":"op","dialect":"onemore"}]}` is a parse error, not a crash or a wrapped index.
- basis: commit message; HEAD src/root.zig:113,130. INFERRED: the exact error a JSON name gets and how `internDialect` reports a full table (the table is process-wide, so this test must run in its own process or last).

### 63f08969 — Xyce: level 57 is BSIMSOI, no pss, fmod and db [PARTIAL: (f), (h), (k)]
- (f) from: xyce   to: ngspice
  - input: `t\n.model ms nmos level=57\n.end\n`
  - expect: the card reads with family `bsimsoi` (not an `is not in the xyce models table` error) and is written `.model ms nmos level=10`.
  - basis: commit diff (xyce.spgrammar `bsimsoi n = nmos level=70 | nmos level=10 | nmos level=57`), grammar at HEAD (xyce.spgrammar:359, ngspice.spgrammar:347). INFERRED: `level=10` as ngspice's first spelling, and whether a caveat about differing implementations accompanies it.
- (h) from: spectre   to: xyce
  - input: `// t\nsimulator lang=spectre\nV1 (in 0) vsource type=sine ampl=1 freq=1M\npss1 pss fund=1M harms=10 tstab=1u\n`
  - expect: `error[unsupported]` `analysis 'pss' cannot be written for xyce: Xyce has no periodic steady-state (shooting) analysis; its periodic analyses are .HB and .MPDE. Dialects that define it: ...`; output has `* [sprack] not written: analysis 'pss'`.
  - basis: commit diff (`no pss` line), grammar at HEAD (xyce.spgrammar:172), message shape from "an analysis the target cannot express…". INFERRED: the list of dialects after `Dialects that define it:`.
- (k) from: spectre   to: xyce
  - input: `// t\nsimulator lang=spectre\nparameters p=fmod(7,2)+db(10)\n`
  - expect: output `.param p={fmod(7,2)+db(10)}`; no report entry `function 'fmod' has no spelling in xyce` nor for `db`.
  - basis: commit diff (xyce functions `same ... fmod db`), grammar at HEAD (xyce.spgrammar:298, spectre.spgrammar:310). INFERRED: the brace form and spacing of the written expression.

### 68025e67 — `sprack caps` marks a moved kind `param` [PARTIAL: (h)]
- CLI check, no input: `sprack caps` → the row `ic` has `param` in the `vacask` column, and the legend has the line `param: written as a parameter of another statement (VACASK tran ic=).`
- basis: commit diff (src/main.zig), HEAD src/main.zig:176,191. INFERRED: that `ic` (and `nodeset`) are still `move`d kinds in vacask.spgrammar at HEAD — the test "verification: VACASK analyses…" shows `ic={"out",0.2}` on the tran, so yes for ic.

### 062bcac0 — VACASK: SFFM defaults, $abstime, chgtol, the save caveat [PARTIAL: (d), (f), (j), (k)]
- (d) from: ngspice   to: vacask
  - input: `t\nV1 a 0 sffm(0 1)\n.end\n`
  - expect: three `error[invalid]` entries: `vsource.freq is not given: VACASK's default carrier frequency is 1k; SPICE's is 1/TSTOP`, `vsource.mdi is not given: VACASK's default modulation index is 0.5; SPICE's is 0`, `vsource.fsig is not given: VACASK's default modulating frequency is 1k; SPICE's is 1/TSTOP`.
  - basis: grammar at HEAD (vacask.spgrammar:317–322), message format writer.zig:2540. INFERRED: which of the two frequencies ngspice's 3rd/5th SFFM argument binds to (`fsig`/`freq`) is irrelevant here since both are missing.
- (f) from: ngspice   to: vacask
  - input: `t\nV1 in 0 1\nB1 b 0 V={v(in)*time}\n.end\n`
  - expect: `B1 (b 0) v=v(in)*$abstime`, clean report.
  - basis: commit message (`$abstime`), grammar at HEAD (vacask.spgrammar:475–478 `time = $abstime`, "only in a behavioural source"). INFERRED: exact spacing; whether `time` outside a behavioural source is reported.
- (j) from: ngspice   to: vacask
  - input: `t\nR1 a 0 1k\n.options chgtol=1e-14\n.op\n.end\n`
  - expect: the control block holds `options chgtol=1e-14` before `analysis op1 op`; no `has no spelling in vacask` entry for chgtol.
  - basis: commit message ("Gaps: chgtol"), grammar at HEAD (vacask.spgrammar:166 `chgtol=chgtol`). INFERRED: number formatting.
- (k) from: ngspice   to: vacask
  - input: `t\nV1 in 0 AC 1\nR1 in 0 1k\n.ac dec 4 10 10k\n.save v(in)\n.end\n`
  - expect: `save v(in)` in the control block and `warning[caveat]` `save.signals: in VACASK's ac, noise, acxf and dcinc analyses v() saves the operating point; the small-signal value is dv() (docs/cmd-analysis-ac.md)`.
  - basis: commit message ("save caveat for AC"), grammar at HEAD (vacask.spgrammar:345), caveat format writer.zig:848 (`<kind>.<slot>: <text>`). INFERRED: that the caveat is raised for any save (not only beside an AC analysis).

### 04b5199f — nint crossing HSPICE is a caveat [PARTIAL: (o)]
- from: ngspice   to: hspice (and hspice → ngspice with `.param p='nint(x)'`)
- input: `t\n.param x=2.5\n.param p={nint(x)}\n.end\n`
- expect: output `.param p='nint(x)'`; `warning[caveat]` containing `nint in hspice: halves round away from zero (nint(2.5) is 3), not to even`.
- basis: commit message, grammar at HEAD (hspice.spgrammar:344), same assertion shape as tests.zig:3198 (ltspice) and :4610 (xyce).

### 33dfc935 — HSPICE has atan2, hypot, fmod and asinh [UNPINNED]
- from: spectre   to: hspice
- input: `// t\nsimulator lang=spectre\nparameters p=atan2(1,2)+hypot(3,4)+fmod(7,2)+asinh(1)\n`
- expect: output `.param p='atan2(1,2)+hypot(3,4)+fmod(7,2)+asinh(1)'`; the report has no `function '...' has no spelling in hspice` entry (clean, or caveats only).
- basis: commit diff (hspice.spgrammar functions `same nint db atan2 hypot fmod asinh`), grammar at HEAD (hspice.spgrammar:337); hspice quotes expressions with `'...'` (tests.zig:4596). INFERRED: spacing inside the written expression. (ngspice cannot be the source: its function table at HEAD has asinh but not atan2/hypot/fmod.)

### b855300c — ngspice reads the noise summary interval; HSPICE noise is against ground [PARTIAL: (b), (c)]
- (b) from: ngspice   to: hspice
  - input: `t\nvin in 0 ac 1\nr1 in out 1k\n.noise v(out) vin dec 10 1 1meg 5\n.end\n`
  - expect: the statement reads as `noise` with `interval` = 5 (not opaque); output has `.noise v(out) vin 5` after an `.ac dec 10 1 1meg` line.
  - basis: commit diff (ngspice.spgrammar noise rule gains `[interval]`), grammar at HEAD (ngspice.spgrammar:171, hspice.spgrammar:153). INFERRED: that hspice writes the sweep as a separate `.ac` line before the `.noise` (the reverse of 66c431f7's merge).
- (c) from: hspice   to: spectre
  - input: `t\nvin in 0 ac 1\nr1 in out 1k\n.ac dec 10 1k 1meg\n.noise v(out) vin\n.end\n`
  - expect: `noise1 (out 0) noise iprobe=vin start=1k stop=1M dec=10`; clean report.
  - basis: commit diff (`implied noise ref = 0`), grammar at HEAD (hspice.spgrammar:254); line shape from the spectre sample in tests.zig:100. INFERRED: the name `noise1` and `1M` spelling.

### b6567bf5 — a SIN without its frequency into Xyce is an error [PARTIAL: (e) WEAK]
- from: ngspice   to: xyce
- input: `t\nV1 a 0 SIN(0 1)\n.tran 10n 1u\n.end\n`
- expect: an error entry on line 2 that names the missing `freq` (the Xyce wave pattern `sin( sinedc ampl freq [...] )` requires it), and no `V1 a 0 sin(0 1)` line in the output (a `* [sprack] not written` comment instead).
- basis: commit message, test at HEAD asserts only `r2.hasErrors()`, grammar at HEAD (xyce.spgrammar:84). INFERRED: the code (`unsupported` from the no-form path) and wording (writer.zig:579 gives the why-text `a statement without 'freq'`).

### 60c1eb72 — IHP manifest: the six OSDI objects IHP's .spiceinit loads [PINNED-ENV]
- not a netlist fixture; today only `test_pdk_installed_ihp` (SPRACK_TEST_PDKS_INSTALLED + ngspice) tells.
- env-free check 1 (data): the `load` list of python/sprack/pdks/ihp-sg13g2.json has, in order, the basenames `psp103.osdi`, `psp103_nqs.osdi`, `r3_cmc.osdi`, `mosvar.osdi`, `cap_cmomi.osdi`, `cap_cmomf.osdi`.
- env-free check 2 (behaviour): a toy tree in the manifest's second layout (`libs.tech/ngspice/models/cornerMOSlv.lib` and the other corner files the `tt` corner names, six empty files under `libs.tech/ngspice/osdi/`); `p = sprack.PDK("ihp", root=toy)`; `[os.path.basename(s["path"]) for s in p.statements("ngspice") if s["kind"] == "hdl"]` is the six names in order and each path is in a circuit's ngspice netlist; remove one .osdi file and that entry is skipped (five).
- basis: manifest at HEAD (read literally), test_pdk_installed_ihp at HEAD, commit message ("a load entry whose file is missing is skipped"). INFERRED: how little the toy corner files may hold (89b8cb17 requires the chosen corner's files and sections to exist).

### ce8ed481 — GF180MCU manifest; installed layouts [PINNED-ENV]
- (b) env-free check: a toy tree holding the files python/sprack/pdks/gf180mcuD.json names (`models/ngspice/design.spice`, `sm141064.spice` with one empty `.lib <name>` ... `.endl` per section the corners name, `smbb000149.spice`); `p = sprack.PDK("gf180mcu", root=toy)`; assert `p.corners == ("tt", "ss", "ff", "sf", "fs")`, `p.entries("sf")[1:3] == [(m + "/sm141064.spice", "sf"), (m + "/sm141064.spice", "bjt_typical")]`, and a circuit's ngspice netlist has `.include "<m>/design.spice"` followed by 7 `.lib` lines, the first `.lib "<m>/sm141064.spice" typical` for corner tt.
- (c) the installed sky130A and IHP layouts are found by each manifest's first layout: only an installed tree tells; keep `test_pdk_installed_*` in a job that has one.
- basis: test_pdk_gf180mcu at HEAD (expected values read literally). INFERRED: the section names to put in the toy `sm141064.spice` (read them from the manifest).

### 2ddd4b02 — Analyses (b3): phasenoise, psp, envlp/qpss text, VACASK pnoise [PARTIAL: e, f]
- from: hspice   to: hspice
- input:
  t
  R1 out 0 1k
  .phasenoise v(out) dec 10 1k 1meg
  .end
- expect: output contains `.phasenoise v(out) dec 10 1k 1meg\n`, no errors.
- basis: grammar at HEAD (grammars/hspice.spgrammar:193, `implied phasenoise ref = 0` :202). Exact spacing INFERRED from the `.snac lin 3 100 300` round trip the b3 test asserts.

- from: hspice   to: spectre
- input: same deck
- expect: error[unsupported] containing `Spectre finds oscillator phase noise with pnoise or hbnoise on an autonomous steady state` and the comment `* [sprack] not written:`-style line for the analysis (comment leader INFERRED: Spectre writes `//`).
- basis: grammar at HEAD (grammars/spectre.spgrammar:252). The generic test `every `no` line` already asserts this for a made-up statement; this fixture asserts it for the read line.

- from: spectre   to: spectre
- input:
  // t
  simulator lang=spectre
  env1 envlp clockname="clk" stop=5m
  qp1 qpss funds=["f1" "f2"] maxharms=[2 2]
  ps1 psp start=10 stop=10k dec=4 ports=[p1 p2]
- expect: the three lines come back unchanged (`env1 envlp clockname="clk" stop=5m`, `qp1 qpss funds=["f1" "f2"] maxharms=[2 2]`, `ps1 psp start=10 stop=10k dec=4 ports=[p1 p2]`), no errors.
- basis: grammar at HEAD (grammars/spectre.spgrammar:144, :147, :149). INFERRED: exact text of the written lines (the test at HEAD only counts kinds).

- from: vacask   to: vacask
- input:
  t
  control
  analysis pn1 pnoise out="out" in="V1" tper=1m from=10 to=10k mode="dec" points=3
  endc
- expect: the analysis line unchanged, no errors.
- basis: grammar at HEAD (grammars/vacask.spgrammar:208); INFERRED by analogy with the asserted `analysis pac1 pac tper=1m from=10 to=10k mode="lin" points=9` round trip.

### 50285205 — Engine: counted lists, signal expressions [PARTIAL: count mismatch, expression refusal]
- from: ngspice   to: spectre
- input:
  t
  V1 a 0 1
  R1 a 0 1k
  .print dc -i(V1)
  .end
- expect: an error on the print line whose text contains `the signal expression -i(V1)` (Spectre has bare expressions and no `expr` signal template, so nothing tells the expression from a node name); the signal is not written as a bare `-i(V1)` in a `save` line.
- basis: commit diff (src/writer.zig; at HEAD writer.zig:402). INFERRED: the wrapping text around `e.why` (the b3/b4 tests show the shape `no <dialect> form of this statement can say <why>`).

- from: json   to: ngspice
- input: a `ctlsrc` statement with form=poly, dim=2 and only one cpos/cneg pair (`{"kind":"ctlsrc","name":"e1","pos":"o","neg":"0","form":"poly","dim":2,"cpos":["a"],"cneg":["0"],"coeffs":[0,1]}` — field spelling INFERRED from schema slot names)
- expect: an error containing `1 items where 'dim' says 2`; no `e1 ... poly(2) a 0 ...` line with one pair.
- basis: commit diff (`Emit.counted`; at HEAD writer.zig:503) and grammar at HEAD (grammars/ngspice.spgrammar:399).

### a7cdc5c8 — three reader fixes [PARTIAL: b, c, d]
- from: hspice   to: xyce (and ngspice)
- input:
  t
  Vc a 0 1
  R1 a 0 1k
  .dc Vc 0 1 0.1
  .print dc par('-i(vc)')
  .end
- expect: Xyce `.print dc {-i(vc)}`; ngspice `.print dc -i(vc)`; no error (the HSPICE `par('...')` form reads back as the expression signal).
- basis: commit diff (src/reader.zig, `par('-i(vc)')` branch) + the written forms asserted in `b4: output forms and measurements`. INFERRED: case of `vc` in the output.

- from: spectre   to: xyce
- input:
  // t
  simulator lang=spectre
  v1 (a 0) vsource dc=1 r=50
  p1 (b 0) port r=50 num=1
- expect: `p1 b 0 port=1 z0=50\n` (asserted today) AND the v1 line contains neither `z0=` nor `port=`: a plain source's `r=` is not moved into the port's z0 slot. What `r=50` becomes on v1 (a loss error or a copied parameter) is INFERRED — assert only the absence.
- basis: commit diff (`requiredMet` in src/reader.zig) + grammar at HEAD (grammars/spectre.spgrammar:165, :180).

- from: hspice   to: hspice
- input:
  t
  Vp b fb 0
  .ac dec 10 1 1meg
  .lstb mode=single vsource=Vp 7 8
  .end
- expect: no crash, and the trailing numbers `7 8` are not glued onto `vsource` as a matrix (`vsource=Vp 7 8` must not come back as a list value of an earlier-read parameter); the line is either unread (error[untranslated] `no hspice rule understood this line`) or read without the numbers changing `probe`.
- basis: commit diff (src/reader.zig: `last` is taken only when the bag entry just read logged a capture). INFERRED: this exact trigger; the fix guards a number following a fixed `k==lit` entry (`mode==single`).

### c9ba088a — b4 minor forms [PARTIAL: i]
- from: ngspice   to: ngspice
- input:
  t
  v6 g 0 trrandom(1 1n 0 1 0)
  .end
- expect: `v6 g 0 trrandom(1 1n 0 1 0)\n` unchanged, no errors.
- basis: commit message (ngspice trrandom) + grammar at HEAD (grammars/ngspice.spgrammar:111 `define wave`). INFERRED: argument spelling kept as written.

- from: ngspice   to: spectre
- input:
  t
  e1 o 0 poly(1) a 0 0 2
  .end
- expect: `e1 (o 0 a 0) pvcvs coeffs=[0 2]\n`.
- basis: grammar at HEAD (grammars/spectre.spgrammar:184) and the asserted sibling `g2 (0 o2 a 0) pvccs coeffs=[0 1m]`.

- from: hspice   to: hspice
- input:
  t
  g9 o9 0 vccap c 0 1u
  .end
- expect: `g9 o9 0 vccap c 0 1u\n` (the line is in the b4 test's input but has no assertion).
- basis: grammar at HEAD (grammars/hspice.spgrammar:424).

- from: vacask   to: vacask
- input:
  t
  control
    abort always
    elaborate circuit("top")
  endc
- expect: both read as kind simctl (2 statements) and are written back inside `control` ... `endc`; → ngspice: error `simctl: 'abort always' is a command of vacask's control language`.
- basis: grammar at HEAD (grammars/vacask.spgrammar:173). INFERRED: argument text of abort/elaborate and its spacing on output.

### b1c81f8d — Spectre pacmag and fundname are slots [PARTIAL: b]
- from: spectre   to: ngspice
- input:
  // t
  simulator lang=spectre
  v1 (a 0) vsource dc=1 pacmag=1 fundname="f1"
  r1 (a 0) resistor r=1k
- expect: the v1 line is written without `pacmag` and `fundname`; two errors (code loss) `vsource.pacmag = 1 has no spelling in ngspice` and `vsource.fundname = f1 has no spelling in ngspice`.
- basis: commit diff (grammars/spectre.spgrammar, src/schema.zig) + message format at HEAD (src/writer.zig:882 `{kind}.{slot} = {value} has no spelling in {dialect}`). INFERRED: how the value is described in the message (`f1` vs `"f1"`).

### e700e490 — VACASK point-count caveats [PARTIAL: b]
- from: ngspice   to: vacask
- input:
  t
  V1 a 0 1 ac 1
  R1 a 0 1k
  .dc V1 0.2 0.9 0.005
  .ac dec 10 1 1k
  .noise v(a) V1 dec 10 1 1k
  .end
- expect: three warnings (code caveat): `dc.step: VACASK counts a stepped sweep's points with no rounding tolerance, so a stop a whole number of steps away may lose its last point`, `ac.points: VACASK counts points per decade with no rounding tolerance`, `noise.points: VACASK counts points per decade with no rounding tolerance`.
- basis: grammar at HEAD (grammars/vacask.spgrammar:531-533) + caveat format at HEAD (src/writer.zig:848 `{kind}.{slot}: {text}`).

### e2d0d41d — instance parameter table, HSPICE as the target [PARTIAL: f]
- from: ngspice   to: hspice
- input:
  t
  R1 a b 1k noisy=0 tc=1m temp=50 m=-2
  .end
- expect: `R1 a b 1k noise=0 tc1=1m ...` (noisy → noise, tc → tc1); info (code rename) `resistor: the instance parameter 'noisy' is spelled 'noise' in hspice`; error (code loss) `resistor: 'temp=50' has no spelling in hspice, whose resistor takes no such instance parameter`; error `resistor: m=-2: hspice refuses m of zero or less`.
- basis: grammar at HEAD (grammars/hspice.spgrammar `params resistor`: `same ac c dtemp l m>0 scale tc2 w`, `tc1 = tc1 tc`, `noisy = noise`) + message formats at HEAD (src/writer.zig:1553, :1562) + the Xyce-target strings the test asserts. INFERRED: whether m=-2 is still written on the line (it is for Xyce: `R1 a b 1k m=-2 tc1=1m`).

### ae35fa60 — HSPICE: a single trailing backslash continues [PARTIAL: a]
- from: hspice   to: ngspice
- input (each `\` is one backslash, the last character of its line):
  t
  .param b=1 c=2
  R1 a 0 \
  1k
  .param a='(b == 1 ? c : \
          (b == 2 ? 3 : 4))' $ note (x), y
  .end
- expect: `R1 a 0 1k\n`; the .param reads as one statement with value `(b == 1 ? c : (b == 2 ? 3 : 4))` and the `$ note ...` is a comment; 0 entries of code untranslated.
- basis: commit message + commit diff (grammars/hspice.spgrammar `continue trail "\"`, src/lexer.zig). INFERRED: whether a blank is kept where the single backslash joined (the doubled form joins with no blank).

### e48768eb — a parameter defined twice into Spectre [WEAK]
- from: hspice   to: spectre
- input:
  t
  .param vt0=0.3
  .param vt0=0.35
  .end
- expect: exactly one error, code invalid, on line 3: `parameter 'vt0' is defined twice in one scope; Spectre stops on a redefinition where SPICE keeps the last value`. And the control: hspice → ngspice of the same deck has no such entry (ngspice has no `unique param` line). Second case, a different scope is not a redefinition: `.param w=1` at top and `.param w=2` inside `.subckt s a b` → no error.
- basis: code at HEAD (src/writer.zig:2895) + grammar at HEAD (grammars/spectre.spgrammar:275). The scope case is INFERRED from `uniqueParams` recursing per body with a fresh set.

### 3cdf3fdc — project copies Verilog-A sources and rewrites the .hdl path [PARTIAL: d]
- from: hspice   to: spectre   (sprack project, library mode)
- input: in/top.lib = `.lib tt` / `.hdl './cap.va'` / `.endl tt`; in/cap.va = `module cap(a, b); endmodule`
- expect: BOTH (1) out/cap.va exists with the same bytes as in/cap.va, and (2) out/top.lib names it by a path that resolves inside out/ (`ahdl_include "cap.va"` or `"./cap.va"` — exact spelling INFERRED), and (3) the report/log has no entry containing `OSDI` for the .va file. Add an .osdi sibling (`.hdl 'x.osdi'`) and assert the compiled-OSDI caveat IS reported for it (suffix condition `caveat hdl path=*.osdi`).
- basis: commit message; test at HEAD asserts only `va_copied or top lacks ahdl_include "./cap.va"`.
- also (b): Python `PDK.translate(d)` for a corner made of sections writes to a cache directory tagged `<dialect>-<corner>-<stamp>` and passes only that corner's sections to the core; minimal check: a made-up PDK with sections tt and ff, translate with corner=tt, assert the translated m.lib has no statements of section ff's includes and the directory name contains `-tt-`. basis: commit diff (python/sprack/__init__.py); directory layout may have changed since — verify against HEAD before asserting.

### 3f81c5a6 — expression semantics: oneway note and the remaining `differs` rows [PARTIAL]
- from: ngspice   to: ltspice
- input:
  t
  .param x=2
  .param q={x>1 ? 1 : 0}
  .end
- expect: `.param q={if(x>1, 1, 0)}` (asserted today) plus one info, code oneway: `expression 'x>1 ? 1 : 0': ltspice has no ..., so the choice is written ...; it reads back in that form`.
- basis: message format at HEAD (src/writer.zig:265). INFERRED: the two filled-in words.

- differs rows, one deck each, expect a warning `<name> in <dialect>: <text>`:
  - ngspice → xyce `.param p={(-2)**3}` → `pow in ngspice: a negative base loses its sign` (grammars/ngspice.spgrammar:305)
  - ngspice → xyce `.param p={int(2.5)}` → `int in ngspice: only .param expressions have int(); a B source refuses it` (:310)
  - hspice → xyce `.param p='pwr(-2,2)'` → `pwr in xyce: pwr(x,y) is pow(x,y) here` (grammars/xyce.spgrammar:322)
  - ngspice → xyce `.param p={log10(-100)}` → `log10 in xyce: a negative argument is taken by its magnitude` (:325)
  - spectre → hspice `parameters p=log10(x)` → `log10 in hspice: a negative argument gives -log10|x|` (grammars/hspice.spgrammar:346)
- basis: grammar at HEAD (lines cited) + the `<name> in <dialect>: <text>` shape of the four asserted rows. INFERRED: for each row, whether the warning fires when the dialect is the source, the target, or both (asserted rows show source for `pwr in ngspice`, target for `nint in xyce` and `ln in hspice`).

### 9ba3ead4 — lot/gauss and /unif variations [PARTIAL]
- from: ngspice   to: xyce
- input:
  t
  .param p=1 lot/gauss=0.1 q=2 dev/unif=0.2 r=3 lot/unif=0.3
  R1 a 0 {p*q*r}
  .end
- expect: `.param p={agauss(1, 0.1, 1)} q={aunif(2, 0.2)} r={aunif(3, 0.3)}` and a warning naming the form (`lot/gauss=` / `dev/unif=`); into Spectre: `vary p dist=gauss std=0.1` in a process block, and `q`, `r` as `dist=unif` variations.
- basis: code at HEAD (src/stats.zig:113-160: `p=nom dev/gauss=s` per device, `lot/gauss=s` per run, or `/unif`; `aunif({nom}, {s})`). INFERRED: the Spectre block (process vs mismatch) each lands in and the `N=` spelling of the uniform width.

### 137d6f02 — VACASK instance parameter tables [PARTIAL: (d)]
- from: (none; `sprack info`)   to: -
- input: run `sprack info` (or `sprack.KINDS` in Python) and read `kinds.<kind>.params`
- expect: `kinds.resistor.params.vacask` is a list holding `$mfactor`, `tc1`, `tc`, `noisy`, `noise`, …; `kinds.mosfet.params` has NO `vacask` key (its table ends in `same ...`: open, nothing to offer). Python consequence: on a VACASK-dialect PDK, calling a MOSFET model card with an unlisted keyword raises no TypeError, while a resistor card with an unlisted keyword raises "… takes no parameter 'x'; it takes: …".
- basis: commit diff (src/json.zig `writeInfo`: "An open table checks nothing: no list to offer"); json.zig:354 and grammars/vacask.spgrammar:378-412 at HEAD; python/sprack/__init__.py:481-485 at HEAD. The exact list contents are INFERRED from the grammar table (every spelling of every entry).

### 168c6032 — Alters [PARTIAL: (g) device-changing alter into ngspice / VACASK]
- from: hspice   to: ngspice (and the same deck to vacask)
- input:
  t
  V1 a 0 1
  R1 a b 1k
  R2 b 0 1k
  .op
  .alter
  R2 b 0 3k
  .end
- expect: report has error[unsupported] "alter cannot be written for ngspice: the form this grammar writes changes only parameters and the temperature, not a resistor" (for vacask the same text with `vacask`); no `.control`/`alterparam` block (ngspice) or `alter instance(...)` line (vacask) is written for that alter; the netlist's own `R2 b 0 1k` is unchanged.
- basis: alter.zig:139-151 at HEAD (`refuse(… "the form this grammar writes" …)`, read literally); the Xyce variant of the same message is asserted in "c2 alter: reruns with cumulative edits…". That no block is written for the refused alter is INFERRED from `flatten` returning null.

### 168c6032 — Alters [PARTIAL: (h) alter into a dialect with `no alter` and no .data table]
- from: hspice   to: ltspice (and cdl)
- input:
  t
  .param ra=1k
  V1 a 0 1
  R1 a 0 'ra'
  .op
  .alter hot
  .param ra=3k
  .end
- expect: error[unsupported] on the alter's line whose text holds the grammar's reason "LTspice has no .alter; a rerun with other values is a .step" (cdl: "CDL is a netlist, not a simulation deck; it has no analyses to rerun"); the output has exactly one `.param ra=1k` and NO `.param ra=3k` (the alter's body is emptied, not written as the netlist's lines); the place of the alter is the comment line `* [sprack] not written: …`.
- basis: grammars/ltspice.spgrammar:333, grammars/cdl.spgrammar:150, alter.zig:36-41 at HEAD ("The writer reports each as unsupported; its edits are not the netlist's"). The full message shape ("analysis 'alter' cannot be written for ltspice: <reason>. Dialects that define it: …") is INFERRED from writer.zig:1758 and the pz case in build.zig cliTests; the generic test "every `no` line…" explicitly skips kind alter, so nothing asserts this today.

### 70be96f3 — Topology severities per grammar [PARTIAL: (d)]
All INFERRED from the `requires` lines at HEAD (hspice.spgrammar:302-305, spectre.spgrammar:267-270, xyce.spgrammar:204-207, ngspice.spgrammar:229-231) and the message formats in topology.zig:484 and :570 (code is `invalid`; the grammar's reason follows after "; "). Source dialect must differ from the target (a deck of the target's own statements is not checked, e1), so use ngspice→X, and hspice→ngspice for the ngspice cells.
- island deck (I): `t\nV1 in 0 1\nC1 in x 1p\nC2 x 0 1p\n.tran 1n 10n\n.end\n`
  - ngspice→hspice: warning[invalid] "node 'x' has no DC path to ground: only C1, C2 reach it" … "HSPICE solves it but starts such nodes at 0 V"
  - ngspice→xyce: warning[invalid] same node text … "Xyce solves it with a warning"
  - hspice→ngspice: warning[invalid] same node text … "ngspice solves it only through its transient operating point"
- V-loop deck (V): `t\nV1 a 0 1\nV2 a 0 1\nR1 a 0 1k\n.op\n.end\n`
  - ngspice→hspice: error[invalid] "V1, V2 form a loop of voltage sources through 'a' and '0'; HSPICE stops on it"
  - ngspice→spectre: error[invalid] same loop text "; Spectre stops on it"
  - hspice→ngspice: error[invalid] same loop text "; ngspice's operating point fails on it"
- V+L-loop deck (VL): `t\nV1 a 0 1\nL1 a 0 1u\n.op\n.end\n`
  - ngspice→hspice: error[invalid] "V1, L1 form a loop of voltage sources and inductors through 'a' and '0'"
  - ngspice→spectre: error[invalid] same text
  - ngspice→xyce: error[invalid] same text
  - hspice→ngspice: warning[invalid] same text … "ngspice solves it only through its transient operating point, and the current around the loop is arbitrary"
- L-loop deck (L): `t\nV1 in 0 1\nR1 in p 1k\nL1 p 0 1u\nL2 p 0 1u\n.op\n.end\n`
  - ngspice→hspice: error[invalid] "L1, L2 form a loop of inductors through 'p' and '0'; HSPICE stops on it, where ngspice and Xyce solve it"
  - (already pinned: spectre error, xyce warning, ngspice nothing, vacask error)
- each deck: exactly one topology entry (count entries whose text holds "DC path" or "form a loop").

### 22ed612f — Topology: no alarm [PARTIAL: (b) XSPICE A device]
- from: ngspice   to: vacask
- input:
  t
  .model lim limit(gain=1)
  A1 y lim
  C1 y 0 1p
  V1 in 0 1
  R1 in 0 1k
  .tran 1n 10n
  .end
- expect: no report entry containing "DC path" (the A device is taken to reach ground inside, as the Verilog-A `N1 y pm` case already asserted); the XSPICE statement itself is still an error "XSPICE code models are ngspice's …".
- basis: commit diff (src/topology.zig: `.device, .xspice, .instance => true`), topology.zig:275 at HEAD. The A-line and `.model … limit(...)` spelling is INFERRED from grammars/ngspice.spgrammar:157 (`rule xspice = name~"A" nodes+ master {...params}`); adjust the card to whatever ngspice reads as kind xspice.

### e30a214b — c4 [PARTIAL: (l) derivative measure into ngspice is weak]
- from: hspice   to: ngspice
- input:
  t
  r1 out 0 1k
  .tran 10n 5u
  .measure tran slope deriv v(out) at=1u
  .end
- expect: an error naming the measure and the missing form — INFERRED text "no ngspice form of this statement can say op = deriv" (pattern of "no ltspice form of this statement can say style = probe"); the `.measure` line is not written as a working ngspice measure.
- basis: commit message ("ngspice 45 has no DERIV measure (no rule writes one)"), grammars/ngspice.spgrammar:412-413 at HEAD. Today's test asserts only `r2.count(.@"error") > 0`. Message text INFERRED.

### e30a214b — c4 [PARTIAL: (m) malformed extra .tran numbers is weak]
- from: hspice   to: ngspice
- input:
  t
  .tran 1n 10n 1n 5n 2n
  .end
- expect: error[invalid] "tran: 3 numbers after the step and stop are neither rising step and stop pairs nor a start time and a step ceiling"
- basis: reader.zig `foldSegments` at HEAD (lines 2252-2254, read literally). Today's test asserts only `r2.count(.@"error") > 0`.

### d7bf89c1 — Translate as a stream [PARTIAL: (c)]
- from: ngspice   to: hspice (CLI)
- input:
  ```
  t
  V1 a 0 1
  R1 a 0 1k
  .pz a 0 a 0 vol pz
  .end
  ```
- expect: `SPRACK_STREAM_WHY=1 sprack translate --from ngspice --to hspice` writes `sprack: read whole: a pole-zero analysis` on stderr; without the variable no such line; with `SPRACK_WHOLE=1` stdout and the report are byte-identical to a run without it (try the 3-line RC deck of `cliTests`). If the new engine has one path only, decide deliberately to drop both variables rather than lose them silently.
- also worth capturing as golden text from the HEAD binary before the rewrite: `stream_deck` (src/tests.zig:2768) → spectre, xyce, hspice, vacask, ltspice. Today it is only compared stream-against-whole, so its absolute output (merged `.option`, topology entries for the two islands, dev/gauss and agauss lowering) is pinned by no test once the two paths become one.
- basis: stream.zig:251-267 and main.zig:285,357 at HEAD (reason strings and the stderr format read literally); that this exact deck reaches the `.pz` reason first is INFERRED (the first reason found wins; a pz deck has no earlier one).

### 82ecaa9e — read the input at its size [PARTIAL: (b)]
- not a netlist fixture. Minimal check: generate a ~100 MiB RC mesh (tools/gen_bench.py), run `sprack translate --from ngspice --to xyce mesh.sp -o /dev/null` under `/usr/bin/time -v` and assert max RSS < 2x the file size (README: 1.5x measured on a 111 MiB mesh; 1.6x on 45 MiB of sky130 cells, 2.1x into Spectre). Same from stdin (`< mesh.sp`), where no size is known and the buffer grows.
- basis: commit diff (src/main.zig `readWhole`), README numbers from bac071a9; the 2x threshold is INFERRED.

### c6e51fc1 — PSP103: what Xyce's lacks is said by name [PARTIAL: (c)]
- from: ngspice   to: xyce
- input (neutral values):
  ```
  t
  .model nm psp103va type=1 st2vfbo=0 ctgo=0 ctbo=0 stcto=1 stthecso=0 nsubedgelexp=1 thecso=2 tr=27
  .end
  ```
- expect: `.model nm nmos level=103 tr=27`; 0 errors; seven warnings "model 'nm': <key> not written: Xyce's PSP103 has no such parameter; at <0\|1\|2> it changes nothing" (0 for st2vfbo, ctgo, ctbo, stthecso; 1 for stcto, nsubedgelexp; 2 for thecso).
- input (acting values): same card with `st2vfbo=0.1 ctgo=1 ctbo=1 stcto=2 stthecso=1 nsubedgelexp=2 thecso=1.2`
- expect: same card line; seven errors "model 'nm': <key> not written: Xyce's PSP103 has no such parameter and ignores it; the device is simulated without its effect".
- basis: grammar at HEAD (grammars/xyce.spgrammar:229-248) and the message form asserted for thecso/ctgo in "r1: ngspice's psp103va is PSP103; ..." — the other keys are INFERRED to behave the same; whether `stcto=1.0` or `thecso=2.0` match the neutral value (text or number comparison) is not known and worth one case each. vacask.spgrammar:847-860 carries the same seven pairs (from a later commit) with its own wording.

### 009bbd04 — the cache follows the build of the core [PARTIAL: (b)]
- not a netlist fixture (Python). Minimal check, in the style of test_library_translated_on_the_fly: with a fresh `SPRACK_CACHE`, `c = sprack.Circuit("t"); c.code('.lib "<d>/x.lib" tt\n', "ngspice"); c.netlist("xyce")` → one directory under `<cache>/libs`; point `sprack._core.__file__` at another existing file (as test_tiny_pdk_subcircuit_for_each_branch does for the PDK stamp) and call `c.netlist("xyce")` again → two directories.
- basis: commit diff (python/sprack/__init__.py: `_build()` in the `_library_copy` key); the directory count is INFERRED.

### 9ca39691 — a project's paths on Windows [PARTIAL: (b)]
- not a netlist fixture. Minimal check on any host needs `commonDir`/`dirname` to take the host flag as `resolveOn`/`normalizeOn`/`rootLenOn` do: `commonDir(win, {"C:/pdk/libs/a.lib", "C:/pdk/models/n.lib"})` = `C:/pdk`; `{"C:/a.lib", "C:/b/n.lib"}` = `C:/` (stops at the drive root, never `C:`); `dirname("C:/x.lib")` = `C:/`.
- on a Windows host: `sprack project` on `C:\dir\top.lib` that includes `sub\m.lib` reports `"root":"C:/dir"`, lists files with `/`, and the include line of the translated copy reads `.include "sub/m.lib"`.
- basis: commit diff (src/project.zig `rootLen`, `dirname`, `commonDir`, `resolve`); expected strings are INFERRED from the code, none is asserted today.

### ed0f1db0 — Python on Windows [PINNED-ENV]
- not a netlist fixture; only a Windows host tells. What the Windows CI job must keep asserting: (a) `Circuit("10 k\u03a9 divider")` with one resistor, `c.write(path, "ngspice")` → `open(path, "rb").read() == c.netlist("ngspice").encode()` (UTF-8, no `\r`); `python -m sprack --from ngspice path` and the same on stdin exit 0 with `"10 k\u03a9 divider"` in stdout; (b) two processes translating the same library on the fly (spawn) both finish, and the sweep of a cache with a live writer's lock does not end that writer (`os.kill(pid, 0)` would).
- basis: py test_utf8_and_lf_on_every_platform at HEAD (read literally); (b) from the commit message and diff (`_alive` via OpenProcess) — INFERRED as a check, no test names it.

### fa7180a9 — e2: the kind `verilog` and the slot `points` of `pss` go [WEAK]
- from: ngspice   to: xyce
- input:
  ```
  t
  .verilog top.v
  R1 a 0 1k
  .end
  ```
- expect: output holds `* [sprack] untranslated ngspice: .verilog top.v`; report has one error[untranslated] `no ngspice rule understood this line; it is in the output only as a comment: .verilog top.v`. Also: `sprack info` JSON has no kind `verilog`, and the `pss` kind's slots are `name fund harms tstab params ic`, the common ones, `period` and `tres` (src/schema.zig:316 at HEAD), with no `points`.
- basis: commit diff (src/schema.zig, the seven grammars). The exact comment and message text are INFERRED from the sibling assertions in `lines no rule understands are errors across dialects and untouched within one`; not read for this input.

### b8c048f7 — card parameters into Xyce (#33) [PARTIAL: (c2), and (a) for vbic/bsim3/bsim4]
- from: ngspice   to: xyce
- input:
  ```
  t
  .model n3 nmos level=8 nqsmod=0 rd=0 vth0=0.5
  .model q1 npn iss=0 ns=1 bf=100
  .model q2 npn iss=1e-15
  .model n4 nmos level=54 version=4.5 vth0=0.4 zzfoo=1
  .model q4 npn level=4 is=1e-16 zzbar=2
  Q1 c b e s t q4
  .end
  ```
- expect: `.model n3 nmos level=9 vth0=0.5` with warnings `model 'n3': nqsmod not written: Xyce's BSIM3 has no such parameter; at 0, ngspice's default, it changes nothing` and the same for `rd`; `.model q1 npn bf=100` with warnings for `iss` (`at 0, ...`) and `ns` (`at 1, ...`); errors: `model 'q2': iss not written: Xyce's BJT has no such parameter; the device is simulated without its effect`, `model 'n4': zzfoo=1 not written: the bsim4 card of xyce takes no such parameter`, `model 'q4': zzbar=2 not written: the vbic card of xyce takes no such parameter`; exactly 3 errors.
- basis: grammar at HEAD (grammars/xyce.spgrammar:712-729 the noparam lines; :355 and grammars/ngspice.spgrammar:343 for level 8 → 9; :519/:532/:568 `modelparams vbic/bsim3/bsim4 only`). Message layout (`model '<n>': <key> not written: <reason>`, `<key>=<value> not written: the <family> card of xyce takes no such parameter`) is INFERRED from the asserted diode/bjt/PSP103 messages; whether the reason is followed by the list of names the card takes, and the family word printed for vbic, were not read.

### ba6a0908 — Xyce's reserved names in alters (#34) [PARTIAL: (c)]
- from: hspice   to: xyce
- input:
  ```
  t
  .param vt=1m
  V1 a 0 1
  R1 a 0 '1k*(1+vt)'
  .op
  .alter one
  .param vt=3m
  .end
  ```
- expect: `.param vt__p=1m`, `R1 a 0 {1k*(1+vt__p)}`, and the table the alters are written as names the renamed parameter: `.data alters vt__p ...` with `.step data=alters`; the word `vt` alone appears nowhere as a column or a parameter; info `parameter 'vt' is written as 'vt__p' ...`; no error.
- basis: commit diff (src/writer.zig: `st.kind == .alter and (sl.name == "param" or "keys")` joins the slots whose words are renamed) and the alter form asserted by `c2 alter: reruns with cumulative edits, in each dialect's form` (`.data alters ra temp 1k 25 3k 25 3k 75` / `.step data=alters`). INFERRED: the exact row values and whether a `temp` column is present when no alter sets the temperature. A second fixture for a target that keeps alters as alters is not possible with a built-in dialect (only Xyce reserves names).

### 2768ed66 — the report says what crosses (#36) [PARTIAL: (c)]
- from: a grammar file (copy of ngspice.spgrammar plus a `raw "<open>" "<close>"` line)   to: spectre
- input: a deck whose raw region has three lines, e.g. with `raw ".blob" ".endblob"`:
  ```
  t
  R1 a 0 1k
  .blob
  one
  .endblob
  .end
  ```
- expect: without a reason on the `raw` line: error[untranslated] `no <source> rule understood this line; it is in the output only as a comment: .blob (and 2 more lines of it)`; with `: reason` on the `raw` line: error[unsupported] `'.blob' and the 2 lines after it cannot be written for spectre: <reason>` and the comment `// [sprack] not written: .blob`.
- basis: writer at HEAD (src/writer.zig:2281-2296) and reader at HEAD (src/reader.zig:1552-1565, lines of a raw region joined by `\n`). INFERRED: the `raw` directive's syntax without `as` (only `raw "embed" ">>>FILE" as embed : ...` exists in a built-in grammar, grammars/vacask.spgrammar:131). The original assertion (`.control (and 3 more lines of it)`) was removed by 43466f7a (#50); no built-in dialect reaches this message now.

### e0f46280 — limits (#37) [PARTIAL: (b), (c), (f)]
- (b) cli check: `sprack translate --from ngspice --to xyce /dev/zero` → exit status 1, stderr `/dev/zero: error[invalid]: not a regular file or a pipe; not read`, nothing on stdout.
  - basis: src/main.zig:102-106,124-128 at HEAD (read literally). POSIX hosts only.
- (c) cli check: a sparse regular file of 1 GiB + 1 byte as the input → exit status 1, stderr `<name>: error[invalid]: larger than 1024 MiB, the most an input may hold; not read`; as an include under `sprack project` → the log line `<path>: error[invalid]: larger than 1024 MiB, the most an input may hold; not read` and 1 error.
  - basis: src/main.zig:107-110,131 and src/project.zig:653-654 at HEAD (read literally); `ir.max_input = 1 << 30` (src/ir.zig:189).
- (f) memory bound: read (ngspice) 60,000 statements nested 100 blocks deep with a counting allocator; assert the peak stays within a small multiple of the input (the commit measured 29 MiB after, 437 MiB before).
  - basis: commit message. INFERRED: the bound to assert (e.g. under 64 MiB).

### 2060a289 — pdk errata (#42) [PARTIAL: (d), (e)]
- (d) cli check, ngspice → xyce: files `in/lib.spice` = `* lib` / `.include "cells/r.spice"`, `in/cells/r.spice` = `* cell` / `.subckt rr a b` / `res a b rm r = 1k tc1r = 1m` / `.ends`, and `e.json` = `[{"file": "cells/r.spice", "was": "res a b rm r = 1k tc1r = 1m", "read": "Rres a b rm r = 1k tc1 = 1m", "why": "a switch to ngspice"}]`; run `sprack project --from ngspice --to xyce --lib --errata e.json --out out in/lib.spice` → exit 0, `out/cells/r.spice` holds `Rres a b 1k rm tc1=1m`, and standard error holds once `r.spice:3: warning[caveat]: read through an erratum of the PDK: 'res a b rm r = 1k tc1r = 1m': a switch to ngspice; read as 'Rres a b rm r = 1k tc1 = 1m'`. The same with `e.json` = `{"name": "x", "errata": [...]}` (a manifest).
  - basis: the project.zig test at HEAD (expected text read literally) and the usage text in src/main.zig:11-26. The command's report goes to standard error (src/main.zig:249, `.log = err`); INFERRED: the path prefix printed before `r.spice:3`.
- (e) Python check without a PDK checkout: a made-up PDK directory and manifest (as the `test_tiny_pdk_*` tests build) whose manifest has the `errata` above; translate through `sprack.PDK` for xyce and assert the same `warning[caveat]: read through an erratum of the PDK` line in the tree's `sprack.log`.
  - basis: python/sprack/__init__.py:1388,1474-1477 at HEAD (`_errata()` passed to `_core.project`); the log file name from `test_pdk_sky130`. INFERRED: the tiny-PDK helper can carry an `errata` key.

### de7005fe — `--provide NAME=FILE` / `--xyce-plugin` on the command line [PARTIAL: (b)]
- from: ngspice   to: xyce   (a cliTests case; also covers 6b384c4d's flag)
- input (stdin of `sprack translate --from ngspice --to xyce --provide r3_cmc=r3_cmc.so`):
  ```
  t
  .model rmod r3_cmc rsh=100
  N1 a b c rmod w=1u l=2u
  v1 a 0 1
  .op
  .end
  ```
- expect: exit 0; stdout contains `Yr3_cmc N1 a b c rmod w=1u l=2u`; stderr contains `warning[caveat]: line 3: device: the Verilog-A module 'r3_cmc' is the plugin r3_cmc.so: run xyce with -plugin r3_cmc.so`. The same run with `--xyce-plugin r3_cmc=r3_cmc.so` gives the same output. Without the flag: exit 1, stderr has `error[unsupported]: line 3: device: xyce instantiates the Verilog-A module 'r3_cmc' only through a plugin of it`. `--provide r3_cmc` (no `=`): exit 2, stderr `--provide takes NAME=FILE`.
- basis: src/main.zig:215-218 at HEAD (flag parsing, die text), writer.zig:1803/1809 (messages), the Zig test "#52: a Verilog-A instance into Xyce is a Y line…" (output line). INFERRED: the stderr prefix `warning[caveat]: line 3:` (format taken from other cliTests cases) and that nothing else makes the status non-zero.

### 7691f313 — a variable that does not lead the path keeps the including file's directory [PARTIAL: (c)]
- from: ngspice   to: spectre   (project; a cliTests case run with cwd = the tree)
- input: `top.sp`:
  ```
  top
  .include "a/b/mid.sp"
  .include "${INC}/sub2.sp"
  X1 a 0 rdiv
  .op
  .end
  ```
  `a/b/mid.sp`: `.include "inc/$SUB/sub.sp"`; `a/b/inc/x/sub.sp`: `.subckt rdiv a b` / `R1 a b 1k` / `.ends rdiv`; `common/sub2.sp`: `.subckt r2 a b` / `R1 a b 1k` / `.ends r2`; run `sprack project --from ngspice --to spectre -D SUB=x -D INC=common --out o top.sp`
- expect: stderr `4 files, 0 errors, 0 warnings` (mid.sp's `inc/$SUB/sub.sp` found beside mid.sp, not from the working directory; `${INC}/sub2.sp` found from the working directory).
- basis: commit diff (src/project.zig `leadsWithDefined`: only a path whose first characters are `$NAME` or `${NAME}` with a -D value uses the cwd). INFERRED: the file count line; that `${NAME}` is expanded by `expand` as `$NAME` is.

### 692d2f56 — a device whose Verilog-A model card is in another file of the project [PARTIAL: (b)]
- from: ngspice   to: xyce   (project of two files)
- input: `top.sp`:
  ```
  top
  .include "models.lib"
  N1 a b c rmod w=1u l=2u
  v1 a 0 1
  .op
  .end
  ```
  `models.lib`: `.model rmod r3_cmc rsh=100`
- expect: log has `top.sp:3: error[unsupported]: device: xyce instantiates the Verilog-A module 'r3_cmc' only through a plugin of it` and the translated top.sp has `* [sprack] not written: N1`; with `--provide r3_cmc=r3.so` the translated top.sp has `Yr3_cmc N1 a b c rmod w=1u l=2u` and 0 errors. It must not be a "no form"/unknown-model error.
- basis: commit diff (src/writer.zig: `w.modules.get(master) orelse e.modules.get(master)`; src/ir.zig Env.absorb). INFERRED: the `file:line:` log prefix (form seen in project.zig's errata test) and the exact outputs, which are #52's for a one-file netlist.

### a2c0a524 — a signal call that the line ends before closing [WEAK]
- from: ngspice (parentheses are blanks) and spectre (parentheses are tokens)   to: any
- input:
  ```
  t
  R1 a 0 1k
  .print tran db(i(vm
  .save v(a
  .ic v(a)=1 v(
  .end
  ```
  and for spectre: `// t` / `R1 (a 0) resistor r=1k` / `save v(a`
- expect: no panic and no out-of-bounds read; reading returns a netlist and a report; the three damaged lines are not read as signals (each is an untranslated/opaque line or an error entry), `R1` is read.
- basis: commit message and diff (src/reader.zig signalAt: "The window ends before the call closes: no signal"). INFERRED: which exact line panicked before the fix (the fuzzer's input was not kept) and the code of the entries; assert "does not crash, R1 present" and pin whatever entries the current build gives.

### 2a2e10c5 — a slot both grammars' `invalid` lines cover is said once, in the source's words [PARTIAL: (e)]
- from: ltspice   to: vacask
- input:
  ```
  t
  V1 a 0 exp(0 1)
  R1 a 0 1k
  .tran 1n 10n
  .end
  ```
- expect: exactly 3 entries of code `invalid` for line 2, each with LTspice's reason: `error[invalid]: line 2: vsource.tau1 is not given: LTspice's default rise time constant is 0, an instant rise; ngspice's and Xyce's is the time step`, `vsource.td2 is not given: LTspice's default TD2 is 0, so the fall starts with the rise; …`, `vsource.tau2 is not given: LTspice's default fall time constant is 0, an instant fall; …`; none with VACASK's text ("VACASK's default rise time constant is 0…").
- basis: commit message ("LTspice to VACASK: 3 errors, not 6"), commit diff (writer.zig `check(g, stmts, before)` / `fires`), grammars at HEAD (ltspice.spgrammar:205-210, vacask.spgrammar:311-316). INFERRED: that this deck is the one meant and that LTspice reads `exp(0 1)` with the three slots absent.

### 2a2e10c5 — a library given itself with no --section is followed whole [PARTIAL: (f)]
- from: ngspice   to: spectre   (cliTests: `sprack project --from ngspice --to spectre --lib --out o corners.lib`)
- input `corners.lib`:
  ```
  .lib tt
  .param rsh=10
  .endl tt
  .lib ff
  .param rsh=8
  .endl ff
  ```
- expect: stderr `1 file, 0 errors, 0 warnings` and no "not followed" line; `o/corners.lib` has both `section tt\nparameters rsh=10\nendsection tt` and `section ff\nparameters rsh=8\nendsection ff`.
- basis: commit diff (src/project.zig: `top_sections = opts.sections.len == 0`; `!(top and r.top_sections)`), the existing `--lib --section tt` CLI case for the output form. INFERRED: the exact text for section ff.

### 2a2e10c5 — PDK.devices leaves out a section the corner does not follow [PARTIAL: (d), env-only today]
- minimal check (Python, no PDK checkout; name it without the `test_pdk_` prefix): a toy PDK directory with `models.lib` = `.lib tt` / `.subckt ra a b` / `R1 a b 1k` / `.ends` / `.endl tt` / `.lib ff` / `.subckt rb a b` / `R1 a b 2k` / `.ends` / `.endl ff`, manifest `{"name":"toy","dialect":"ngspice","layouts":[{"probe":"models.lib"}],"corners":{"tt":[["models.lib","tt"]],"ff":[["models.lib","ff"]]}}`.
- expect: `sprack.PDK("toy", root=d, manifest=m, corner="tt").devices` holds `ra` and not `rb`; with `corner="ff"` (same cache_dir) it holds `rb` and not `ra` (the catalogue is cached per corner).
- basis: commit diff (python/sprack/__init__.py: `not_followed`, `catalog-{stamp}-{corner}.json`). INFERRED: the toy manifest shape (copied from test_pdk_env_reserved_params) and device names.

### 4885e7a8 — a catalogue with no target collects every dialect's reserved names [PARTIAL: (b), env-only today]
- from: ngspice   to: none (catalogue)
- input `models.lib` for `sprack catalog --from ngspice models.lib`:
  ```
  * toy
  .param vt=0.4
  .model nch nmos level=54 vth0={vt}
  ```
- expect: stdout JSON `"env":{…}` contains `"params":["vt"]` and `"family_of":{"nch":"bsim4"}`. And the simplest fix of the gap: rename py:test_pdk_env_reserved_params so the runner's `test_pdk_` skip does not catch it; it asserts `.param x={2*vt__p}` in the Circuit's Xyce netlist and equality with `sprack project`'s lines.
- basis: commit diff (src/project.zig:712-717: `collectReserved` for every built-in grammar when there is no target; src/json.zig writeEnv), python/test_sprack.py runner at HEAD (lines 1361-1364 skip every `test_pdk_*` but test_pdk_errors without SPRACK_TEST_PDKS). INFERRED: the JSON array/object text, which follows json.zig `keys`/`names` and was not run.

### 52e5c576 — a reserved-name rename skips every probe's arguments [PARTIAL: (d)]
- from: ngspice   to: xyce
- input:
  ```
  t
  .param vt=3.5m
  V1 vt 0 1
  M1 vt vt 0 0 nch w=1u l=1u
  .model nch nmos level=1
  B1 a 0 v={vdb(vt)*vt}
  R1 a 0 1k
  .op
  .end
  ```
- expect: `.param vt__p=3.5m` and `B1 a 0 v={vdb(vt)*vt__p}` (the node inside `vdb()` keeps its name; the parameter outside is renamed); info "parameter 'vt' is written as 'vt__p'". A second line `B2 b 0 v={id(vt)}` with a device named `vt` should keep `id(vt)` likewise.
- basis: commit message ("parameter renames skip every probe, not only v() and i()"), existing test at tests.zig:5653-5661 for the `v(vt)` case. INFERRED: the exact output lines for vdb/id.

### 2c5c2b3f — `.op` beside one other analysis into Xyce is a caveat, not an error [PARTIAL: (b)]
- from: ngspice   to: xyce
- input:
  ```
  t
  V1 a 0 1
  R1 a 0 1k
  .tran 1u 1m
  .op
  .end
  ```
- expect: both `.tran 1u 1m` and `.op` written; 0 errors; one `warning[caveat]: line 5: op beside tran; Xyce 7.10 runs one analysis a netlist: of several it runs the last and leaves the others out without a message, and an .op beside another analysis is not run on its own`.
- basis: grammar at HEAD (grammars/xyce.spgrammar `unique analysis dc ac tran noise sp hb beside op : …`), src/writer.zig:2919-2934 (`uniqueAnalyses`), and the LTspice case of the same branch in "z2: more analyses than LTspice loads…". INFERRED: not run for Xyce.

### f2d3eb02 — a Circuit on a PDK sends the PDK's dialect as `defaults` [PARTIAL: (b), env-only today]
- minimal check (Python, toy PDK, no checkout): manifest as in test_pdk_env_reserved_params but `"dialect": "hspice"`; `c = sprack.Circuit("t", pdk=pdk); c.R("1", "a", 0, "1k"); c.op()`.
- expect: `c.netlist("xyce")` raises sprack.Unsupported containing `the circuit sets no temp or tnom; its PDK's simulator (hspice) assumes temp=25, tnom=25 and xyce assumes temp=27, tnom=27`; `c.netlist("hspice")` does not raise; after `c.options(temp=25, tnom=25)` `c.netlist("xyce")` does not raise.
- basis: commit diff (python/sprack/__init__.py: `doc["defaults"] = self.pdk.dialect`), the Zig test's message text. INFERRED: that a toy HSPICE-dialect PDK needs nothing else to build.

### a5aaafea — the plugin caveat is said once across streamed groups [PARTIAL: (d)]
- from: ngspice   to: xyce, through the streaming path with Env.provided `mosvar=mosvar.so`
- input:
  ```
  t
  .model cv mosvar type=-1
  N1 g b w cv l=1u
  .subckt s g b w
  N2 g b w cv l=1u
  .ends
  X1 g b w s
  N3 g b w cv l=2u
  .op
  .end
  ```
- expect: no crash; three `Ymosvar …` lines; exactly one `warning[caveat]` "device: the Verilog-A module 'mosvar' is the plugin mosvar.so: run xyce with -plugin mosvar.so" for the file.
- basis: commit message and diff (writer.zig: `plugins_said.put(w.perm, …)`, "it was freed between streamed groups"). INFERRED: what makes a new streamed group (a subcircuit between the instances is a guess); run the fixture under the testing allocator so a use-after-free is caught.

### 9cec7da6 — the provided-family caveat survives the second file of a project [PARTIAL: (e), env-only today]
- from: hspice   to: ngspice (and vacask), `project` with `provided = bsimcmg=/m/bsimcmg.osdi`, library mode, two top files
- input: `a.pm`: `.model n1 nmos level=72 version=107`; `b.pm`: `.model p1 pmos level=72 version=107`
- expect: no crash; 0 errors; the log holds "written for the module /m/bsimcmg.osdi given to the translation" exactly twice (once a file); `a.pm` out has `.model n1 bsimcmg devtype=1`, `b.pm` out `.model p1 bsimcmg devtype=0`. With nothing provided: 2 errors "has no built-in bsimcmg".
- basis: the env-gated test "#53: ASAP7 into ngspice and VACASK: 24 errors, or with the module given 0 and one caveat a file" (same assertions on ASAP7's three files), commit diff (writer.zig perm arena). INFERRED: counts for the two-file toy.

### 9cec7da6 — JSON env `"provided"` is read; the manifest's `provide` reaches the netlist [PARTIAL: (f), (g), env-only today]
- from: JSON (`sprack write --to ngspice`)   to: ngspice
- input: `{"title":"t","dialect":"hspice","stmts":[{"kind":"model","name":"n1","family":"bsimcmg","type":"n","params":{"version":"107"}},{"kind":"op"}],"env":{"provided":{"bsimcmg":"/m/bsimcmg.osdi"}}}`
- expect: output has `.control\npre_osdi /m/bsimcmg.osdi\n.endc` and `.model n1 bsimcmg devtype=1`; 0 errors; with the `env` key removed, error "ngspice has no built-in bsimcmg … --provide bsimcmg=FILE".
- basis: commit diff (src/json.zig parseEnv `provided`; python `doc["env"] = {..., "provided": …}`). INFERRED: the JSON spelling of a model statement (`family`/`type`/`params` keys) — take it from `sprack read --from hspice` of `.model n1 nmos level=72 version=107` rather than from this sketch. For (f): a toy PDK manifest with `"provide": {"ngspice": {"bsimcmg": "$TOY_OSDI"}}` and an empty file at that path; `pdk.translate("ngspice")` log has the caveat once a file, and without the variable set raises Unsupported "ngspice has no built-in bsimcmg".

### c6a9e5fa — an erratum that names its file by basename applies in any layout [PINNED-ENV]
- from: ngspice   to: xyce   (project with errata; variant of project.zig's "errata: …" test)
- input: `in/lib.spice`: `* lib` / `.include "cells/r.spice"`; `in/cells/r.spice`: `* cell` / `.subckt rr a b` / `res a b rm r = 1k tc1r = 1m` / `.ends`; errata `[{"file": "r.spice", "was": "res a b rm r = 1k tc1r = 1m", "read": "Rres a b rm r = 1k tc1 = 1m", "why": "a switch to ngspice"}]`
- expect: 0 errors; `out/cells/r.spice` has `Rres a b 1k rm tc1=1m`; the log has `r.spice:3: warning[caveat]: read through an erratum of the PDK: …` once.
- basis: commit diff (sky130A.json: the erratum's `file` changed from a path to the bare file name "so it applies to both layouts"), project.zig "errata: …" test for the output text. Matching is by path suffix (src/project.zig:665 at HEAD, `endsWith(path, e.file)`), so a bare name matches; not run. The sky130 counts themselves (312 loss entries) can only be checked with the checkout.

## Themes

Each FIX commit carries one or two theme tags, so the counts add up to more than 205. "Not fully pinned" counts rows whose status is UNPINNED, WEAK, PARTIAL or PINNED-ENV.

| theme | fixes | not fully pinned |
|---|---|---|
| model-cards | 32 | 9 |
| includes-projects | 29 | 15 |
| limits-robustness | 25 | 5 |
| engine-grammar | 24 | 4 |
| json-python-cli | 24 | 9 |
| analyses | 21 | 7 |
| sources | 18 | 4 |
| report | 17 | 5 |
| options | 16 | 2 |
| expressions | 16 | 5 |
| devices | 14 | 4 |
| lexer-lines | 14 | 1 |
| case-spelling | 12 | 3 |
| instance-params | 10 | 4 |
| statistics | 10 | 2 |
| alters-sweeps | 9 | 3 |
| conditionals | 7 | 1 |
| subckt-params | 6 | 1 |
| control-output | 6 | 1 |
| topology | 5 | 2 |
| numbers-scales | 2 | 0 |

### model-cards (32 fixes, 9 not fully pinned)

Every simulator run turned up another card parameter or level that a target refuses or means differently, and each finding added a grammar directive (`noparam`, then `noparam ... warning|error`, `threshold`, `modelparams`, `only`, `when`, `computes`, `edge`, `provided`, `key>=n`). The precedence between them exists only as individual fixes: a `noparam` line decides over `only`, `level` is never refused, a card refused by one value has none of its other names checked, a parameter given twice keeps the last, a renamed model is declared under its new name. NARROW/SHORT took three passes (930214bc, ec87e566, 9b8f8e6b) and the VACASK version/level severity three (a3ecebbe, f2b17e4d, f9d7b423); the tables are hundreds of grammar lines that the tests only sample (no BSIM3 name is asserted for Xyce or VACASK, nor the BSIM3/BJT neutral-value rows).

Commits: 63f08969 062bcac0 074da563 ed4d2d96 c7063348 26ac2ce9 e48768eb b9dde6ee a3ecebbe 9df73320 f5562cc6 f2b17e4d 31b798ca 59389682 ec87e566 9a38cfa6 c6e51fc1 7124d40e 9b8f8e6b 9ac764e9 3cf2965a 9d810cc3 b8c048f7 0522e2bd 6b384c4d de7005fe c91655cf f9d7b423 a5aaafea 9cec7da6 c6a9e5fa 29f8d9a1

Not fully pinned: 63f08969 062bcac0 e48768eb c6e51fc1 b8c048f7 de7005fe a5aaafea 9cec7da6 c6a9e5fa

### includes-projects (29 fixes, 15 not fully pinned)

Cache validity was discovered one input at a time (a changed source file, concurrent writers, the manifest, every file read, `$NAME` values, a grammar file's hash, the corner, the build of the core, a plugin file), and so were section following and path resolution (`--section`, sections named by followed `.lib` lines, a library given itself, `libsections opened`, `-D` variables, `.option search`, Windows roots). The logic is split between src/project.zig and python/sprack/__init__.py. Half of these fixes are held only by Python tests that skip without a PDK checkout: the runner skips every `test_pdk_*` name, including toy-PDK tests that need no checkout.

Commits: cc1a6e08 0d842dba ed4d2d96 6f45950a 60c1eb72 ce8ed481 3cdf3fdc f5562cc6 2750ce0b a0250214 27abcb20 89b8cb17 462d1aae cb8baf8a 5d1ac5a3 e053e123 009bbd04 9ca39691 ed0f1db0 b824243c 88e29b3f 2060a289 7691f313 c98724b5 692d2f56 2a2e10c5 4885e7a8 9cec7da6 c6a9e5fa

Not fully pinned: cc1a6e08 0d842dba 60c1eb72 ce8ed481 3cdf3fdc 009bbd04 9ca39691 ed0f1db0 2060a289 7691f313 692d2f56 2a2e10c5 4885e7a8 9cec7da6 c6a9e5fa

### limits-robustness (25 fixes, 5 not fully pinned)

Fuzzing found recursion and unbounded-size crashes one at a time (grammar nesting, define expansion, the match stack, nameless statements, block and JSON depth, a signal call past the token window, lost report entries on OOM) and each got a limit with a diagnostic. The memory work (sparse slots, line-at-a-time lexing, streaming) is held by one bound test (peak at most 0.8x the input) and by stream-equals-whole comparisons. Most pins are no-crash runs over fixed corpora; the stream path's absolute output, its fall-back reasons and the CLI's own memory use are asserted nowhere.

Commits: 603d7d06 6d381c30 d4d6a338 b490b0d8 dc34e36e 872a7de6 6f45950a fa412a94 4b11f9ab f9ea7cf1 a8436bc2 70fb1771 e8f29c25 012fa25e 3f47bcf0 a4349767 ded3032f d7bf89c1 ddd12030 82ecaa9e a063a34c da5b074c e0f46280 a2c0a524 652fd5e4

Not fully pinned: 872a7de6 d7bf89c1 82ecaa9e e0f46280 a2c0a524

### engine-grammar (24 fixes, 4 not fully pinned)

The .spgrammar language gained a directive or pattern operator for nearly every dialect fact (define, repeated groups, merge, needs, convert in four forms, invalid, differs, slot#1, slot#other, raw, k==lit!@s:a, $+list, rule kind[family], params, default, unique, reserved, switch, spread, noparam, requires, preamble unless, quotes expr-in-values, means, own, inert, omitted, libsections, provided, when), and several fixes are interactions between them (a matrix after a fixed key, required keys before a move, the wildcard only as a capture). Behaviour is pinned through dialect tests, not per directive, so the rewrite needs the directive list with its semantics as a spec of its own. Grammar-file errors (`path:line: message`) and the compile limits are pinned by exact text.

Commits: 525d29d2 b1931bc9 186dda8a 211ec795 208dae35 68025e67 7d73f491 fc64e233 50285205 a7cdc5c8 47a1ccba 7e4e7073 f182921e 4b11f9ab f9ea7cf1 a8436bc2 012fa25e 3f47bcf0 79a57dfa 46ebf5c8 5488267e fa7180a9 57c9ee53 43466f7a

Not fully pinned: 68025e67 50285205 a7cdc5c8 fa7180a9

### json-python-cli (24 fixes, 9 not fully pinned)

Every field added to the IR later (a statement's dialect, folds_case, the env's models, functions, conditional subcircuits, params, family_of and modules, defaults, provided) needed a follow-up fix to cross JSON and the Python builder (4885e7a8 is "the JSON form holds every field"), and read-then-write had to be made equal to translate after the fact (a4349767). CLI exit codes and stderr text are pinned by cliTests, but what was added late has no case: `--provide`/`--xyce-plugin`, `--errata`, SPRACK_WHOLE, SPRACK_STREAM_WHY, an input that is no regular file or is over 1 GiB.

Commits: 186dda8a cc1a6e08 3bcb97fc 144d7577 588cb36f 0d842dba 872a7de6 70fb1771 a4349767 f4b98c5d 9b4d220c d7bf89c1 462d1aae e053e123 7e898c16 e05a0076 ed0f1db0 d875ee84 08cce97f de7005fe 7691f313 4885e7a8 f2d3eb02 652fd5e4

Not fully pinned: cc1a6e08 0d842dba 872a7de6 d7bf89c1 ed0f1db0 de7005fe 7691f313 4885e7a8 f2d3eb02

### analyses (21 fixes, 7 not fully pinned)

Positional numbers and paired statements mean different things per dialect: HSPICE `.ac` followed by `.noise`/`.lin`/`.lstb` is one analysis, the extra numbers of `.tran` were reinterpreted three times (segments, start time, step ceiling as `.option delmax`: e30a214b, b0382fd6, 284f713a), `.pz`/`.tf`/`.noise` outputs switch between node pairs and signals, and ic, nodeset and options move onto analyses. The late findings are per-target limits (one analysis a deck in LTspice and Xyce, one noise node in Xyce) reported as an error on each statement. Unpinned leftovers are whole forms nobody asserted (HSPICE `.phasenoise`, Spectre psp/envlp/qpss text, a VACASK multi-tone hb line, reading ngspice's noise interval).

Commits: b1931bc9 66c431f7 a57bbdce 68025e67 04b5199f b855300c 2ddd4b02 f8a16163 308545c3 2f0d2eb2 e30a214b b0382fd6 08b1fb58 d6a25691 be7bbaac 291ce19b 46a1e047 603dda27 ea0de603 2c5c2b3f 937a8bab

Not fully pinned: a57bbdce 68025e67 04b5199f b855300c 2ddd4b02 e30a214b 2c5c2b3f

### sources (18 fixes, 4 not fully pinned)

The recurring bug is a value left out (or given as 0) that the source simulator fills in its own way: a pulse's rise, fall and width, an EXP's td1/tau1/td2/tau2 (four passes: de07dfb3, 284f713a, 51c48de6, 6d7d5ed6), SFFM order and defaults, a bare `ac`, a SIN with no frequency, a PWL's repeat. Each crossing needs the source's meaning, the target's meaning, a `.tran` to take the value from and an error when there is none. The answers changed as simulators were measured, so the exact numbers in the tests (`1a`, `23500p`, `wrote 2n`) are the specification.

Commits: 525d29d2 208dae35 062bcac0 b6567bf5 c9ba088a b1c81f8d dc1035a5 ce7b69d6 9a91157f de07dfb3 284f713a 51c48de6 42c1435a ff60377b b31b70ba 21aef6d1 6d7d5ed6 10d44925

Not fully pinned: 062bcac0 b6567bf5 c9ba088a b1c81f8d

### report (17 fixes, 5 not fully pinned)

Report text, code, severity and count are contract: fixes turned errors into warnings or infos, folded repeats into one entry a file, put an entry on each analysis at its own line, and removed double reporting where both grammars have an `invalid` line. The once-a-file keys broke under streaming and multi-file projects (a5aaafea, 9cec7da6: the key was freed between groups and files). Several caveat lines that exist in the grammars are asserted by no test (VACASK point counts and the save caveat, five `differs` rows).

Commits: e4d1269f 0b2454b6 a7cdc5c8 e700e490 26ac2ce9 308545c3 2f0d2eb2 f2b17e4d da5b074c 40420079 2b8503cc be7bbaac 291ce19b 2768ed66 c838d073 2a2e10c5 ea0de603

Not fully pinned: e4d1269f a7cdc5c8 e700e490 2768ed66 2a2e10c5

### options (16 fixes, 2 not fully pinned)

One vocabulary is filed differently per target (Xyce's packages, analysis parameters in Spectre and VACASK, HSPICE's delmax, reli and gmindc), so the fixes are about aliases that collide, a move onto an analysis the netlist has not, defaults that differ silently (temp and tnom), options that change no result, and an options line left with nothing on it. Well pinned, mostly by one long test ("options: one vocabulary, five ways of filing it") and the c5 tests.

Commits: 144d7577 0b2454b6 8dfb488a e30a214b 3c8d51ed 353e097d ddd12030 284f713a 5765a544 46a1e047 31b01a3e 7b4f8023 4a9bcc85 cb2b3910 f2d3eb02 5bd9ba72

Not fully pinned: e30a214b f2d3eb02

### expressions (16 fixes, 5 not fully pinned)

Functions and operators of the same name differ per dialect (the base of log, `^` as xor, pwr, nint, int, the form of a choice, `!=`), handled by per-dialect tables with `differs` caveats and `means` rewrites; delimiter handling (`{a} + b`, quoted values as expressions) was fixed repeatedly. What is unpinned is table rows: HSPICE's atan2/hypot/fmod/asinh (the one fully UNPINNED commit), Xyce's fmod/db, five `differs` rows and the oneway note of a rewritten choice.

Commits: 63f08969 7d73f491 04b5199f 33dfc935 3f81c5a6 2425e6f1 68c96bb2 fe08b98a 971f28c4 90e7eb32 9a91157f c82c47e2 0167eeb0 f23e7426 8dfad872 52e5c576

Not fully pinned: 63f08969 04b5199f 33dfc935 3f81c5a6 52e5c576

### devices (14 fixes, 4 not fully pinned)

A device's kind, letter and form depend on its model card (lossy lines, MESFET/HFET, PSP103 N devices, Verilog-A Y lines, HICUM's thermal node, an inductor's master), and the card may be in another file, so fixes kept widening what the environment carries (family_of, modules). The cross-file plugin case (692d2f56) and several minor forms (trrandom, VCCAP, pvcvs, pacmag/fundname as slots) have no test.

Commits: 211ec795 c7063348 fc64e233 c9ba088a b1c81f8d 59389682 9a38cfa6 7124d40e 5feb4d93 c838d073 6b384c4d 692d2f56 937a8bab a5aaafea

Not fully pinned: c9ba088a b1c81f8d 692d2f56 a5aaafea

### lexer-lines (14 fixes, 1 not fully pinned)

Where an undelimited value ends was fixed eight times (a bare call after `=`, blanks around operators, a sign after a blank, a stray `+`, choice operators, `%` and `\` after a blank, a comma, a bracketed value), each as a dialect-flagged lexer rule; the rest are continuation markers, quotes as expressions, several statements on one line and a language switch mid-file. Nearly all pinned by exact output; the single-backslash HSPICE continuation is not.

Commits: ae35fa60 616e975f 2425e6f1 5488267e bd8c7d2e fe08b98a 6a6c84b8 971f28c4 ded3032f 644173cd b824243c f23e7426 7b4f8023 59288756

Not fully pinned: ae35fa60

### case-spelling (12 fixes, 3 not fully pinned)

Name spelling was redone four times (keywords out of the table ba6f84d1, names kept from expressions ec4c9ae5, one spelling per kind d36f98fc, probe argument spaces 52e5c576), and each rename (a model as `name__m`, a reserved parameter as `name__p`) had to be chased into every place a name can occur: sweeps, data columns, alters, probes, other files of a project, a Python circuit's own devices. There is no symbol table, so every new reference site was a new fix; an alter's parameters and the probes other than v() are still unasserted.

Commits: 588cb36f ba6f84d1 46ebf5c8 9ba3ead4 44cb89d2 ec4c9ae5 68c96bb2 31b798ca c82c47e2 d36f98fc ba6a0908 52e5c576

Not fully pinned: 9ba3ead4 ba6a0908 52e5c576

### instance-params (10 fixes, 4 not fully pinned)

Per-dialect instance parameter tables (rename, loss, m>0, open or closed) were added target by target as each was measured (Xyce, Spectre, VACASK's `$mfactor`, LTspice 26.0.2), with special crossings that synthesize devices (a capacitor's ic= and q= into VACASK). HSPICE as the target, the info[rename] entry itself and what `sprack info` offers for an open table are unasserted.

Commits: b6567bf5 e2d0d41d 137d6f02 2f496077 c6e51fc1 42c1435a 5feb4d93 21aef6d1 5bd9ba72 35d5a78f

Not fully pinned: b6567bf5 e2d0d41d 137d6f02 c6e51fc1

### statistics (10 fixes, 2 not fully pinned)

Random functions and statistics blocks are lowered both ways with synthesized names (`sprack_rv_*`), and `dev/gauss` collided with the duplicate-parameter check and with reserved names; a Monte Carlo run is a `spread` over the analyses with a form per target. Of the four `lot|dev / gauss|unif` forms only `dev/gauss` is asserted.

Commits: 79a57dfa 472d4b47 b9dde6ee 9ba3ead4 82ecaa9e 40420079 2b8503cc 1d6edd7a b31b70ba a4e6005a

Not fully pinned: 9ba3ead4 82ecaa9e

### alters-sweeps (9 fixes, 3 not fully pinned)

Alters and sweeps are whole-netlist rewrites whose order matters: assumed defaults go in before the alters are laid out, renames reach into alter and data tables, a step needs an analysis to repeat. The refusal paths (an alter that changes a device into ngspice or VACASK, any alter into LTspice or CDL) and the rename of an alter's parameter are unpinned; VACASK's point-count caveats too.

Commits: 47a1ccba 7e4e7073 f182921e 269c3d7b e700e490 168c6032 1e288c33 3c8d51ed ba6a0908

Not fully pinned: e700e490 168c6032 ba6a0908

### conditionals (7 fixes, 1 not fully pinned)

Three mechanisms were stacked: branches of the same statements merged into conditional values (s1), a subcircuit written once for each branch with each instance picking one (v1), then constants and values passed down from a parent (#41), with the environment carrying conditional subcircuits across files, streams and JSON. The reason text of every case that cannot be merged or split is asserted exactly; well pinned.

Commits: a1afc9a4 644173cd 0167eeb0 d583b921 e05a0076 009bbd04 09d399a0

Not fully pinned: 009bbd04

### subckt-params (6 fixes, 1 not fully pinned)

Spectre's single `global 0 ...` line, a parameter defined twice in one scope, and a subcircuit's inner parameters hoisted onto the Xyce header with their instances' `params:`. The plain HSPICE-to-Spectre duplicate-parameter error is asserted only by a substring.

Commits: 8ec3ca62 e48768eb 90e7eb32 ece9d9a8 d583b921 09d399a0

Not fully pinned: e48768eb

### control-output (6 fixes, 1 not fully pinned)

Control blocks became typed scripts (#50) and dialect-only statements the typed kinds `native` and `embed` (#51); print, plot, measure and fft forms map per target with losses that give the grammar's reason. #50 removed the only assertion of the raw-block "(and N more lines of it)" message, which no built-in dialect reaches now.

Commits: 50285205 8dfb488a 4a9bcc85 57c9ee53 43466f7a 08cce97f

Not fully pinned: 50285205

### topology (5 fixes, 2 not fully pinned)

Severity per target comes from the grammars' `requires` lines, gated by the analyses present; the fixes after the first were all about false alarms (no analysis, a UIC transient, a deck of the target's own statements, unknown cells, ports, alters, conditionals) and about loops through subcircuit instances. Most cells of the dialect-by-rule severity table are asserted by no test.

Commits: 70be96f3 22ed612f 08b441a9 dcc4c7d7 bb7e3d2b

Not fully pinned: 70be96f3 22ed612f

### numbers-scales (2 fixes, 0 not fully pinned)

Strict numbers (`version=3.3.0` is a word, not a number) and exact decimal arithmetic wherever a value is computed (`23500p`, `1a`, `500n`); pinned through the tests of the features that use them.

Commits: 8ec3ca62 51c48de6

## What the test suite itself will not carry across a rewrite

These are not single fixes but properties of how the fixes are pinned today. Each one can make a
PINNED row stop being pinned once the engine changes.

1. **Pins that live inside the modules being replaced.** 26 unit tests sit in src files other than
   tests.zig and call internal functions: expr.zig (5: argSpace, condition evaluation, the two-table
   expression mapping, the form of a choice, exact convert arithmetic), project.zig (7: Windows path
   rules through `rootLenOn`/`resolveOn`/`normalizeOn`/`varValue`, errata, a non-regular include,
   `libsections opened`, the small project), json.zig (3: IR round trip, env declarations, every Env
   field), lexer.zig (4: the M trap, lines/comments/continuation, Spectre tokens, odd scale factors),
   grammar.zig (2), ir.zig (2), schema.zig (1), stats.zig (1), capi.zig (1). They pin c98724b5,
   9ca39691, 88e29b3f, 2060a289, e0f46280, 0167eeb0, 4885e7a8, 462d1aae, 52e5c576, 3f81c5a6 and
   others. They must be ported as behaviour tests, or their fixes become unpinned.
2. **The stream path is compared only with the whole-netlist path.** "a stream writes what the
   whole netlist does" asserts that the two paths agree, not what either writes. If the rewrite has
   one path, the absolute output of `stream_deck` (merged `.option` lines, topology entries for two
   islands, dev/gauss and agauss lowering, into five targets) is pinned by nothing. Capture it as
   golden text from the HEAD binary first (see the d7bf89c1 fixture).
3. **Generic sweeps depend on introspection.** "every pair of dialects: write, read back, same
   circuit, no errors", "every `no` line: the kind is an error in that dialect, and the reason is the
   grammar's", "caps: every kind has a rule, a place or a reason in every dialect", "every kind,
   every slot, every dialect: written without a crash, and the JSON is the statement" and "each
   grammar file compiled at run time is the grammar compiled into the binary" walk the compiled
   grammar tables. They pin many rows at once (a4349767, 5765a544, c838d073, ea0de603) and need the
   same enumeration API from the new engine. "every `no` line" skips the kind `alter`.
4. **Python tests skipped by name.** The runner skips every `test_pdk_*` function except
   `test_pdk_errors` unless SPRACK_TEST_PDKS is set. `test_pdk_env_reserved_params` builds a toy PDK
   and needs no checkout, yet is skipped with the rest, so 4885e7a8 (b) is undefended in a default
   run. Toy-PDK tests named `test_tiny_pdk_*` do run.
5. **Env-gated pins.** PINNED-ENV rows and the env-only letters of PARTIAL rows (0d842dba g,
   e2d0d41d e, 2060a289 e, 2a2e10c5 d, f2d3eb02 b, 9cec7da6 e-g, 60c1eb72, ce8ed481, c6a9e5fa,
   ed0f1db0) are checked only with PDK checkouts, installed simulators or a Windows host. One Zig test
   is gated the same way ("#53: ASAP7 into ngspice and VACASK ..." returns SkipZigTest without
   SPRACK_TEST_PDKS), and project.zig's non-regular-include test runs on Linux only.
6. **Command-line surface with no case.** `--provide`/`--xyce-plugin` (de7005fe, 6b384c4d),
   `--errata` (2060a289), SPRACK_WHOLE and SPRACK_STREAM_WHY (d7bf89c1), an input that is no regular
   file or exceeds 1 GiB (e0f46280), a `$NAME` that does not lead an include path (7691f313), a
   library given itself with no `--section` (2a2e10c5).
7. **Exact report text is the contract.** Most PINNED rows are pinned by the literal message
   (`<kind>.<slot> = <value> has no spelling in <dialect>: <grammar reason>`, `model '<n>': <key> not
   written: ...`, `... and N more ...`), by its code and severity, and by its count (one a file, one
   per card, one on each analysis). A rewrite that words, counts or orders entries differently fails
   those tests without having regressed a behaviour, and one that keeps the tests green by loosening
   them loses the pin.
8. **Grammar data is sampled, not covered.** The largest behavioural surface is data in the seven
   .spgrammar files (parameter tables, `noparam`, `differs`, `requires`, `invalid`, `no ... : reason`
   lines). Only the slot-level and kind-level `no` lines are checked exhaustively; the instance and
   model parameter tables, `differs` rows, topology severities and caveat lines are asserted by
   sample. Keeping the grammar files byte-identical through the rewrite, and diffing the corpus audit
   output against the HEAD binary, defends these better than new unit fixtures can.


## Cross-check: the 46 issue patches of 2026-11-24 and the three follow-ups

| hash | issue | class | status | subject |
|---|---|---|---|---|
| 5feb4d93 | #28 | FIX | PINNED | a capacitor's ic= and q= cross into VACASK as other devices (#28) |
| 9ac764e9 | #30 | FIX | PINNED | a diode card of ngspice's level 3 is an error into Xyce (#30) |
| 3cf2965a | #31 | FIX | PINNED | a model card's level by its version or by its instances' terminals (#31) |
| 9d810cc3 | #32 | FIX | PINNED | resistor and capacitor cards: ngspice's other names, and Xyce's cards take only theirs (#32) |
| b8c048f7 | #33 | FIX | PARTIAL | card parameters into Xyce: every name its device declares, the rest a loss (#33) |
| ba6a0908 | #34 | FIX | PARTIAL | Xyce's reserved names in sweeps, data columns and alters; temper and hertz shadowed (#34) |
| 88e29b3f | #35 | FIX | PINNED | a library copied for one section loads in ngspice: the others' includes are comments (#35) |
| 2768ed66 | #36 | FIX | PARTIAL | the report says what crosses: dropped blocks, text in another syntax, lines written back (#36) |
| e0f46280 | #37 | FIX | PARTIAL | limits: inputs that are no regular file or too large, and blocks nested over 100 deep (#37) |
| 46a1e047 | #38 | FIX | PINNED | VACASK: a transient's start, a node pair in noise and dcxf, gshunt, and dcxf's sources (#38) |
| 8dfad872 | #40 | FIX | PINNED | a function the target lacks is written as what the source means by it; pwr into VACASK (#40) |
| 09d399a0 | #41 | FIX | PINNED | a subcircuit written once for each branch: constant values, and values passed down from a parent (#41) |
| 31b01a3e | #39 | FIX | PINNED | options that change no result are not errors: noacct, klu, a method with no transient (#39) |
| 2060a289 | #42 | FIX | PARTIAL | pdk: errata in a manifest for lines the PDK's own simulator refuses (#42) |
| 7b4f8023 | #43 | FIX | PINNED | reader: ngspice forms ngspice 45 takes (#43) |
| 4a9bcc85 | #44 | FIX | PINNED | writer: small forms a target has (print all, .plot, hb harmonics, maxord) (#44) |
| 603dda27 | #45 | FIX | PINNED | reader: HSPICE analysis forms of kinds the schema has (#45) |
| b31b70ba | #46 | FIX | PINNED | reader: HSPICE element variation, port, pattern and data forms (#46) |
| 57c9ee53 | #47 | FIX | PINNED | schema: HSPICE statements with no kind get one or a reason (#47) |
| 0522e2bd | #48 | FIX | PINNED | models: ngspice MOS levels 4, 5, 6, 9, 55-57, 1040 and MESA get families (#48) |
| c838d073 | #49 | FIX | PINNED | vacask: an S-parameter port's loss says how to rebuild it (#49) |
| 43466f7a | #50 | FIX | PINNED | reader: an ngspice .control block is a script of statements (#50) |
| 08cce97f | #51 | FIX | PINNED | python: dialect-only statements, embedded files and measures are typed (#51) |
| 6b384c4d | #52 | FIX | PINNED | xyce: a PDK's Verilog-A modules through plugins named on the command line (#52) |
| de7005fe | #53 | FIX | PARTIAL | models: a family a dialect has only as a module given to the translation (#53) |
| 7691f313 | #54 | FIX | PARTIAL | cli: audit's status says a silent difference; -D paths start where sprack runs (#54) |
| c98724b5 | #55 | FIX | PINNED | windows: $NAME in any case, path rules tested on every host, an ARM64 tag (#55) |
| bd8a61ef | #56 | BUILD | - | measure: HSPICE decks for the checks that have no row yet (#56) |
| c3c652e2 | #57 | BUILD | - | measure: Spectre decks for the checks that have no row yet (#57) |
| 7645d22a | #59 | BUILD | - | corpus audit: each deck in its declared dialect, error-case decks apart (#59) |
| 5e36bd62 | #60 | BUILD | - | corpus audit: LTspice and CDL are targets too (#60) |
| 692d2f56 | #61 | FIX | PARTIAL | tests: a harness that compares each PDK device across simulators (#61) |
| 15c9f2d5 | #62 | BUILD | - | ci: format, the pages' examples and the corpus audit on every pull request (#62) |
| 1f2db230 | #63 | TEST | - | tests: memory bounded and measured in the Python tests (#63) |
| a2c0a524 | #64 | FIX | WEAK | fuzz: JSON, grammar and include-tree targets, 64 KiB inputs, a nightly run (#64) |
| 4ff08583 | #65 | BUILD | - | coverage: zig build coverage with kcov, a Python line tracer, a floor per file (#65) |
| eb3cf6b2 | #66 | BUILD | - | release: metadata PyPI shows, and a bump that refuses a taken tag (#66) |
| 2a2e10c5 | #67 | FIX | PARTIAL | leftovers: streamed Python translate, one test run directory, a deck's sections alone, each invalid slot once (#67) |
| ea0de603 | #68 | FIX | PINNED | xyce: noise between two nodes is a loss that says why, with its row (#68) |
| a4e6005a | #70 | FIX | PINNED | spectre: a Monte Carlo run from HSPICE or Xyce varies the mismatch block too (#70) |
| 4885e7a8 | #71 | FIX | PARTIAL | env: the JSON form holds every field, so a circuit on a PDK renames as its library (#71) |
| 52e5c576 | #72 | FIX | PARTIAL | reader: names in probes and function arguments keep their own spellings (#72) |
| 21aef6d1 | #73 | FIX | PINNED | ltspice: a PWL's repeat, Rser, Cpar and load are slots (#73, in part) |
| ff014f85 | #74 | TEST | - | tests: a requires line's analysis list is exercised again (#74) |
| 6d7d5ed6 | #75 | FIX | PINNED | exp: a TAU2 that plays no part is written as the step where it must be said (#75) |
| c91655cf | #76 | FIX | PINNED | small items: HSPICE's floor resistance, Xyce's inductor multiplier, stdin, Rule.line (#76) |
| cb2b3910 | - | FIX | PINNED | writer: an options statement none of whose values cross is not written |
| f9d7b423 | - | FIX | PINNED | vacask: sp_bjt has no level parameter |
| 2c5c2b3f | - | FIX | PARTIAL | xyce: one analysis a netlist; the others are errors that say so |

Of these 49 commits: FIX 40, BUILD 7, TEST 2. Status of the FIX ones: PINNED 27, PARTIAL 12, WEAK 1. No subject cites #29, #58 or #69 (#69 is named in the body of a5aaafea); #31, #43, #52, #53, #56, #57, #65 and #73 have a second commit on 2026-11-26 (f2d3eb02 and 18ce4909, 937a8bab, a5aaafea, 9cec7da6, 10d44925, 5bd9ba72, 0ea3e599, 35d5a78f), and the tests of 9cec7da6 are titled #27.

## Appendix: the 113 commits that are not in the ledger

| hash | date | class | note |
|---|---|---|---|
| b57ccfe4 | 2026-11-14 | BUILD | MIT LICENSE restored; Zig test workflow |
| 91e25dae | 2026-11-14 | BUILD | flake pins Zig/zls; CI through nix develop |
| 49874cf0 | 2026-11-14 | DOCS | PLAN.md added |
| 3797341b | 2026-11-14 | BUILD | pyproject + in-tree PEP 517 wheel backend |
| a430f8ee | 2026-11-14 | TEST | adds capi.zig `C ABI: dialects, translate, report, free` (pins the C ABI of the initial import); wired into `zig build test` |
| b7e1ac94 | 2026-11-14 | BUILD | CI builds and tests the wheel |
| b5ce0b42 | 2026-11-14 | MERGE | merge of 3797341b, a430f8ee, b7e1ac94 |
| 55a1398b | 2026-11-14 | DOCS | PLAN.md ticks |
| 65fe97a1 | 2026-11-14 | BUILD | flake verify shell (simulators, PDKs, suite) |
| e94535ce | 2026-11-14 | BUILD | Tests workflow runs PDK tests |
| 030e282a | 2026-11-14 | DOCS | docs/verification.md VACASK findings |
| 50255db0 | 2026-11-14 | MERGE | merge main into worktree branch |
| ab07f9d2 | 2026-11-14 | BUILD | build.zig links libc into the Python extension (without it the first file read segfaults); only the env-gated PDK python tests exercise it |
| 6ca09401 | 2026-11-14 | TEST | py PDK tests join `\n+ ` continuation lines before matching paths (`unwrap`) |
| ceaeb491 | 2026-11-14 | BUILD | nightly corpus audit vs baseline tsv |
| 71529684 | 2026-11-14 | MERGE | merge (CI/flake conflicts) |
| 6b7e02ad | 2026-11-14 | MERGE | merge of 525d29d2, b1931bc9, 66c431f7, a57bbdce |
| 5cddfaf2 | 2026-11-14 | DOCS | PLAN.md; .gitignore |
| dfcb96f1 | 2026-11-14 | TEST | py dialect lists gain ltspice, cdl (espice then): test_translate, test_build_every_dialect, test_vocabulary_is_closed |
| 4911b61c | 2026-11-14 | BUILD | `zig build py` ships the self-contained package |
| c36a63f4 | 2026-11-14 | TEST | py test_pdk_asap7 expected error text updated |
| d5865658 | 2026-11-14 | DOCS | README test count |
| 4c094e74 | 2026-11-14 | DOCS | docs/verification.md grammar findings |
| 0c187402 | 2026-11-14 | MERGE | merge (docs only) |
| da84dcaa | 2026-11-14 | MERGE | merge origin/main |
| 45e26f08 | 2026-11-14 | BUILD | wheel CI sets SPRACK_GRAMMARS for the copied test file |
| 85f66e7d | 2026-11-14 | BUILD | flake Python bundle for five platforms; Windows import lib (pyext reads PyExc_ValueError via `__imp_`) |
| 6522ef35 | 2026-11-14 | BUILD | tools/gen_bench.py |
| d5b727eb | 2026-11-14 | DOCS | PLAN.md |
| c6d662f4 | 2026-11-14 | DOCS | verification.md marks findings fixed; audit tsv refreshed; src changes are `zig fmt` whitespace only |
| ea9d0b45 | 2026-11-14 | BUILD | verify shell builds VACASK b2c1551; nightly load check |
| 0985bd22 | 2026-11-14 | BUILD | tools/licensed_check.py |
| d6aab22d | 2026-11-14 | DOCS | PLAN.md |
| 4ea34932 | 2026-11-14 | BUILD | tools/parse_check.py |
| 9b164d1d | 2026-11-14 | BUILD | tools/pdk_smoke.py |
| c63b0150 | 2026-11-14 | BUILD | tools/sim_check.py; parse/sim check results tsv |
| 448ea27c | 2026-11-14 | DOCS | parse/sim check result tsv |
| 9c282775 | 2026-11-14 | BUILD | wheel platform tags from the Zig target; sdist |
| c03a59a7 | 2026-11-14 | TEST | adds 10 `gap:` reproducers (then skipped; all run at HEAD, pinning ae35fa60, e48768eb, 3cdf3fdc, 616e975f, 2425e6f1, b1c81f8d, 68c96bb2): `gap: an unquoted function call is a value in an HSPICE .param`, `gap: HSPICE coupling written with k=`, `gap: function definitions and values in one HSPICE .param`, `gap: a $ comment after a backslash-continued HSPICE expression`, `gap: ngspice .func with several arguments needs commas`, `gap: Spectre user functions`, `gap: binned HSPICE models become one Spectre model group`, `a subcircuit named like the model its transistor uses` (renamed from `gap: ...` by 68c96bb2), `gap: a parameter defined twice`, `gap: a project keeps Verilog-A sources and section spellings` |
| 2d77f091 | 2026-11-14 | DOCS | PLAN tick + audit baseline |
| 494c5aaa | 2026-11-14 | TEST | closing brace for `gap: a project keeps Verilog-A sources and section spellings` (rebase join) |
| 6929e892 | 2026-11-14 | BUILD | tools/licensed_check.py --jobs |
| 0274a173 | 2026-11-14 | TEST | `gap: Spectre user functions` now asserts the written text `real f(real x) {\nreturn (x*w)\n}` for an HSPICE `.param f(x)='x*w'` inside a subcircuit |
| e57e2198 | 2026-11-14 | DOCS | README directive reference; audit baseline |
| a3e01188 | 2026-11-14 | TEST | PLAN/README + py `test_pdk_sky130`, `test_pdk_gf180mcu` expectations after statistics (env-gated: SPRACK_TEST_PDKS) |
| ca078094 | 2026-11-14 | BUILD | zig fmt of grammar.zig (one blank line) |
| b0f29b83 | 2026-11-14 | DOCS | README directives; audit baseline |
| b54465f8 | 2026-11-14 | BUILD | tools/sim_check.py: VACASK noise units |
| 050908cf | 2026-11-14 | BUILD | tools/sim_check.py: VACASK one-point DC sweep |
| 9ff59d5e | 2026-11-14 | DOCS | audit/parse/sim tsv after VACASK fixes |
| 3e39def8 | 2026-11-14 | DOCS | PLAN phases ticked |
| 242cf3cb | 2026-11-14 | DOCS | audit tsv after insensitive=yes |
| ef8558cc | 2026-11-14 | DOCS | audit tsv after alters and SWEEP |
| 99131da8 | 2026-11-14 | DOCS | parse/sim tsv, vacask rows |
| fe506ee4 | 2026-11-14 | DOCS | audit tsv after topology; PLAN 6.2 |
| 03dbea62 | 2026-11-14 | DOCS | audit tsv, topology on alters |
| f344c39e | 2026-11-14 | DOCS | audit tsv after c4 |
| db87b8b1 | 2026-11-15 | DOCS | audit tsv after c5 |
| 202982c1 | 2026-11-15 | DOCS | audit tsv after d1 |
| 30d7f8bb | 2026-11-15 | DOCS | audit tsv after d2 |
| b2d487fc | 2026-11-15 | DOCS | audit tsv after c6 |
| 0ed40386 | 2026-11-15 | DOCS | audit tsv after e1 |
| b53d6fff | 2026-11-15 | DOCS | audit tsv after d3 |
| badb5afe | 2026-11-15 | DOCS | audit tsv after g1 |
| c6444d34 | 2026-11-15 | DOCS | audit tsv after h1 |
| 0e030808 | 2026-11-15 | DOCS | PLAN/audit tables removed; baseline summary tsv |
| 2ac1c7c4 | 2026-11-15 | DOCS | README rewrite, mdBook site, publish workflows |
| 906cc28a | 2026-11-15 | BUILD | flake ltspice shell and batch runner |
| de4f6472 | 2026-11-15 | DOCS | PDK doc pages updated |
| 2b15ae62 | 2026-11-15 | DOCS | verification section 8, LTspice runs |
| 43802374 | 2026-11-15 | DOCS | verification 8.6, LTspice load results |
| d33c4bbb | 2026-11-15 | DOCS | LTspice docs; runner lock in tools |
| 78d60eb0 | 2026-11-15 | TEST | adds "a stream writes what the whole netlist does"; memory bound 11.6x → 0.8x |
| bac071a9 | 2026-11-15 | DOCS | README/docs: measured translation memory |
| 48e966c5 | 2026-11-15 | DOCS | corpus baseline after noparam severity |
| 5367049d | 2026-11-15 | TEST | py test_netlist_leaves_the_circuit_as_it_is: a PDK model renamed `pm` → `pm__m` followed by the circuit's devices |
| 93c7aca8 | 2026-11-15 | DOCS | docs: PDK pages, caches, grammar-file dialects |
| af2cf896 | 2026-11-15 | DOCS | corpus baseline after s1 |
| 930214bc | 2026-11-15 | DOCS | docs: NARROW/SHORT measured |
| 2390bacf | 2026-11-15 | DOCS | corpus baseline after s2 |
| 6c52ea7b | 2026-11-15 | DOCS | README/PDK page: PDK table as measured |
| 77c6e0e4 | 2026-11-15 | TEST | dev/gauss and r1 tests read the xyce header form (`params:`) u1 now writes |
| 153313c5 | 2026-11-15 | DOCS | docs: a subcircuit for each branch, measured |
| d5ef6079 | 2026-11-15 | DOCS | README: IHP to Xyce is 37 |
| 5827e164 | 2026-11-15 | BUILD | wheel backend: Windows wheel cp310-abi3-win_amd64 |
| 855b904e | 2026-11-15 | BUILD | CI: wheel built and tested on Windows |
| 7c966ee1 | 2026-11-15 | DOCS | README/docs: the Windows wheel |
| f8d828ad | 2026-11-15 | BUILD | .gitattributes: LF checkout on every platform |
| a8bd31ed | 2026-11-15 | DOCS | corpus baseline after y1 |
| 2ed9552f | 2026-11-15 | DOCS | ltspice grammar comment and docs only: what the other MOS levels select in LTspice |
| f08beb2f | 2026-11-15 | DOCS | corpus audit baseline after z2 |
| dea1fa64 | 2026-11-15 | DOCS | corpus baseline after y2 |
| 2f837502 | 2026-11-15 | TEST | retargets every test that used ESPice to LTspice/VACASK/Xyce/ngspice/HSPICE (cutset `h1: a current cutset follows its own requires line: not under a UIC transient`, `c4: SFFM argument order, HSPICE and Xyce against ngspice`, `c4: ngspice .noise takes the summary interval`, `Schemify decks: paths, scopes, control blocks and XSPICE survive the JSON trip`, the e1 topology tests); ESPice-only assertions (.verilog, .alter read, island lines, EXP line) are dropped |
| 1e9494a3 | 2026-11-15 | DOCS | grammar comments only (hspice, vacask, xyce cite measurements, not ESPice) |
| 10601c40 | 2026-11-15 | DOCS | README and docs: seven dialects |
| bd8a61ef | 2026-11-24 | BUILD | HSPICE measurement decks (tools/measure/hspice), docs |
| c3c652e2 | 2026-11-24 | BUILD | Spectre measurement decks (tools/measure/spectre), docs |
| 7645d22a | 2026-11-24 | BUILD | corpus audit tools: declared dialect, own/other keys |
| 5e36bd62 | 2026-11-24 | BUILD | corpus audit tools: LTspice and CDL targets |
| 15c9f2d5 | 2026-11-24 | BUILD | CI: zig fmt, docs examples, corpus audit per PR |
| 1f2db230 | 2026-11-24 | TEST | py:test_memory: reading a 4 MB deck under 60x its size, 1,000 translations grow RSS under 4 MiB, PDK catalogue peak under 150 MiB (that part needs SPRACK_TEST_PDKS); 8 GiB address-space limit for the run |
| 4ff08583 | 2026-11-24 | BUILD | zig build coverage (kcov), Python line tracer, floors |
| eb3cf6b2 | 2026-11-24 | BUILD | release metadata; bump refuses a taken tag |
| ff014f85 | 2026-11-24 | TEST | "#74: a requires line with an analysis list checks only those analyses": pins topology `requires dc-path error [op dc ac]` — a capacitive island with only `.tran` gets no entry, with `.op` the error |
| 63285aaa | 2026-11-25 | DOCS | corpus baseline TSV after the 46 patches |
| 18ce4909 | 2026-11-26 | DOCS | verification 4.21: ASAP7 numbers are at 25 degrees |
| 0ea3e599 | 2026-11-26 | DOCS | coverage numbers and Zig floor TSV |
| 8113e9ef | 2026-11-26 | DOCS | corpus baseline (written empty by mistake) |
| 44a8c19d | 2026-11-26 | DOCS | corpus baseline restored with counts |
| 6c2e081b | 2026-11-26 | BUILD | tools/py_coverage.py output path fix |
| e18159d1 | 2026-11-26 | DOCS | verification: HSPICE EXP with no TD2 in LTspice |
| 2b8460cd | 2026-11-26 | BUILD | flake: Xyce built with plugin support |
| 11ccbb3e | 2026-11-26 | BUILD | pdk_devices harness: VACASK, baselines, nightly |
