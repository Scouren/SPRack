* #56 item 13: .opt is .option: tnom=77 at .temp 127, a 1k of tc1=0.01.
* Applied: 1k*(1 + 0.01*50) = 1.5k, i(v1) 0.667 mA; ignored (TNOM 25): 0.495 mA.
.opt tnom=77
.temp 127
v1 a 0 1
r1 a 0 1k tc1=0.01
.op
.print op i(v1)
.end
