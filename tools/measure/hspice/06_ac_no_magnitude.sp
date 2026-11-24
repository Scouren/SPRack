* #56 item 6: `ac` with no value is a magnitude of 1: 0.5 at the divider.
v1 a 0 dc 0 ac
r1 a b 1k
r2 b 0 1k
.ac lin 1 1k 1k
.print ac vm(b)
.end
