# SPRack: plan to 100%

Built from the 14 November 2026 handoff, checked against `main` the same day.
Item numbers (2.1, 5.2, ...) refer to the handoff's sections and are kept so
both documents can be tracked together.

## What "100%" means

SPRack is done when all of these hold:

1. **No `-` in `sprack caps`.** Every cell is `yes`, `inst` or `none`, and every
   `none` has a cited source for the claim.
2. **No generic `untranslated` error** for any statement that some dialect
   supports. Each one either translates or names the dialects that have it.
3. **Every error-free translation loads in its target simulator (2.2)** and,
   where `.expected.json` exists, simulates to the same result (2.1).
4. **No `assumed` line is left** in any grammar.
5. **The Python package installs as a wheel** and finds an installed PDK tree.
6. **CI runs the tests and the corpus audit** with `SILENT` = 0.

**Spectre and HSPICE** are checked by running the tools on decks we write (Phase 6).

## State on 14 November

| | |
|---|---|
| Zig | 0.18.0-dev.349, pinned through `flake.nix` (ESPice's pins); handoff said 0.17.1 |
| Tests | Zig tests and Python tests pass in CI (Tests workflow); 4 PDK tests skip in CI |
| Corpus | 9,670 runs, 0 crashes, `SILENT` 0 (`conformance-suite-audit.tsv`) |
| `caps` gaps | Spectre 9, VACASK 15, HSPICE 3, Xyce 4 |
| `no` lines | 31; `assumed` lines: 9 (VACASK) |
| Simulators here | ngspice only. Xyce is in nixpkgs; VACASK and OpenVAF come from the conformance flake |

## Phase 0: tooling (small, unblocks everything)

- [x] **0.1 Simulators in the flake.** Add a `verify` dev shell containing
  `ngspice`, `xyce` and the conformance flake's `vacask` and `openvaf-r`, the
  same way ESPice's `benchmarking` shell does.
- [x] **0.2 Conformance Suite as a flake input.** Pin the audited commit
  (`4d565dd`) so the audit is reproducible from `nix develop .#verify`.
- [x] **0.3 PDK checkouts as flake inputs** (sparse paths per handoff §1), so
  `SPRACK_TEST_PDKS` is set in the shell and the 4 skipped tests run in CI.
- [x] **0.4 Corpus audit in CI** (nightly, not per push: it is slow). Fail if
  `SILENT` > 0 or if the error count rises against a committed baseline TSV.

*Exit:* `nix develop .#verify -c zig build test` runs all 9 Python tests, and
the nightly audit is green.

## Phase 1: does the output load? (2.2, then 2.1)

This is the biggest unknown. Until it is done, every grammar line is unverified.

- [x] **1.1 `tools/parse_check.py`.** For each error-free translation to
  ngspice, Xyce or VACASK, run the target in batch mode and require that it
  loads with no syntax error. Record failures in a TSV beside the audit.
- [x] **1.2 Fix or `caveat`** every failure. Each fix is a grammar edit plus a
  regression test in `src/tests.zig`.
- [x] **1.3 `tools/sim_check.py` (2.1).** Simulate the source and the
  translation, then compare against `.expected.json`. Start with ngspice → Xyce
  (386 decks), then ngspice ↔ VACASK.
- [x] **1.4 PDK smoke (2.3).** One inverter per PDK through
  `Circuit.netlist()`: sky130 → Xyce, FreePDK45/ASAP7 → Xyce. The Spectre half
  waits for Phase 6.
- [x] **1.5 Real fuzzer (2.4).** Run `zig build test --fuzz` on a normal
  machine; check that it works on Zig 0.18-dev.

*Exit:* the parse-check failures TSV is empty for the three free targets, and
the sim-check mismatches are either fixed or covered by a `caveat`.

## Phase 2: verify what was written from memory (6.1–6.7)

Work this list in the order Phase 1's failures point to.

- [x] **2.1 VACASK (6.1).** Read the VACASK manual and source, then resolve all
  9 `assumed` lines. VACASK is free, so each fix is checked by 1.1.
- [x] **2.2 Model level tables (6.2)** for ngspice and Xyce, against their
  reference manuals. HSPICE and Spectre are checked by running the tools (Phase 6).
- [x] **2.3 Function and operator tables (6.3)**, starting with `log`.
- [x] **2.4 All 31 `no` lines (6.4).** Each gets a source citation (open-source simulators) or an observed tool run (HSPICE, Spectre),
  or is turned into a rule.
- [x] **2.5 Enum spellings (6.5)** and the Spectre device forms (6.6).

*Exit:* every `no` line cites a source, and no `assumed` line is left.

## Phase 3: engine features that block grammar work (5.2, 5.3, 5.7)

- [x] **3.1 Repeated groups `( ... )*` with separators (5.2).** Touches
  `P.item` in `src/grammar.zig`, `Matcher.m` in `src/reader.zig` and `Emit.one`
  in `src/writer.zig`. It unblocks Spectre `func` and conditionals, `.step`
  lists, HSPICE `.hb tones=`, and nested probes.
- [x] **3.2 One rule emitting several statements (5.3).** Use a reader
  post-pass, as `undoMoves` does. It unblocks the lone HSPICE `.noise`.
- [x] **3.3 `define name = pattern` (5.7).** Do this before writing more
  rules: it collapses the twelve copies of the source-waveform line.

*Exit:* each feature has tests, and the audit shows no new difference.

## Phase 4: close `caps` (3.1–3.5)

| Dialect | Missing | Depends on |
|---|---|---|
| Spectre | done, each rule loaded in Spectre 25.10 | - |
| VACASK | `mutual`, `vcvs`, `vccs`, `cccs`, `ccvs`, `tline`, `libsection`, `lib`, `cond_*`, `ic`, `nodeset`, `sens`, `sp`, `pss`, `stb`, PWL/exp sources, more model families | Phase 2.1 |
| HSPICE | done, each rule loaded in HSPICE Y-2026.03 | - |
| Xyce | `sp` (`.lin`), `pss`, `cond_elif/else`; decide on `.sens` | none |

*Exit:* `sprack caps | grep -c ' - '` is 0.

## Phase 5: close the vocabulary (section 4)

Each new kind needs:

- an entry in `Kind` and in `defs`, in the same order, in `src/schema.zig`;
- a rule in each grammar that has it, and a `no` line in each that does not;
- an entry in `_POSITIONAL` in `python/sprack/__init__.py`;
- a test.

Order, by deck count:

1. [x] **Parameter sweeps (4.1):** `.dc` param, `.step`, `.temp` lists, `.alter`, `.data`, Spectre `sweep`.
   Done: `dc` sweeps an instance, a parameter or the temperature in both
   loops, by step, points per decade or octave, points in all, or a list;
   kinds `step` (body: the analyses it repeats) and `data`; Spectre `sweep`
   blocks, `dc param=`, `values=`; VACASK sweeps.
   *Done (c2):* kind `alter` (body: its edits, cumulative), HSPICE `.alter`,
   Spectre `altergroup` and one-change `alter` both ways (`rerun alter`: the
   analyses are written again after each); VACASK `alter instance(...)` and
   ngspice `.control` `alterparam` runs, Xyce a `.step` over a `.data`
   table, these three for parameter and temperature changes only. The
   HSPICE `SWEEP` tail (step, `POI`, `DEC`/`OCT`/`LIN`, `DATA=`) is a `step`
   around its analysis (`spread step "sweep"`). Semantics measured per tool
   (`docs/verification.md` 7). Out of scope: `SWEEP MONTE=` lists and
   `OPTIMIZE=`, Spectre `paramset`, `.data` from files (`MER`, `LAM`),
   HSPICE `.DEL LIB` and analyses added inside an `.alter` (an error elsewhere).
2. [x] **Analyses (4.2):** `pss`, HSPICE `pz`, ~~`mc`/`variation`~~ (done with 4.6), `dcmatch`, `pnoise`, `trannoise`, `envelope`, `sn`, then the 4–6-deck tail.
   - [x] **Periodic small-signal (b3):** kinds `pac`, `pnoise`, `pxf`, `psp`,
     each with `engine=hb` for the harmonic-balance form. Spectre
     `pac`/`hbac`, `pnoise`/`hbnoise`, `pxf`/`hbxf`, `psp`/`hbsp`; HSPICE
     `.SNAC`/`.HBAC`, `.SNNOISE`/`.HBNOISE`, `.SNXF`/`.HBXF`, `.HBLIN`;
     VACASK `pac` and `pnoise`, on the period given on the same statement.
   - [x] **The rest of the Spectre list (b3):** `xf` (also VACASK `acxf`),
     `dcmatch` (also HSPICE `.DCMATCH`), `envlp` (`envelope`), `qpss`;
     `stb` now also reads and writes HSPICE `.LSTB mode=single`.
   - [x] **HSPICE `.TRANNOISE` and `.PHASENOISE` (b3):** kinds `trannoise`
     and `phasenoise`.
   - [ ] **Left:** HSPICE `.SN TRES= PERIOD=` (3 decks; the period-and-step
     form needs a per-rule conversion), the keyword `.HBOSC` (needs an
     oscillator node on `hb` and `pss`), `.LSTB mode=diff|comm`, and a
     VACASK `pac`/`pnoise` written from a Spectre or HSPICE one (the period
     is on the `pss` before it).
   - **Out of scope, ESPice-only syntax** (HSPICE Y-2026.03 ignores each as an
     unknown card): `.pss f0 [points]` and `.pss v(osc) ...`, `.pac`, `.pxf`,
     `.pnoise`, `.qpss`, `.envelope`, `.matex`, `.stb Vprobe ...`, and the
     `.trannoise tstep tstop`, `.hbac ... f0 K` and `.hbosc v(osc) f0 K`
     forms, which HSPICE refuses. ESPice's own `.pss` and `.stb` rules were
     already in its grammar and stay.
3. [x] **Devices (4.3):** P, O, Y and W lines; `poly`/`table`/`laplace` sources.
   *Done (b4):* `lossyline` (ngspice/ESPice O, Y, P by model family; Xyce O;
   HSPICE W with RLGC), `ctlsrc` (POLY, TABLE, LAPLACE, POLE, VCR, VCCAP;
   Spectre pvcvs/pvccs for one input, written only), Spectre `relay` and
   `port`, HSPICE P ports, Xyce HICUM's fifth node through `rule bjt[hicum2]`.
   *Out of scope:* Xyce `YTRANSLINE` (no lumped-line form here; Xyce's O is
   the lossy line), Spectre's lossy lines (`mtline` takes no SPICE line
   cards), TABLE in HSPICE (none of the SPICE spellings load), LAPLACE in
   ngspice and Xyce (both reject the coefficient form).
