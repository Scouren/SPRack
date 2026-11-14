CMOS inverter testbench (ngspice)
.param vdd=1.8 wn=1u
.model nch nmos level=54 version=4.5 vth0=0.42
.model pch pmos level=54 version=4.5 vth0=-0.41
.subckt inv in out vdd vss wp=2u
M1 out in vss vss nch W={wn} L=0.18u
M2 out in vdd vdd pch W={wp} L=0.18u
.ends inv
Vdd vdd 0 DC {vdd}
Vin in 0 PULSE(0 1.8 1n 50p 50p 2n 4n)
X1 in out vdd 0 inv wp=3u
Cload out 0 20f
Rleak out 0 10MEG
.option reltol=1e-4
.tran 5p 12n 0 20p uic
.pz in 0 out 0 vol pz
.end
