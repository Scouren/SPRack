model families
V1 vdd 0 2
V2 g 0 1
Rq1 vdd d1 1k
Q1 d1 g e1 qn
Re1 e1 0 1k
Rq2 vdd d2 1k
Q2 d2 g e2 qv
Re2 e2 0 1k
Rj vdd d3 1k
J1 d3 0 0 jn
Rz vdd d4 1k
Z1 d4 0 0 zn
Rm1 vdd d5 1k
M1 d5 g 0 0 m1n w=10u l=1u
Rm2 vdd d6 1k
M2 d6 g 0 0 m2n w=10u l=1u
Rm3 vdd d7 1k
M3 d7 g 0 0 m3n w=10u l=1u
Rm4 vdd d8 1k
M4 d8 g 0 0 b3n w=10u l=1u
Rm5 vdd d9 1k
M5 d9 g 0 0 b4n w=10u l=1u
Rm6 vdd d10 1k
M6 d10 g 0 vd
Rm7 vdd d11 1k
M7 d11 g vdd vdd m1p w=10u l=1u
.model qn npn bf=100
.model qv npn level=4
.model jn njf vto=-2 beta=1m
.model zn nmf vto=-2 beta=1m
.model m1n nmos level=1 vto=0.5 kp=100u
.model m1p pmos level=1 vto=-0.5 kp=50u
.model m2n nmos level=2 vto=0.5 kp=100u
.model m3n nmos level=3 vto=0.5 kp=100u nsub=1e15
.model b3n nmos level=8
.model b4n nmos level=14
.model vd vdmos vto=0.5 kp=1
.op
.end
