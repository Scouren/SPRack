* #56 item 17: a DELAY element: v(o7) lags v(a) by 1 ms.
v1 a 0 pulse(0 1 0 1u 1u 2m 4m)
e7 o7 0 delay a 0 td=1m
r7 o7 0 1k
.tran 10u 4m
.meas tran ta when v(a)=0.5 rise=1
.meas tran t7 when v(o7)=0.5 rise=1
.end
