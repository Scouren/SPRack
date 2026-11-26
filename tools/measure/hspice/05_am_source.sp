* #56 item 5: AM source; the formula predicts 2.4142 at 0.125 ms:
* 2*(0.5 + sin(2 pi 1k 0.125m))*sin(2 pi 10k 0.125m).
v1 a 0 am(2 0.5 1k 10k)
r1 a 0 1k
.tran 1u 1m
.meas tran va find v(a) at=0.125m
.end
