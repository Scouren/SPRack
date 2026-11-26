* #56 item 8 (no-lloop): two inductors in parallel fed through 1k. The
* manual (User Guide p.422): a loop error; the grammar: the run stops.
v1 in 0 1
r1 in a 1k
l1 a 0 1u
l2 a 0 1u
.op
.tran 1u 1m
.print tran i(l1) i(l2)
.end
