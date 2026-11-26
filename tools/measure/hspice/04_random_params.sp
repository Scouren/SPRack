* #56 item 4, deck 1: a .param with DEV and LOT in a subcircuit used twice,
* and agauss(1k,30,3) against agauss(1k,10,1). 200 Monte Carlo runs; read
* the .mt0 file: per run the four resistances 1/i.
* DEV/LOT is documented on .MODEL parameters only (Reference Manual:
* Commands, .MODEL): DEV varies each device alone, LOT all together.
* Read: std(rx1 - rx2)/sqrt(2) (the DEV spread), std((rx1 + rx2)/2) (LOT);
* rqa and rqb: the manual's rule (sigma = abs_variation / sigma argument)
* gives both a standard deviation of 10.
.param qa=agauss(1k,30,3) qb=agauss(1k,10,1)
.subckt rp a b
.param p=1k dev/gauss=10 lot/gauss=20
r1 a b p
.ends
v1 in 0 1
x1 in 0 rp
x2 in 0 rp
ra in 0 qa
rb in 0 qb
.dc v1 0 1 0.5 sweep monte=200
.meas dc rx1 find par('1/i(x1.r1)') at=1
.meas dc rx2 find par('1/i(x2.r1)') at=1
.meas dc rqa find par('1/i(ra)') at=1
.meas dc rqb find par('1/i(rb)') at=1
.end
