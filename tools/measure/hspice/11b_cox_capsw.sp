* #56 item 11: a capacitor card's COX and CAPSW, 1 V AC at 1 MHz.
* Elements and Device Models manual: C = L W COX + 2 (L + W) CAPSW.
* First run, COX alone: C 0.1 pF, im(v1) 6.2832e-7. The alter adds
* CAPSW=1n: C 0.14 pF, im(v1) 8.7965e-7.
.model cm c cox=1m
v1 a 0 ac 1
c1 a 0 cm l=10u w=10u
.ac lin 1 1meg 1meg
.print ac im(v1)
.alter capsw
.model cm c cox=1m capsw=1n
.end
