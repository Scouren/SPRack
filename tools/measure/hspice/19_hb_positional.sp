* #56 item 19: `.hb 1meg 4` against `.hb tones=1meg nharms=4`.
v1 a 0 sin(0 1 1meg)
r1 a b 1k
d1 b 0 dm
.model dm d is=1e-14
.hb 1meg 4
.print hb v(b)
.alter
.hb tones=1meg nharms=4
.end
