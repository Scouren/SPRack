* #56 item 1: an EXP source's explicit 0s: taken as 0 or as left out?
* The seven sources of the zero table of docs/verification.md 4.18. Left
* out (4.18): TD1 0, TAU1 (stop - TD1)/2, no fall without TD2, TAU2
* (stop - TD2)/2. Each .meas: the value if the 0 is taken as 0 | if left out.
va na 0 exp(0 1 0)
vb nb 0 exp(0 1 0 0.5n)
vc nc 0 exp(0 1 3n 0)
vd nd 0 exp(0 1 3n 0.5n 0)
ve ne 0 exp(0 1 3n 0.5n 6n 0)
vf nf 0 exp(0 1 1e-18 0.5n 6n 0.25n)
vg ng 0 exp(0 1 0 0.5n 6n 0.25n)
ra na 0 1k
rb nb 0 1k
rc nc 0 1k
rd nd 0 1k
re ne 0 1k
rf nf 0 1k
rg ng 0 1k
.option delmax=0.05n
.tran 2n 50n
* TD1 0 is TD1 left out: the same either way.
.meas tran a1n find v(na) at=1n       $ 0.039211 | 0.039211
.meas tran b05n find v(nb) at=0.5n    $ 0.632121 | 0.632121
* TAU1 0: a step at 3n, or TAU1 = 23.5n.
.meas tran c4n find v(nc) at=4n       $ 1.000000 | 0.041661
.meas tran c10n find v(nc) at=10n     $ 1.000000 | 0.257604
* TD2 0: a fall from 0 with TAU2 = 25n, or no fall.
.meas tran d10n find v(nd) at=10n     $ 0.670319 | 0.999999
.meas tran d49n find v(nd) at=49n     $ 0.140858 | 1.000000
* TAU2 0: a drop to 0 at 6n, or TAU2 = 22n.
.meas tran e625 find v(ne) at=6.25n   $ 0.000000 | 0.987197
.meas tran e10n find v(ne) at=10n     $ 0.000000 | 0.833752
* Nothing left out: the given curve, both.
.meas tran f625 find v(nf) at=6.25n   $ 0.367876
.meas tran g625 find v(ng) at=6.25n   $ 0.367876
.end
