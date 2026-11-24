* #56 item 7: a .meas with no analysis name, after .dc, .ac and .tran.
* Which analysis's results does m1 take?
v1 a 0 dc 1 ac 1 sin(0 1 1k)
r1 a b 1k
c1 b 0 1u
.dc v1 0 2 1
.ac dec 1 10 100
.tran 10u 2m
.meas m1 max v(b)
.end
