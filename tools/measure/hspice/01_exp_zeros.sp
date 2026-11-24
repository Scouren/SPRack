* #56 item 1: an EXP source's explicit 0s: taken as 0 or as left out?
* Read v(nX) at 10n, 30n, 49n for each source; compare with the formula
* with the 0 and with the value HSPICE assumes when it is left out (4.18).
v1 n1 0 exp(0 1 0 0 0 0)
v2 n2 0 exp(0 1 0 5n 0 0)
v3 n3 0 exp(0 1 2n 0 20n 5n)
v4 n4 0 exp(0 1 2n 5n 0 5n)
v5 n5 0 exp(0 1 2n 5n 20n 0)
v6 n6 0 exp(0 1 0 5n 20n 5n)
v7 n7 0 exp(0 1 2n 5n 0 0)
r1 n1 0 1k
r2 n2 0 1k
r3 n3 0 1k
r4 n4 0 1k
r5 n5 0 1k
r6 n6 0 1k
r7 n7 0 1k
.tran 2n 50n
.print tran v(n1) v(n2) v(n3) v(n4) v(n5) v(n6) v(n7)
.end
