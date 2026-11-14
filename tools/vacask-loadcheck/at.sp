abstime
b1 t 0 V={time*1e6}
R1 t 0 1k
.param g={agauss(1,0.1,3)}
R2 t 0 {g*1k}
.tran 1n 1u
.end
