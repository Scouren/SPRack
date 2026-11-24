* #56 item 2: .option parhier=local with the 4.14 subcircuit deck.
* Four instances: r0 from the instance, the header default, a global one.
.option parhier=local
.param r0=3k
.subckt rr a b r0=1k
r1 a b r0
.ends
v1 in 0 1
x1 in 0 rr r0=2k
x2 in 0 rr
x3 in 0 rr r0=4k
x4 in 0 rr
.op
.print op i(x1.r1) i(x2.r1) i(x3.r1) i(x4.r1)
.end
