* #56 item 15: .option temp=127 in place of .temp: 0.495 mA applied, 1 mA ignored.
.option temp=127
v1 a 0 1
r1 a 0 1k tc1=0.01
.op
.print op i(v1)
.end
