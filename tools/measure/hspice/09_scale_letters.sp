* #56 item 9: scale letters x (1e6), a (1e-18), mil (25.4e-6).
* i(v1) = 1/1e6, i(v2) = 1e-18/1 (through a current source), i(v3) = 1/25.4e-6.
v1 a 0 1
r1 a 0 1x
i2 0 b 1a
r2 b 0 1
v3 c 0 1
r3 c 0 1mil
.op
.print op i(v1) v(b) i(v3)
.end
