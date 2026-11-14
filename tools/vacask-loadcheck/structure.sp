structure
.param sel=2 a=2
.param p={log(a) + asinh(1) + floor(2.7) + temper*0}
.lib 'models.lib' typ
.subckt div in out
R1 in out 1k
R2 out 0 {rtyp}
.ends div
.if (sel == 1)
R3 x 0 1k
.elseif (sel == 2)
R3 x 0 2k
.else
R3 x 0 3k
.endif
V1 in 0 1
X1 in mid div
Rx in x 1k
Rp in pn {p*1k}
Rpn pn 0 1k
C1 mid 0 1u
.ic v(mid)=0.2
.tran 1u 1m uic
.end
