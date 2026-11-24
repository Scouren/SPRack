* stats
.param p1=agauss(100,10,1)
.param p3=aunif(1000,30,1)
.param p5='2*agauss(0,1,3)+p1'
.subckt cell a b
.param pm=agauss(1,0.1,1)
r1 a b 'pm*p1'
.ends
x1 in 0 cell
x2 in 0 cell
v1 in 0 1
r5 in 0 'p5+p3'
.tran 1n 10n sweep monte=200
.end
