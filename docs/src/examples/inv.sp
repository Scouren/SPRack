inverter
.param vdd=1.8 wn=1u
.model nch nmos level=54 vth0=0.42
.model pch pmos level=54 vth0=-0.41
.subckt inv in out vdd vss wp=2u
M1 out in vss vss nch W={wn} L=0.18u
M2 out in vdd vdd pch W={wp} L=0.18u
.ends inv
V1 vdd 0 DC {vdd}
X1 in out vdd 0 inv wp=3u
C1 out 0 20f
R1 out 0 {sqrt(wn)*1e9}
.tran 5p 12n uic
.end
