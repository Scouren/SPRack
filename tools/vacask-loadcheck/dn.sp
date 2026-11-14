dc and noise
V1 in 0 dc 1 ac 1
R1 in out 1k
R2 out 0 1k
.nodeset v(out)=0.4
.save v(out)
.dc V1 0 1 0.5
.noise v(out) V1 lin 4 1k 4k
.end
