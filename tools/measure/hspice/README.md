# HSPICE measurement decks (issue 56)

Each deck answers one item of issue 56's checklist; run it in HSPICE
(Y-2026.03-SP2-1) as it is, and record in `docs/verification.md` whether it
loaded and the value it printed, next to what the deck's comment expects.
The decks that the checklist runs from the test suite (items 23 to 26) and
the PDK cards (27, 28) are run from there, not copied here.

| deck | item | what to read |
|---|---|---|
| 01_exp_zeros.sp | 1 | each v(nX) at 10n, 30n, 49n: an explicit 0 as 0, or as left out |
| 02_parhier_local.sp | 2 | i(x1.r1) .. i(x4.r1) with parhier=local |
| 03_fft_defaults.sp | 3 | the two .fft headers: points, window, format |
| 05_am_source.sp | 5 | va: 2.4142 by the formula |
| 06_ac_no_magnitude.sp | 6 | vm(b): 0.5 |
| 07_meas_no_analysis.sp | 7 | m1: which analysis it measured |
| 09_scale_letters.sp | 9 | i(v1) 1e-6, v(b) 1e-18, i(v3) 39370 |
| 12_tf_current.sp | 12 | loaded or refused |
| 13_opt_opts.sp | 13 | i(v1): 0.667 mA applied, 0.495 mA ignored |
| 14_width.sp | 14 | i(v1): 1 mA |
| 15_option_temp.sp | 15 | i(v1): 0.495 mA applied, 1 mA ignored |
| 16_noacct_klu.sp | 16 | loaded; i(v1) 1 mA |
| 17_delay.sp | 17 | t7 - ta: 1 ms |
| 19_hb_positional.sp | 19 | the positional .hb loaded, and the same v(b) as tones= |
| 20_print_all.sp | 20 | each .print loaded, and what it printed |
| 21_params_port.sp | 21 | `params:` a port name, or refused |
| 29_mos_levels.sp | 29 | each level: loaded, and the model in the listing |

Items 4 (random parameters), 8 (`requires` circuits, in verification 8.5),
10 (library sections), 11 (`tc1r`, `cox`) and 18 and 22 (suite decks) need
the decks named in the issue; 23 to 28 are the suite's and the PDKs' own.
