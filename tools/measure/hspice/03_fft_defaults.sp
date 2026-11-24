* #56 item 3: .fft defaults against np=1024 window=rect format=norm.
* Compare the two result files' headers (points, window, format) and values.
v1 a 0 sin(0 1 1meg)
r1 a 0 1k
.tran 10n 8u
.fft v(a)
.fft v(a) np=1024 window=rect format=norm
.end
