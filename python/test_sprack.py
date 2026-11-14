"""Tests for the Python package. Run: python3 test_sprack.py

The PDK tests need the model libraries of the four PDKs. Point
SPRACK_TEST_PDKS at a directory holding checkouts named sky130_fd_pr, ihp,
asap7 and freepdk45; without it those tests are skipped and say so.
"""
import os, sys, tempfile, traceback

import sprack


def raises(exc, fn, *needles):
    try:
        fn()
    except exc as e:
        for n in needles:
            assert n in str(e), f"expected {n!r} in:\n{e}"
        return e
    raise AssertionError(f"expected {exc.__name__}")


def test_translate():
    out = sprack.translate("t\nR1 a 0 1M\n.tran 1n 1u\n.end\n", frm="ngspice", to="spectre")
    assert "R1 (a 0) resistor r=1m\n" in out and "tran1 tran step=1n stop=1u\n" in out
    assert out.report == []
    e = raises(sprack.Unsupported, lambda: sprack.translate("t\n.pz a 0 b 0 vol pz\n.end\n", frm="ngspice", to="xyce"),
               "Xyce has no pole-zero analysis", "Dialects that define it: espice, ngspice")
    assert "not written: analysis 'pz'" in e.text and e.report.errors[0].code == "unsupported"
    lax = sprack.translate("t\n.pz a 0 b 0 vol pz\n.end\n", frm="ngspice", to="xyce", strict=False)
    assert len(lax.report.errors) == 1
    raises(ValueError, lambda: sprack.translate("", frm="pspice", to="xyce"), "unknown dialect")


def build():
    c = sprack.Circuit("RC low-pass and an inverter")
    c.param(vdd=1.8, rload="2k")
    c.model("nch", "bsim4", "n", version="4.5", vth0=0.4)
    c.model("pch", "bsim4", "p", version="4.5", vth0=-0.4)
    with c.subckt("inv", "in", "out", "vdd", wn="1u") as s:
        s.M("n", "out", "in", 0, 0, "nch", w="wn", l="180n")
        s.M("p", "out", "in", "vdd", "vdd", "pch", w="2*wn", l="180n")
    c.V("dd", "vdd", 0, "vdd")
    c.V("in", "in", 0, 0, ac=1, pulse=(0, "vdd", "1n", "50p", "50p", "2n", "4n"))
    c.X("1", "in", "mid", "vdd", "inv", wn="2u")
    c.R("1", "mid", "out", "rload")
    c.C("1", "out", 0, "10f")
    c.options(reltol=1e-4, temp=27, method="gear")
    c.ic(out=0)
    c.save(sprack.v("out"), sprack.i("Vdd"))
    c.op()
    c.dc("Vin", 0, 1.8, 0.01)
    c.ac("dec", 10, 1, "1G")
    c.tran("10p", "8n", uic=True)
    return c


def test_build_every_dialect():
    c = build()
    ng = c.netlist("ngspice")
    for line in [".param vdd=1.8 rload=2k", ".model nch nmos level=14 version=4.5 vth0=0.4",
                 ".subckt inv in out vdd wn=1u", "Mp out in vdd vdd pch w={2*wn} l=180n",
                 "Vin in 0 dc 0 ac 1 pulse(0 {vdd} 1n 50p 50p 2n 4n)", "X1 in mid vdd inv wn=2u",
                 "R1 mid out {rload}", ".options temp=27 reltol=0.0001 method=gear", ".ic v(out)=0",
                 ".save v(out) i(Vdd)", ".dc Vin 0 1.8 0.01", ".ac dec 10 1 1g", ".tran 10p 8n uic"]:
        assert line + "\n" in ng, f"missing {line!r} in\n{ng}"
    sp = c.netlist("spectre")
    for line in ["model nch bsim4 type=n version=4.5 vth0=0.4", "subckt inv (in out vdd)", "parameters wn=1u",
                 "Mp (out in vdd vdd) pch w=2*wn l=180n", "X1 (in mid vdd) inv wn=2u", "R1 (mid out) resistor r=rload",
                 "ic out=0", "save out Vdd:p", "tran1 tran step=10p stop=8n skipdc=yes method=gear2"]:
        assert line + "\n" in sp, f"missing {line!r} in\n{sp}"
    assert [e.code for e in sp.report.warnings].count("caveat") >= 2
    c.netlist("hspice")
    # Xyce records only what .print lists: a bare save is an error there, and says so.
    raises(sprack.Unsupported, lambda: c.netlist("xyce"), "Xyce records only what .PRINT lists")
    # VACASK has no BSIM4 card in its grammar and no initial conditions.
    e = raises(sprack.Unsupported, lambda: c.netlist("vacask"), "model family 'bsim4 n'", "Defined by: espice, hspice, ltspice, ngspice, spectre, xyce")
    assert "analysis tran1 tran step=10p stop=8n" in e.text
    # Reading any netlist back gives a circuit that can be written again.
    again = sprack.read(ng, "ngspice")
    assert again.netlist("spectre", strict=False).count("\n") == sp.count("\n")


