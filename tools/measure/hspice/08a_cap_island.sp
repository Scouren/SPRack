* #56 item 8 (dc-path): a node between two capacitors. Read: the warning
* ("no dc path to ground ... connected with gdcpath", User Guide p.1142)
* and v(b): 0 V by the grammar's line, 0.5 V where the charge is divided.
v1 a 0 1
c1 a b 1u
c2 b 0 1u
.op
.tran 1u 1m
.print tran v(b)
.end
