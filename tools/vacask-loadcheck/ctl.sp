controlled and behavioural sources
V1 in 0 dc 1
R1 in 0 1k
E1 e 0 in 0 2
Re e 0 1k
G1 0 g in 0 1m
Rg g 0 1k
Vs in s 0
Rs s 0 1k
F1 0 f Vs 3
Rf f 0 1k
H1 h 0 Vs 500
Rh h 0 1k
b1 b 0 V={v(in)*2 + 1}
Rb b 0 1k
b2 0 bi I={v(in)*1m}
Rbi bi 0 1k
.nodeset v(e)=1.9
.options chgtol=1e-14
.op
.tf v(e) V1
.end
