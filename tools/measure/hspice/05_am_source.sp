* #56 item 5: AM source; the formula predicts 2.4142 at 0.125 ms.
v1 a 0 am(1 1 1k 10k 0)
r1 a 0 1k
.tran 1u 1m
.meas tran va find v(a) at=0.125m
.end