def test_vocabulary_is_closed():
    c = sprack.Circuit("t")
    raises(TypeError, lambda: c.tran("1n", "1u", errpreset="moderate"), "tran has no 'errpreset'; it has: name, step, stop")
    raises(TypeError, lambda: c.M("1", "d"), "needs its terminals and then its model")
    raises(TypeError, lambda: c.Q("1", "c", "b", "e", "s", "t", "x", "qmod"), "at most 5 terminals")
    raises(AttributeError, lambda: c.zener, "not a statement kind")
    c.R("1", "a", 0, "1M")
    raises(sprack.Unsupported, lambda: c.netlist("ngspice"), "'1M' is ambiguous", "1m or 1meg")
    c.statements.clear()
    c.C("1", "a", 0, "10PF")
    raises(sprack.Unsupported, lambda: c.netlist("ngspice"), "'10PF' is not a number", "case matters")
    assert sprack.can_write("tran", "vacask") and not sprack.can_write("pz", "xyce")
    assert "Xyce has no pole-zero analysis" in sprack.why_not("pz", "xyce")
    assert sprack.why_not("tran", "xyce") is None
    assert set(sprack.DIALECTS) == {"ngspice", "hspice", "xyce", "spectre", "vacask", "espice", "ltspice", "cdl"}
    c2 = sprack.Circuit("t")
    c2.B("1", "out", 0, v="v(inp)*2 + ln(k)")
    c2.global_("vdd", "vss")
    c2.print_("tran", sprack.v("out"))
    out = c2.netlist("ngspice")
    assert "B1 out 0 v={v(inp)*2 + ln(k)}\n" in out and ".global vdd vss\n" in out and ".print tran v(out)\n" in out
    assert "B1 (out 0) bsource v=v(inp)*2 + log(k)\n".replace("v=v(inp)*2 + log(k)", "v=(v(inp)*2 + log(k))") in c2.netlist("spectre", strict=False)


GRAMMARS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "grammars")


def test_grammar_file():
    path = os.path.join(GRAMMARS, "ngspice.spgrammar")
    c = build()
    ng = c.netlist("ngspice")
    assert c.netlist(path) == ng
    assert sprack.translate(ng, frm=path, to="spectre") == sprack.translate(ng, frm="ngspice", to="spectre")
    assert sprack.translate(ng, frm="ngspice", to=path) == sprack.translate(ng, frm="ngspice", to="ngspice")
    assert sprack.read(ng, path).statements == sprack.read(ng, "ngspice").statements
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "tb.spice")
        c.write(out, path)
        assert open(out).read() == ng
        bad = os.path.join(d, "bad.spgrammar")
        with open(bad, "w") as f:
            f.write('dialect bad\nlexer\nend\nrule op = ".op" zz\n')
        raises(ValueError, lambda: c.netlist(bad), f"{bad}:4: unknown slot 'zz' for kind 'op'")
    raises(ValueError, lambda: c.netlist("/no/such.spgrammar"), "cannot read /no/such.spgrammar")


def test_code():
    c = sprack.Circuit("code blocks")
    c.R("1", "in", "out", "1k")
    c.C("1", "out", 0, "1p")
    c.V("in", "in", 0, 1)
    added = c.code(".tran 1n 1u\n.ac dec 10 1 1G $ sweep\n.save v(out)\n")
    assert [s["kind"] for s in added] == ["tran", "ac", "save"]
    with c.subckt("buf", "a", "b") as s:
        s.code("rb (a b) resistor r=10\n", "spectre")
    sp = c.netlist("spectre")
    for line in ["tran1 tran step=1n stop=1u", "ac1 ac start=1 stop=1G dec=10 // sweep", "save out", "rb (a b) resistor r=10"]:
        assert line + "\n" in sp, f"missing {line!r} in\n{sp}"
    ng = c.netlist(os.path.join(GRAMMARS, "ngspice.spgrammar"))
    assert ".tran 1n 1u\n" in ng and "rb a b 10\n" in ng
    # A line the reader does not understand is an error of the netlist.
    c.code(".bogus 1 2\n")
    raises(sprack.Unsupported, lambda: c.netlist("ngspice"), "no sprack rule understood this line", ".bogus 1 2")
    assert any(e.code == "untranslated" for e in c.netlist("xyce", strict=False).report.errors)
    raises(ValueError, lambda: c.code(".op\n", "pspice"), "unknown dialect")


