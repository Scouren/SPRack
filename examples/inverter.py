"""One circuit, every dialect. After `zig build py`, from the repository root:

    PYTHONPATH=python python3 examples/inverter.py

With PDK_ROOT set it uses sky130A devices; without, two model cards of its own.
"""
import os
import sprack

pdk = sprack.PDK("sky130A") if os.environ.get("PDK_ROOT") else None

c = sprack.Circuit("CMOS inverter", pdk=pdk)
c.param(vdd=1.8)
c.V("dd", "vdd", 0, "vdd")
c.V("in", "in", 0, 0, pulse=(0, "vdd", "1n", "50p", "50p", "2n", "4n"))
if pdk:
    c.pfet_01v8("Mp", "out", "in", "vdd", "vdd", w=1, l=0.15)
    c.nfet_01v8("Mn", "out", "in", 0, 0, w=0.5, l=0.15)
else:
    c.model("nch", "bsim4", "n", vth0=0.4)
    c.model("pch", "bsim4", "p", vth0=-0.4)
    c.M("p", "out", "in", "vdd", "vdd", "pch", w="2u", l="180n")
    c.M("n", "out", "in", 0, 0, "nch", w="1u", l="180n")
c.C("load", "out", 0, "5f")
c.options(reltol=1e-4, method="gear")
c.tran("10p", "8n")

for dialect in sprack.DIALECTS:
    print(f"----- {dialect}")
    try:
        print(c.netlist(dialect))
    except sprack.Unsupported as e:
        print(e)
