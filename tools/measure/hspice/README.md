# HSPICE measurement decks (issue 56)

Each deck answers one item of issue 56's checklist; run it in HSPICE
(Y-2026.03-SP2-1) as it is, and record in `docs/verification.md` whether it
loaded and the value it printed, next to what the deck's comment expects.
The decks that the checklist runs from the test suite (items 23 to 26) and
the PDK cards (27, 28) are run from there, not copied here.

| deck | item | what to read |
|---|---|---|
| 01_exp_zeros.sp | 1 | each .meas against its comment: the value of a 0 taken as 0, or as left out |
| 02_parhier_local.sp | 2 | i1 .. i4: 0.5m 1m 0.25m 1m with parhier=local; the alter (global) 0.333m each by the manual |
| 03_fft_defaults.sp | 3 | the two .fft headers: points, window, format |
| 04_random_params.sp | 4 | the .mt0 over 200 runs: the DEV and LOT spreads of rx1, rx2; rqa and rqb, sigma 10 each by the manual |
| 04b_variation_seed.sp | 4 | ra, rb: sigma 10 each (absolute 10, 1 %); two runs the same; another with `.option seed=7` |
| 05_am_source.sp | 5 | va: 2.4142 by the formula |
| 06_ac_no_magnitude.sp | 6 | vm(b): 0.5 |
| 07_meas_no_analysis.sp | 7 | m1: which analysis it measured (the manual: the last, .tran) |
| 08a..08e_*.sp | 8 | loaded or stopped, the message, the values printed; again with `uic` on the `.tran` (`sed 's/^\.tran 1u 1m$/.tran 1u 1m uic/'`) |
| 09_scale_letters.sp | 9 | i(v1) 1e-6, v(b) 1e-18, i(v3) 39370 |
| 10_library_sections.sp | 10 | loads with i(v1) 1 mA, or stops on the missing include of section two |
| 11a_tc1r.sp | 11 | i(v1) 0.5 mA at 25, 0.25 mA at 125 if TC1R is taken |
| 11b_cox_capsw.sp | 11 | im(v1) 6.2832e-7 (COX), 8.7965e-7 with CAPSW in the alter |
| 12_tf_current.sp | 12 | loaded or refused; taken: 3.333e-4 |
| 13_opt.sp | 13 | i(v1): 0.667 mA applied, 0.495 mA ignored |
| 13b_opts.sp | 13 | the same for `.opts` |
| 14_width.sp | 14 | i(v1): 1 mA |
| 15_option_temp.sp | 15 | i(v1): 0.495 mA applied, 1 mA ignored |
| 16_noacct_klu.sp | 16 | loaded; i(v1) 1 mA |
| 17_delay.sp | 17 | t7 - ta: 1 ms |
| 19_hb_positional.sp | 19 | the positional .hb loaded, and the same v(b) as tones= |
| 20_print_all.sp | 20 | each .print loaded, and what it printed |
| 21_params_port.sp | 21 | `params:` a port name, or refused |
| 29_mos_levels.sp | 29 | each level: loaded, and the model in the listing |

Items 18 and 22 to 26 run the suite's decks named in the issue, 27 and 28
the PDKs' cards. What the manuals say for each item is in
`docs/verification.md` 4.38.
