# How it is tested

Four layers, from the fastest to the slowest. The first two run in CI on
every push to `main` and every pull request; the others need a corpus of
decks or the simulators themselves.

## Adding a test for a netlist that went wrong

A fix for a reported netlist adds one file to `tests/fixtures/`: the
netlist, the dialect it is in, the dialect it is written for, and the output
and the report that must come out, byte for byte.

```sh
python3 -I tools/fixture.py new zig-out/bin/sprack capacitor-ic-into-vacask ngspice vacask < deck.sp
```

writes `tests/fixtures/capacitor-ic-into-vacask.case` with what the binary
answers now. Read the two sections it filled in before you commit them: they
are the claim. Say in the first line what the case holds and the issue it
comes from. `zig build test` runs every case (the test named `fixtures:`),
and puts each through the checks every translation of the suite goes
through. After a change that is meant to move a case,
`python3 -I tools/fixture.py bless zig-out/bin/sprack <file>` rewrites its
expected sections, and the diff in review shows what moved.

## Changing the engine without changing what it does

A change that is not meant to move any output is checked against a snapshot
of everything the command prints:

```sh
python3 -I tools/golden.py snapshot before/bin/sprack before.snap --suite "$SPRACK_SUITE" --pdks "$SPRACK_TEST_PDKS"
python3 -I tools/golden.py snapshot zig-out/bin/sprack  after.snap  --suite "$SPRACK_SUITE" --pdks "$SPRACK_TEST_PDKS"
python3 -I tools/golden.py diff before.snap after.snap
```

31,034 cases: every deck of the conformance suite read in its own dialect,
as ngspice and as HSPICE, and written for all seven (`translate`, `read`,
`audit`); the model libraries of the five PDKs as projects; and two damaged
copies of each deck. `diff` prints `IDENTICAL` or the cases that differ and
exits 1. A refactor is done when it prints `IDENTICAL`; a change of
behaviour names the cases it moved in its commit.

## Speed

```sh
python3 -I tools/bench.py zig-out/bin/sprack [other/bin/sprack] --pdks "$SPRACK_TEST_PDKS"
```

times a 27 MB RC mesh and 49 MB of sky130 cells into four dialects, by the
process's own time and, with `perf` on `PATH`, by instructions retired: on a
machine that is doing other work the wall clock moves by a third from run
to run, the instruction count does not. Build with
`-Doptimize=ReleaseFast` to measure.

## The rules the build holds the code to

`zig build lint` runs with every `zig build` and `zig build test`: `zig fmt
--check`; `lint/perf_tidy.py`, the linter of the performance guide (a
function is at most 70 lines and a line 100 columns, no recursion without a
stated bound, an assertion in every function of some length, no swallowed
error, no allocation or I/O in a loop without a reason); and
`lint/check_style.py`, the order of a file (what goes in and what comes out
and a list of its public items first, then imports, public before private,
tests last). The second and third hold the files listed in `lint/lint.zig`;
a module joins the list when it is moved to the rules
(`docs/dev/ARCHITECTURE.md`), and cannot slide back.

## 1. `zig build test`

```sh
zig build test        # everything below
zig build test-cli    # only the command-line cases
```

The tests are in `src/tests.zig`, with a few unit tests beside the code they
test (`src/reader/lexer.zig`, `src/core/expr.zig`, `src/grammar/root.zig` and others). The
names say what each one holds to; `grep -n '^test "' src/tests.zig` lists
them. By kind:

* **Every pair of dialects.** One circuit is written from each dialect to
  each other, read back, and compared: same circuit, no errors (`every pair
  of dialects: write, read back, same circuit, no errors`).
* **Invariants on every example.** Each translation a test makes goes
  through the same checks: the target reads the output as the same circuit
  or the report says why not; what the target read, it writes again without
  an error and reads the same from that; the JSON form reads back to the
  same statements; and a grammar loaded from its file at run time writes
  the same bytes as the one compiled in.
* **The whole vocabulary.** Every kind and every slot is written for every
  dialect without a crash; every kind has a rule, a place or a `no` line
  with a reason in every dialect; every `no` line produces an error that
  carries the grammar's reason.
* **Damaged input.** Truncated and foreign input through every reader;
  random bytes; 20,000 randomly damaged netlists through every reader and
  writer; mutated and deeply nested grammars, which must be refused with a
  diagnostic. None may crash.
* **Behaviour, one test per fact.** What `M` means in each dialect, model
  levels, sources and their waveforms, sweeps, alters, statistics, the
  topology check, and so on. The tests named `verification:`, `parse
  check:`, `sim check:` and `gap:` each reproduce, with a few lines of
  netlist, something a simulator or a real library showed.
* **The command.** `zig build test-cli` runs the built `sprack` on small
  inputs and checks what it prints and how it exits: 0 nothing lost, 1 the
  report has an error, 2 the command line is wrong. The cases are `cliTests`
  in `build.zig`.