PDKS = os.environ.get("SPRACK_TEST_PDKS", "")


def unwrap(text):
    """Join continuation lines: the writer wraps at 100 columns, and PDK paths are long."""
    return text.replace("\n+ ", " ")


def pdk(name, sub, **kw):
    cache = tempfile.mkdtemp(prefix="sprack-test-")
    return sprack.PDK(name, root=os.path.join(PDKS, sub), cache_dir=cache, **kw)


def test_pdk_sky130():
    p = pdk("sky130A", "sky130_fd_pr")
    assert p.dialect == "ngspice" and p.corner == "tt" and "ff" in p.corners
    assert len(p.devices) > 150
    nfet = p.device("nfet_01v8")
    assert nfet["name"] == "sky130_fd_pr__nfet_01v8" and nfet["ports"] == ["d", "g", "s", "b"]
    assert {"l", "w", "nf", "mult"} <= set(nfet["params"])
    c = sprack.Circuit("sky130 inverter", pdk=p)
    c.V("dd", "vdd", 0, 1.8)
    c.V("in", "in", 0, pulse=(0, 1.8, "1n", "50p", "50p", "2n", "4n"))
    c.pfet_01v8("Mp", "out", "in", "vdd", "vdd", w=1, l=0.15)
    c.nfet_01v8("Mn", "out", "in", 0, 0, w=0.5, l=0.15)
    c.tran("10p", "8n")
    ng = unwrap(c.netlist("ngspice"))
    assert f'.lib "{p.root}/models/sky130.lib.spice" tt\n' in ng
    assert "XMp out in vdd vdd sky130_fd_pr__pfet_01v8 w=1 l=0.15\n" in ng
    raises(TypeError, lambda: c.nfet_01v8("M3", "a", "b", "c"), "has 4 terminals (d, g, s, b), got 3")
    raises(TypeError, lambda: c.nfet_01v8("M3", "a", "b", "c", "d", width=1), "has no parameter 'width'; it has: l, w")
    raises(AttributeError, lambda: c.nfet_1v8, "Did you mean: nfet_01v8")
    # Another dialect: the library itself is translated, once, and referenced.
    e = raises(sprack.Unsupported, lambda: c.netlist("xyce"))
    assert all(x.file for x in e.report.errors) and len(e.report.errors) <= 3, str(e)
    xy = c.netlist("xyce", strict=False)
    assert [x.code for x in xy.report.errors] == ["untranslated", "untranslated"] and "pm3.spice" in xy.report.errors[0].file
    tree = p.translate("xyce", strict=False)
    assert f'.lib "{tree}/models/sky130.lib.spice" tt\n' in unwrap(xy)
    lib = open(os.path.join(tree, "models", "sky130.lib.spice")).read()
    assert '.include "../cells/nfet_01v8/sky130_fd_pr__nfet_01v8__tt.corner.spice"' in lib
    assert os.path.isfile(os.path.join(tree, "cells/nfet_01v8/sky130_fd_pr__nfet_01v8__tt.corner.spice"))
    assert ".options parser scale=1.0u" in open(os.path.join(tree, "models", "all.spice")).read()


def test_pdk_ihp():
    p = pdk("IHP", "ihp")
    assert p.name == "ihp-sg13g2" and p.dialect == "ngspice"
    assert {"sg13_lv_nmos", "sg13_lv_pmos", "sg13_hv_nmos", "npn13G2", "rppd", "cap_cmim"} <= set(p.devices)
    assert p.device("sg13_lv_nmos")["ports"] == ["d", "g", "s", "b"]
    c = sprack.Circuit("ihp amp", pdk=p)
    c.sg13_lv_nmos("M1", "out", "in", 0, 0, w="1u", l="0.13u", ng=1)
    c.rppd("R1", "vdd", "out", 0, w="0.5u", l="2u")
    c.npn13G2("Q1", "c", "b", "e", "s", Nx=1)
    c.op()
    ng = unwrap(c.netlist("ngspice"))
    assert ng.count(".lib ") == 6 and '/cornerMOSlv.lib" mos_tt\n' in ng and '/cornerHBT.lib" hbt_typ\n' in ng
    assert "XM1 out in 0 0 sg13_lv_nmos w=1u l=0.13u ng=1\n" in ng
    hs = unwrap(c.netlist("hspice"))  # translates the library: conditionals and all
    assert '/cornerMOSlv.lib\' mos_tt\n' in hs or '/cornerMOSlv.lib" mos_tt\n' in hs
    # Spectre has no gauss()/agauss() and this grammar no conditional block: reported, per file and line.
    e = raises(sprack.Unsupported, lambda: c.netlist("spectre"), "function 'gauss' has no spelling in spectre")
    assert any("cond_if" in x.message for x in e.report.errors)
    assert sprack.PDK("ihp", root=os.path.join(PDKS, "ihp"), corner="ss").entries()[0][1] == "mos_ss"


