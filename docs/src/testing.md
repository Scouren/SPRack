# How it is tested

Four layers, from the fastest to the slowest. The first two run in CI on
every push to `main` and every pull request; the others need a corpus of
decks or the simulators themselves.

## 1. `zig build test`

```sh
zig build test        # everything below
zig build test-cli    # only the command-line cases
```

The tests are in `src/tests.zig`, with a few unit tests beside the code they
test (`src/lexer.zig`, `src/expr.zig`, `src/grammar.zig` and others). The
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

`corpus_audit.py` runs every deck to every target and writes one row per
run. `corpus_summary.py` prints how much was understood and what was not.
`corpus_compare.py` is the gate: it fails if any run is *silent* (the
circuit read back differs and no report entry explains it), or if crashes
or any target's error count rise against the baseline. The nightly workflow
runs these three on the conformance suite.

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
