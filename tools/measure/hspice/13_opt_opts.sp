* #56 item 13: .opt and .opts with tnom, and .temp: 0.667 mA applied, 0.495 mA ignored.
.opt tnom=27
.opts reltol=1e-4
.temp 127
v1 a 0 1
r1 a 0 1k tc1=0.01
.op
.print op i(v1)
.end
