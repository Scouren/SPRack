* #56 item 4, deck 2: a .variation sigma absolute against `%`, and the seed.
* User Guide (E-2010.12): a variation is absolute by default; `%` makes it
* relative to the parameter. rsh=1000, l/w = 1: absolute 10 and 1 % are both
* a sigma of 10 ohm. Run twice as it is (the same numbers if the seed is
* fixed, the manual: "always uses the same seed value for the first run"),
* then with `.option seed=7` added (different numbers).
.model rm r rsh=1000
.model rn r rsh=1000
.variation
.local_variation
r rm rsh=10
r rn rsh=1 %
.end_local_variation
.end_variation
v1 in 0 1
r1 in 0 rm l=1u w=1u
r2 in 0 rn l=1u w=1u
.dc v1 0 1 0.5 sweep monte=200
.meas dc ra find par('1/i(r1)') at=1
.meas dc rb find par('1/i(r2)') at=1
.end