def test_pdk_asap7():
    p = pdk("ASAP7", "asap7", corner="ff")
    assert p.dialect == "hspice" and p.entries()[0][0].endswith("7nm_FF.pm")
    assert set(p.devices) == {f"{t}mos_{v}" for t in "np" for v in ("lvt", "rvt", "slvt", "sram")}
    assert p.device("nmos_rvt")["device"] == "mosfet" and p.device("nmos_rvt")["family"] == "bsimcmg"
    c = sprack.Circuit("asap7 inverter", pdk=p)
    c.nmos_rvt("M1", "out", "in", 0, 0, nfin=3)
    c.pmos_rvt("M2", "out", "in", "vdd", "vdd", nfin=3)
    c.tran("1p", "1n")
    hs = unwrap(c.netlist("hspice"))
    assert f'.include "{p.root}/models/hspice/7nm_FF.pm"\n' in hs and "M1 out in 0 0 nmos_rvt nfin=3\n" in hs
    sp = c.netlist("spectre")
    assert "M1 (out in 0 0) nmos_rvt nfin=3\n" in sp
    tree = p.translate("spectre")
    assert "model nmos_rvt bsimcmg type=n" in open(os.path.join(tree, "7nm_FF.pm")).read()
    xy = open(os.path.join(p.translate("xyce"), "7nm_FF.pm")).read()
    assert ".model nmos_rvt nmos level=110" in xy
    # ngspice has no built-in BSIM-CMG: an error that says who has.
    raises(sprack.Unsupported, lambda: c.netlist("ngspice"), "model family 'bsimcmg n'", "Defined by: espice, hspice, spectre, xyce")


def test_pdk_freepdk45():
    p = pdk("FreePDK45", "freepdk45")
    assert p.dialect == "hspice" and p.corner == "nom"
    assert {"NMOS_VTL", "PMOS_VTL", "NMOS_VTG", "NMOS_VTH", "NMOS_THKOX"} <= set(p.devices)
    c = sprack.Circuit("freepdk45 inverter", pdk=p)
    c.NMOS_VTL("M1", "out", "in", 0, 0, w="90n", l="50n")
    c.pmos_vtl("M2", "out", "in", "vdd", "vdd", w="180n", l="50n")       # any case
    c.tran("1p", "1n")
    ng = c.netlist("ngspice")
    assert "M1 out in 0 0 NMOS_VTL w=90n l=50n\n" in ng and "M2 out in vdd vdd PMOS_VTL w=180n l=50n\n" in ng
    tree = p.translate("ngspice")
    # $PDK_DIR in the PDK's own include lines is resolved; the copy is self-contained.
    assert '.include "tran_models/models_nom/NMOS_VTL.inc"' in open(os.path.join(tree, "hspice_nom.include")).read()
    assert ".model NMOS_VTL nmos level=14" in open(os.path.join(tree, "tran_models/models_nom/NMOS_VTL.inc")).read()
    assert "model NMOS_VTL bsim4 type=n" in open(os.path.join(p.translate("spectre"), "tran_models/models_nom/NMOS_VTL.inc")).read()


def test_pdk_errors():
    raises(sprack.SprackError, lambda: sprack.PDK("tsmc28", root="/nowhere"), "no manifest for PDK 'tsmc28'; known: ASAP7, FreePDK45, ihp-sg13g2, sky130A")
    raises(sprack.SprackError, lambda: sprack.PDK("sky130A", root="/nowhere"), "no model library found", "sky130.lib.spice")
    if PDKS:
        raises(sprack.SprackError, lambda: sprack.PDK("ASAP7", root=os.path.join(PDKS, "asap7"), corner="fs"), "has no corner 'fs'; it has: tt, ff, ss")


if __name__ == "__main__":
    failed = skipped = 0
    for name, fn in list(globals().items()):
        if not name.startswith("test_"):
            continue
        if name.startswith("test_pdk_") and name != "test_pdk_errors" and not PDKS:
            print(f"skip  {name} (set SPRACK_TEST_PDKS)")
            skipped += 1
            continue
        try:
            fn()
            print(f"ok    {name}")
        except Exception:
            failed += 1
            print(f"FAIL  {name}")
            traceback.print_exc()
    print(f"{failed} failed, {skipped} skipped")
    sys.exit(1 if failed else 0)
