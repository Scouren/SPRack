* #56 item 21: a .subckt port named `params:`: a name, or refused?
.subckt div a b params: rt=1k
r1 a b rt
.ends
v1 in 0 1
x1 in 0 0 div rt=2k
.op
.end
