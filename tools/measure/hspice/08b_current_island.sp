* #56 item 8: 1 mA into a node with only a capacitor. Read: loaded, the
* message, and v(a) (the grammar says about 1e9 V).
i1 0 a 1m
c1 a 0 1u
.op
.tran 1u 1m
.print tran v(a)
.end