4. [x] **Source forms (4.4)** and **output forms (4.5).**
   *Done (b4):* pulse count, trnoise, trrandom, ngspice AM with phases (the
   old mapping used HSPICE's order), HSPICE AM and PAT, `ac` alone, `dc=`;
   nested and negated probes, `#branch`, terminal currents, `.measure` in
   slots with text as the fallback (ambiguous across dialects).
   *Out of scope:* `pwl file=` (ESPice refuses it; ngspice and HSPICE do not
   load it), HSPICE LFSR (its tap list is bracketed, which the HSPICE lexer
   here does not read), PAT with inline repeats (`b1011 r=1 rb=2`).
5. [x] **Spectre structure (4.6).** `statistics` blocks come first: they are the 179 IHP errors.
   *Done:* kinds `statistics`, `statgroup`, `vary`, `correlate`, `montecarlo`,
   `library`, and `subckt.inline`. Spectre statistics blocks read and write;
   into Spectre, agauss/gauss/aunif/unif become statistics variations
   (`src/stats.zig`), and back, process variations become agauss()/aunif().
   HSPICE `.VARIATION` (model-parameter variations), `sweep monte=`
   (`spread`), Xyce `.sampling useexpr=true`; ngspice has no Monte Carlo
   card (`no`). HSPICE `dev/gauss=` becomes agauss(); Xyce's reserved
   parameter names (`vt`, `temp`, `time`, `freq`, `gmin`) are errors.
   `simulator lang=spice` sections (`switch`), binned model groups both
   ways, `library` blocks. IHP to Spectre: 325 errors to 8 (the rest are
   instance flags). The IHP inverter switches at 0.62253 V in Spectre via
   translation and 0.62253 V in ngspice. Left: HSPICE `parameter` lines in
   `.VARIATION`, mismatch and correlation into SPICE, Spectre `truncate`;
   a case-insensitive source needs `simulator lang=spectre insensitive=yes`
   in Spectre when Verilog-A parameter names are upper case (PSP103).
   *Done (c1):* written in every file (`header folded`) from a dialect that
   folds case, kept from a Spectre source; the setting is per file in
   Spectre, so an included file with the plain header was what failed. It
   covers Verilog-A module names too: the IHP tree loads with IHP's own
   `.va` files unedited, and the inverter (2u/1u, l=0.13u, VDD 1.2 V)
   crosses v(out)=v(in) at 0.6173038 V in Spectre and in ngspice.
6. [x] **VACASK control language (4.7).** `print`, `postprocess`, `abort`,
   `elaborate` are `simctl` statements in the control block; every other
   dialect has a `no simctl` line saying why. An `embed` block written
   elsewhere is an error giving the reason. `print stats` has no exact
   SPICE equivalent (`.options acct` prints different statistics).

**Stop rule.** If an item in the 4–6-deck tail turns out to be ESPice-only
syntax rather than a real simulator's, mark it out of scope instead of
building it.

*Exit:* no generic `untranslated` error is left for a statement that any
supported simulator defines.

## Phase 6: commercial targets

- [x] **6.1 Tool runs.** `tools/licensed_check.py` translates every
  error-free run, loads it in Spectre 25.10 / HSPICE Y-2026.03 on a host
  given by arguments, and runs the source deck in its own simulator as a
  control. Left (source loads, translation does not): `rise=0`
  pulses (now the `.tran` step, written by a `default` line), `%` and braces inside `.meas` text, `agauss` inline in HSPICE
  instance expressions, and decks whose values the commercial tools reject
  at run time (zero step, 0 K, m <= 0, V/L loops).

## Phase 7: Python and PDKs (section 7)

- [x] **7.1 `pyproject.toml` and a wheel (7.5).** Build it with `zig build py`
  and package the `.abi3.so`.
- [x] **7.2 Installed PDK layouts (7.1)** and the IHP corner map and `load`
  list (7.2), checked against IHP's documentation.
- [x] **7.3 Parameter check for model-card devices (7.3).** `params kind ...
  end` tables (ngspice/ESPice, Xyce, HSPICE, Spectre) for resistors,
  capacitors, inductors, current sources, diodes, BJTs, JFETs and HSPICE
  MOSFETs: renamed, or a loss, or `m>0` refused. The Python API checks a
  PDK model card's parameters against its dialect's table. Left: vsource,
  MOSFET tables outside HSPICE, VACASK (vacask-fix adds its own).
- [x] **7.4 CI matrix (7.4):** CPython 3.10 and 3.13, on Linux and macOS.
- [x] **7.5 C API (7.7).** Add one test, or delete `src/capi.zig`.
- [x] **7.6 GF180MCU manifest (7.6).** Optional.

## Phase 8: engine and warts (5.1, 5.4–5.6, section 8)

- [x] **8.1 Memory (5.1).** Lex one logical line at a time and store values
  sparsely. *Exit:* peak ≤ 5× on the RC mesh and ≤ 4× on sky130, and the
  audit is unchanged. *Reached:* 7.1× on the mesh (`tools/gen_bench.py mesh
  1000`, 111 MiB, was 17×) and 4.3× on sky130 (`gen_bench.py cat`, 45 MiB,
  was 12.7×). The test in `tests.zig` bounds the counted peak at 13×.
  Next lever: streaming read→write, or a 16-byte `Value` (the mesh's bound
  values alone are 2.6×). Smaller ones: free the logical-line list (1×) and
  shrink the 72-byte `Stmt` (1.8×).
- [x] **8.2 Expression semantics (5.4).** `?:` and `if()` are restructured
  into the form the target has; `differs` for ngspice `**`/`pwr`/`int`/
  `negpow`, Xyce `pwr`/`nint`/`log10`, HSPICE `ln`/`log10`, all measured
  (`docs/verification.md` 4.4). `int` and `floor` agree everywhere measured.
- [x] **8.3 Report the model-parameter caveat once per file (5.5).**
- [x] **8.4 Corner-aware `sprack project` (5.6).** `--section`; the Python
  PDK translates its corner only.
- [x] **8.5 Fix the spelling table for name slots only** (`Spelling.scan`).
- [x] **8.6 Doc cleanup:** the directive table lists every directive; no
  "spx" caption is left anywhere in the repository.

## Order and size

| Phase | Blocks | Rough size |
|---|---|---|
| 0 Tooling | everything | small |
| 1 Load/sim check | 2, 4 | large: produces the fix list |
| 2 Verify tables | 4 (VACASK) | medium |
| 3 Engine features | 4, 5 | medium |
| 4 `caps` | — | medium |
| 5 Vocabulary | — | large: the long tail |
| 6 Commercial | criterion 3 for 2 dialects | external |
| 7 Python/PDK | — | small–medium |
| 8 Engine/warts | — | medium |

Phases 7 and 8.1 are independent and can run alongside 1–5.

After every change, run `zig build test`, the Python tests, and the corpus
audit, which must keep `SILENT` at 0.