## 2. `python/test_sprack.py`

```sh
zig build py
cd python && python3 test_sprack.py
```

The Python layer: the builder for every dialect, the closed vocabulary,
`code` blocks, grammar files by path, libraries translated on the fly and
the cache under parallel writers, netlists turned into builder scripts and
back, and the PDKs. The PDK tests read the real model libraries of the five
PDKs when `SPRACK_TEST_PDKS` names a directory holding them, and installed
SKY130 and IHP trees when `SPRACK_TEST_PDKS_INSTALLED` does (the flake
builds both: `nix build .#test-pdks`, `nix build .#test-pdks-installed`).
Some of them simulate an inverter in ngspice. Without the variables those
tests are skipped and say so.

## 3. The corpus audit

`sprack audit` translates one deck, reads the result back and compares
([columns](cli.md#audit)). Over a tree of decks:

```sh
python3 -I tools/corpus_audit.py zig-out/bin/sprack <suite>/tests out.tsv ngspice,hspice
python3 -I tools/corpus_summary.py out.tsv
python3 -I tools/corpus_compare.py tools/corpus-baseline.tsv out.tsv
```

`corpus_audit.py` runs every deck to every target (all seven built-in
writers, LTspice and CDL included) and writes one row per run. Each deck is read in the dialect its oracle names (`tokenizer` in
`<stem>.expected.json`, else ngspice; a `.sim` is VACASK), and also in each
dialect the last argument lists; the `declared` column says which reads are
the deck's own, and `expect` whether the suite expects it to be refused.
`corpus_summary.py` prints how much was understood and what was not, for
own-dialect and other-dialect reads apart; a deck expected to be refused
whose translation reports an error agrees with its oracle and is listed
apart, not counted as a failure. `corpus_compare.py` is the gate: it fails
if any run is *silent* (the circuit read back differs and no report entry
explains it; `sprack audit` exits 1 for it), or if crashes or any error
count rise against the baseline, kept per target for own-dialect
(`own.xyce`) and other-dialect (`other.xyce`) reads. A baseline from
before those keys gates only silence and crashes until it is rewritten
with `--update`. The nightly workflow runs these three on the
conformance suite.

## 4. In the simulators

A translation that reads back the same can still be refused by the target
simulator, or give another result. These tools check that. The first three
take the audit's table and work on the runs that had no error:

| tool | what it does |
|---|---|
| `tools/parse_check.py` | loads each translation in its target (ngspice, Xyce, VACASK), and the source deck in its own simulator as a control; a failure counts only when the source loads |
| `tools/sim_check.py` | simulates the source in ngspice and the translation in the target, and judges both against the suite's expected results |
| `tools/licensed_check.py` | the load check for Spectre and HSPICE, run on a host that has them |
| `tools/vacask-loadcheck/check.sh` | translates a set of decks that together use every rule of the VACASK grammar, and runs VACASK on each |
| `tools/pdk_smoke.py` | one inverter per PDK, simulated natively and from its Xyce translation |

Their header comments give the arguments. `nix develop .#verify` is a shell
with the free simulators and the suite.

What these runs found is fixed in the grammars and pinned by a test in
`src/tests.zig`, so the fast layers keep it fixed.

## The examples in these pages

Every command and Python snippet here is run and compared with the output
printed beside it. From the repository root, after `zig build` and `zig
build py`:

```sh
python3 docs/check/checkfiles.py      # the files printed in the pages are docs/src/examples
python3 docs/check/checkpage.py       # every python block, against the block after it
python3 docs/check/checkconsole.py    # every `$ command`, its output and exit status
```

Each exits non-zero on a mismatch and prints it. The SKY130 examples run
when `SPRACK_TEST_PDKS` is set and are skipped otherwise.

## The verification log

[Verification log](verification.md) records, claim by claim, what each
grammar's tables were checked against: the simulator's source or manual, or
a deck run in the simulator. The file is `docs/verification.md` in the
repository; grammar files and tests cite it by that path.

## What a pull request runs

`test.yaml` runs, on every push to `main` and every pull request: the Zig
tests, the Python tests with the real PDKs, `zig fmt --check build.zig
src`, the three checkers of the pages' examples (`docs/check/`), the corpus
audit against `tools/corpus-baseline.tsv`, the wheels, and `nix build
.#python` (the package a project pins, from only the files the flake keeps). `publish.yaml`'s
test job runs the same before a release. The nightly workflow keeps the
audit, the VACASK load check (which builds VACASK), the PDK device
comparison, and ten minutes of fuzzing: four targets in `src/tests.zig`
(netlist text up to 64 KiB, the JSON form, grammar files, trees of
includes) under `zig build test --fuzz`, and the 20,000 damaged netlists
from a seed of the night's own, printed when they fail
(`SPRACK_FUZZ_SEED`; `zig build test` keeps a fixed one).

## Threads

`sprack project` works on several files at once, and three things hold
that they share nothing while they do. A test of `src/translate/project.zig`
translates a tree of thirteen files one at a time and four at once and
compares the copies, the logs and the names expanded. The goldens take
every PDK as a project at the default of eight. And `zig build -Dtsan`
builds the command with the thread sanitizer, which stops at the first
write two threads make to one place unguarded:

```sh
zig build -Doptimize=ReleaseSafe -Dtsan
zig-out/bin/sprack project -j 8 --from ngspice --to spectre --lib --out out sky130.lib.spice
```

No `WARNING: ThreadSanitizer` is the result to hold (sky130, IHP and
gf180 give none). Under the sanitizer the large tables come from libc's
allocator: the page allocator grows them with `mremap`, which the
sanitizer does not follow, and a page one thread gave back and another
was given then reads as a race between the two.

## Coverage

`zig build coverage` runs the Zig tests built with the LLVM backend under
kcov (`--include-path=src`) and writes the report to `zig-out/coverage`;
the flake's `ci` shell has kcov. `tools/py_coverage.py` measures the Python
package's lines over `python/test_sprack.py` with a `sys.settrace` tracer
(function bodies; lines run only in other processes are not seen). The
`coverage` job of `test.yaml` runs both, and `tools/coverage_floor.py`
fails it when a file's line coverage falls more than one point below its
floor in `tools/coverage-floor-zig.tsv` or `tools/coverage-floor-py.tsv`.

| file | lines covered | measured |
|---|---|---|
| `src/passes/alter.zig` | 95.4 % (185 of 194) | 2026-11-26, at f2d3eb02 |
| `src/passes/cond.zig` | 95.2 % (278 of 292) | 2026-11-26, at f2d3eb02 |
| `src/core/expr.zig` | 96.4 % (719 of 746) | 2026-11-26, at f2d3eb02 |
| `src/grammar/root.zig` | 98.3 % (1115 of 1134) | 2026-11-26, at f2d3eb02 |
| `src/core/ir.zig` | 98.5 % (600 of 609) | 2026-11-26, at f2d3eb02 |
| `src/translate/json.zig` | 97.5 % (433 of 444) | 2026-11-26, at f2d3eb02 |
| `src/reader/lexer.zig` | 99.4 % (659 of 663) | 2026-11-26, at f2d3eb02 |
| `src/translate/project.zig` | 91.9 % (582 of 633) | 2026-11-26, at f2d3eb02 |
| `src/reader/root.zig` | 96.5 % (1811 of 1877) | 2026-11-26, at f2d3eb02 |
| `src/root.zig` | 98.1 % (52 of 53) | 2026-11-26, at f2d3eb02 |
| `src/core/schema.zig` | 100.0 % (23 of 23) | 2026-11-26, at f2d3eb02 |
| `src/passes/stats.zig` | 98.2 % (383 of 390) | 2026-11-26, at f2d3eb02 |
| `src/translate/stream.zig` | 99.6 % (274 of 275) | 2026-11-26, at f2d3eb02 |
| `src/tests.zig` | 99.0 % (4476 of 4523) | 2026-11-26, at f2d3eb02 |
| `src/passes/topology.zig` | 98.4 % (440 of 447) | 2026-11-26, at f2d3eb02 |
| `src/writer/` (one file then) | 98.5 % (2765 of 2808) | 2026-11-26, at f2d3eb02 |
| `src/` in all | 97.9 % (14795 of 15111) | 2026-11-26, at f2d3eb02 |
| `python/sprack/__init__.py` | 92.8 % (827 of 891) | 2026-11-24, with the five PDKs, the installed trees skipped |

The files are named as they are now; they were measured before they were
grouped into folders, and the writer before it was a folder of files, whose
floors the next `coverage_floor.py --update` writes. The `src/` rows are kcov's over the test binary of the `sprack` module,
and `tools/coverage-floor-zig.tsv` holds them. kcov counts only the lines
the binary has: a function nothing calls is not compiled, so it is not
counted, and `main.zig`, `pyext.zig` and `capi.zig` are not in the
binary (the command runs of `test-cli` and the Python tests reach them,
and are not measured). The least covered, and what their tests miss:
`project.zig`, a catalogue entry for a subcircuit (its ports and
parameters; the tests catalogue models only), a section asked for that
no file defines, a file it cannot write, and an input over the size
limit; `cond.zig`, a branch that holds a subcircuit and a conditional
of three or more variants (its `elif`); `alter.zig`, a `.data` sweep
over a parameter the netlist does not have, or with an expression in
it, and a netlist with no temperature; `expr.zig`, `^` and `**` where
the dialect has no power operator, exact division by a negative number
or a multiple of 5, and `applyMeans`/`ifToTernary` on quoted text and
on an `if` inside parentheses; `reader.zig`, an opaque block read
whole, `.alter` on a name or parameter the netlist lacks, and a
multi-segment `.tran` with an expression in it.
