* #56 item 20: .print tran all and .print pz all: loaded, and what each prints.
v1 a 0 sin(0 1 1k) ac 1
r1 a b 1k
c1 b 0 1u
.tran 10u 2m
.pz v(b) v1
.print tran all
.print pz all
.end
