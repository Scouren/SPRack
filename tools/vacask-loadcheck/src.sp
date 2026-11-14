source waveforms
Va a 0 sin(0.5 1 1meg 100n 1e5 30)
Vb b 0 exp(0 1 100n 200n 1u 300n)
Vc c 0 pwl(0 0 1u 1 2u 0.5 3u 0)
Vd d 0 sffm(0 1 2meg 3 200k)
Ve e 0 pulse(0 1 100n 50n 80n 300n 1u)
Ie 0 ie pulse(0 1m 100n 50n 80n 300n 1u)
Rie ie 0 1k
Ib 0 ib exp(0 1m 100n 200n 1u 300n)
Rib ib 0 1k
.tran 1n 3u 0 2n
.end
