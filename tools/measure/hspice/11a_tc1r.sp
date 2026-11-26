* #56 item 11: a resistor card's TC1R. R = RSH L/W = 2k at 25.
* Taken (TC1R is TC1, Elements and Device Models manual): i(v1) 0.5 mA at
* 25 and 0.25 mA at 125; ignored: 0.5 mA at both.
.model rm r rsh=1000 tc1r=0.01
v1 a 0 1
r1 a 0 rm l=10u w=5u
.temp 25 125
.op
.print op i(v1)
.end
