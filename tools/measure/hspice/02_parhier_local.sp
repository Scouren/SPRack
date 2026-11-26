* #56 item 2: .option parhier with the 4.14 subcircuit deck and a global r0.
* HSPICE User Guide: Simulation and Analysis (E-2010.12), Table 26: GLOBAL
* (the default) puts the top-level .PARAM above the instance and the header,
* LOCAL the instance, then the header, then the top-level .PARAM.
* First run (LOCAL):   i1 i2 i3 i4 = 0.5m 1m 0.25m 1m (2k, 1k, 4k, 1k).
* The alter (GLOBAL):  0.333m each (3k), by the manual.
.option parhier=local
.param r0=3k
.subckt rr a b r0=1k
r1 a b r0
.ends
v1 in 0 1
x1 in 0 rr r0=2k
x2 in 0 rr
x3 in 0 rr r0=4k
x4 in 0 rr
.dc v1 0 1 0.5
.meas dc i1 find i(x1.r1) at=1
.meas dc i2 find i(x2.r1) at=1
.meas dc i3 find i(x3.r1) at=1
.meas dc i4 find i(x4.r1) at=1
.alter global
.option parhier=global
.end
