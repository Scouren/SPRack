ideal line
Vt c0 0 pulse(0 1 0 1n 1n 50n 200n)
Rt c0 c 50
T1 c 0 d 0 z0=50 td=10n
Rl d 0 50
.tran 0.5n 200n
.end
