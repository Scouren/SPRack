# Spectre measurement decks (issue 57)

Each answers one item of issue 57's list; run it in Spectre 25.10 as it is
and record in `docs/verification.md` (with the Spectre version) whether it
loaded and what it printed.

| deck | item | what to read |
|---|---|---|
| 01_statistics.scs | 1 | SPRack's translation of 01_statistics.source.sp (HSPICE): does it load (a `parameters` line after its use; a top-level parameter in `mismatch`)? 1b: in the Monte Carlo, x1 and x2 differ within a run, p1's std is 10; 1c: p3 within 970..1030 |
| 02_exp_zeros.scs, 02_exp_start.scs | 2 | v(n1..n7) at 10n, 30n, 49n against the values in verification 4.39; v(b) at 12.5n: 0.632121 or 0.713495 |
| 03_measure_in_spice.scs | 3 | loaded; where the results go; which kinds gave a value |
| 04_capacitor_q.scs | 4 | i(v1) against i(v2): the same, or refused |
| 05_lteratio.scs | 5 | v(a)'s amplitude near 20 us in tran1 and tran2 |
| 06a..06e | 6 | per deck and analysis (op1, tran1, tran2 with skipdc=yes): loads or stops, the message, v(b) / v(a) / the inductor currents |
| 07a_unique_param.scs | 7 | i(v1), i(v2): -1m (first value), -0.5m (last) or a stop |
| 07b_unique_master.scs | 7 | i(v1): -1m (the subcircuit) or hundreds of amperes (the diode model); again with the model line first |
| 08_readscale.scs | 8 | i(va), i(vb), i(vc): 1, 0.5, 0.5 |
| 09_psp_pac.scs | 9 | does psp1 stop without ports=; does pac1 stop without pacmag |
| 10_library_sections.scs | 10 | loaded (the second section's missing include not opened), or refused |
| 11_tf_current.scs | 11 | the transfer function to i(vmeasure): 1e-3 |
| 12_element_variation.scs | 12 | whether any form varies elements by type |
| 13_save_all.scs | 13 | which statement saves every node |
| 14_mos_levels.scs | 14 | which of the model names load |

`01_statistics.scs` is `sprack translate --from hspice --to spectre
01_statistics.source.sp`; regenerate it when the writer changes. Item 2's
deck is the seven sources of `tools/measure/hspice/01_exp_zeros.sp`
written by hand, since SPRack drops an explicit `td1=0`. Run each deck as
`spectre <deck> -format psfascii -raw <deck>.raw` and give the version line
of its log with the results. Where one line stops a deck (14 with a name
Spectre lacks), remove that line and run again, so every line gets an answer.
