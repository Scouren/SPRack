# Changelog

What changed for someone translating netlists or using the Python package.
Each entry names its issue; the measurements behind it are in
`docs/verification.md`. Newest first within each section.

## Unreleased (since v0.2.0)

### Changed: may need action

- A `sprack.Circuit` on a PDK that sets no `temp` or `tnom` is now an error when the target's default temperature is not the PDK simulator's. HSPICE assumes 25 °C and ngspice 27 °C, so the result used to depend on which simulator ran it. Set them with `c.options(temp=..., tnom=...)`. Plain translations still write the defaults, with a warning. (f2d3eb02)
- sky130 is read from FOSSi Foundation's `skywater-pdk-libs-sky130_fd_pr` (29b5515); Google's repository is archived. The two lines ngspice refused are corrected upstream, so their errata are gone. Their errors now cover all corners: 319 files, 312 errors to Xyce, 2 to Spectre, 18 to VACASK. (#25)
- Every name on a diode, BJT, VBIC, BSIM3, BSIM4 or PSP103 card going into VACASK is checked against the module's parameter list. VACASK refuses a card with an unknown name, so libraries that used to translate "cleanly" now report the names that would have stopped VACASK loading them. IHP: 3 errors. sky130: 18. (#33)
- Into LTspice, the instance parameters of R, C, L, D, Q and J are checked against what LTspice 26.0.2 takes. A name it refuses (which makes it refuse the whole deck) is a loss. LTspice's own names (Rser, Lser, Rpar, Cpar, RLshunt, noiseless, a diode's n) are a loss going out. (#73)
- A capacitor's `q=` into Spectre is an error; Spectre has no such parameter and drops it with a warning. (#57)
- ngspice's power operator is written as what ngspice computes, `pow(abs(x), y)`, into every other target. ngspice drops the sign of a negative base; the others keep it, and VACASK failed its operating point on the NaN. (#78)

### Added

- BSIM-CMG for ngspice and VACASK, through a module given to the translation: `--provide bsimcmg=FILE`, or `BSIMCMG_OSDI` for ASAP7. It agrees with Xyce's level 107 to 9 digits. (#27, #53)
- Xyce plugins for a PDK's Verilog-A modules (`--xyce-plugin MODULE=FILE`), written as `Y` devices. (#52)
- Errata in a PDK manifest for lines the PDK's own simulator refuses (`--errata`). (#42)
- Model families: ngspice MOS levels 4, 5, 6, 9, 55–57, 1040 and MESA (#48). A card's level found from its version or its instances' terminals (#31).
- Reader:
  - ngspice forms that ngspice 45 takes, a current as the `.tf` output, and the URC line (#43).
  - HSPICE analysis forms, element variation, port, pattern and data forms (#45, #46).
  - HSPICE statements that had no kind now get one or a reason; the optimizer reads `results=a,b` and `result=` (#47).
  - An ngspice `.control` block is read as a script (#50).
- Writer: `print all`, `.plot`, hb harmonics and maxord where the target has them (#44). A subcircuit is written once for each branch (#41). A function the target lacks is written as what the source means by it (#40).
- Python: dialect-only statements, embedded files and measures are typed (#51). Streamed translation (#67). The env JSON keeps every field (#71).
- CLI: `audit` says when a difference is silent; `-D` paths start where sprack runs (#54). On Windows, `$NAME` works in any case and there is an ARM64 tag (#55).
- Limits: inputs that are not regular files or are too large, and blocks nested over 100 deep, are refused with a reason (#37).

### Fixed

- HSPICE: a bare `ac` in a source is a magnitude of 1. It was read as the DC value and written `dc {ac}`. (#56)
- JSON: a byte that is not UTF-8 (a Latin-1 `µ` in a PDK comment) is written as its Latin-1 character. Before, the whole document was refused by `sprack write` and by Python. (#64)
- An HSPICE or Spectre EXP source with no TD2 is no longer an error into LTspice and VACASK, and it gives HSPICE's waveform in both. (#75)
- VACASK:
  - A capacitor's `ic=` and `q=` (#28).
  - A transient's start, a node pair in noise and dcxf, and gshunt (#38).
  - An S-parameter port's loss says how to rebuild it (#49).
  - `sp_bjt` has no level.
- Xyce:
  - A level 3 diode card is an error (#30).
  - Resistor and capacitor cards take only their own names (#32).
  - Reserved names in sweeps, data columns and alters (#34).
  - Noise between two nodes is a loss that says why (#68).
  - One analysis per netlist; the others are errors.
- Spectre: a Monte Carlo run from HSPICE or Xyce varies the mismatch block too (#70).
- Options that change no result are no longer errors (#39). An options statement none of whose values cross is not written.
- A library copied for one section loads in ngspice (#35). The report says what crosses: dropped blocks, foreign syntax, lines written back (#36). Names in probes and function arguments keep their spellings (#72).

### Tooling and CI

- Every pull request runs the format check, the documentation's examples and the corpus audit (#62). LTspice and CDL are audit targets (#59, #60).
- The nightly run fuzzes JSON, grammar and include-tree inputs and fails on a crash (#64). It compares every PDK device between its own simulator and Xyce and VACASK, against `tools/pdk-devices-baseline.tsv` (#61).
- Coverage: `zig build coverage` with kcov, a Python line tracer, and a floor per file (#65). Memory is bounded in the Python tests (#63).
- The `.#verify` shell's Xyce is built with plugin support (#26). Measurement decks for HSPICE and Spectre are in `tools/measure/` (#56, #57).
