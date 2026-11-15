"""Tests for the Python package. Run: python3 test_sprack.py

The PDK tests need the model libraries of the five PDKs. Point
SPRACK_TEST_PDKS at a directory holding checkouts named sky130_fd_pr, ihp,
asap7, freepdk45 and gf180mcu (nix build .#test-pdks), and
SPRACK_TEST_PDKS_INSTALLED at installed sky130 and ihp trees
(nix build .#test-pdks-installed; those tests also run ngspice). Without
them those tests are skipped and say so.
"""
import os, shutil, sys, tempfile, time, traceback

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
               "Xyce has no pole-zero analysis", "Dialects that define it: espice, hspice, ngspice, spectre")
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
    # VACASK loads the BSIM4 module and takes the initial condition on the analysis.
    # Its BSIM4 takes version only as a string, so a numeric one is refused.
    raises(sprack.Unsupported, lambda: c.netlist("vacask"), "version not written: VACASK ships BSIM4 4.8 only")
    va = c.netlist("vacask", strict=False)
    for line in ['load "spice/bsim4v8.osdi"', "model nch sp_bsim4v8 (type=1 vth0=0.4)",
                 'analysis tran1 tran step=10p stop=8n maxstep=10p icmode="uic" ic={"out",0}']:
        assert line + "\n" in va, f"missing {line!r} in\n{va}"
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


def test_sweeps():
    c = sprack.Circuit("t")
    c.param(rv="1k")
    c.V("1", "a", 0, 1)
    c.R("1", "a", "b", "1k")
    c.R("2", "b", 0, "rv")
    c.step("rv", "1k", "3k", "1k")
    c.dc(param="rv", start="1k", stop="3k", step="1k")
    c.op()
    xy = c.netlist("xyce")
    assert ".step rv 1k 3k 1k\n" in xy and ".dc rv 1k 3k 1k\n" in xy, xy
    sp = c.netlist("spectre")
    assert "swp1 sweep param=rv start=1k stop=3k step=1k {\ndc1 dc param=rv start=1k stop=3k step=1k\nop1 dc\n}\n" in sp, sp
    raises(sprack.Unsupported, lambda: c.netlist("ngspice"), "ngspice has no .step")
    d = sprack.Circuit("t")
    d.data("rows", ["rv"], ["1k", "3k"])
    d.dc(data="rows")
    assert ".data rows rv 1k 3k\n.enddata\n.dc data=rows\n" in d.netlist("hspice")
    # An alter reruns the analyses with its edits: after them in Spectre, a table row in Xyce.
    e = sprack.Circuit("t")
    e.param(rv="1k")
    e.V("1", "a", 0, 1)
    e.R("1", "a", 0, "rv")
    e.op()
    e.code(".alter hot\n.param rv=2k\n.temp 85", dialect="hspice")
    sp = e.netlist("spectre")
    assert "op1 dc\nhot altergroup {\nparameters rv=2k\nsprackOptions1 options temp=85\n}\nop2 dc\n" in sp, sp
    assert ".data alters rv temp 1k 27 2k 85\n.enddata\n.step data=alters\n.op\n" in e.netlist("xyce", strict=False)


# SPRACK_GRAMMARS: for a copy of this file run outside the checkout (the wheel test).
GRAMMARS = os.environ.get("SPRACK_GRAMMARS") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "grammars")


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
    # A line the reader does not understand is kept as written for its own
    # dialect, and is an error of the netlist for any other.
    c.code(".bogus 1 2\n")
    assert ".bogus 1 2\n" in c.netlist("ngspice")
    raises(sprack.Unsupported, lambda: c.netlist("spectre"), "no ngspice rule understood this line", ".bogus 1 2")
    assert any(e.code == "untranslated" for e in c.netlist("xyce", strict=False).report.errors)
    raises(ValueError, lambda: c.code(".op\n", "pspice"), "unknown dialect")
    # An ngspice .control block in a code block is kept for ngspice only.
    ctl = sprack.Circuit("ctl")
    ctl.R("1", "a", 0, "1k")
    ctl.code(".control\nrun\n.endc\n")
    assert ".control\nrun\n.endc\n" in ctl.netlist("ngspice")
    raises(sprack.Unsupported, lambda: ctl.netlist("xyce"), "no ngspice rule understood this line")
    # A parameter defined outside the block keeps its spelling inside it
    # (Spectre is case-sensitive): the deck Schemify writes for Simulate.
    pc = sprack.Circuit("cm")
    pc.param(VCM=0.7, VDD=1.8)
    pc.code("VP inp 0 dc {VCM} ac 1\nVDD vdd 0 {VDD}\n")
    sp = pc.netlist("spectre", strict=False)
    assert "parameters VCM=0.7 VDD=1.8\n" in sp and "VP (inp 0) vsource dc=VCM mag=1\n" in sp and "dc=VDD\n" in sp, sp
    # A dialect's own options survive a code block written in it.
    lt = sprack.Circuit("lt")
    lt.R("1", "a", 0, "1k")
    lt.code(".options plotwinsize=0 numdgt=15\n.op\n", "ltspice")
    assert ".options plotwinsize=0 numdgt=15\n" in lt.netlist("ltspice")
    raises(sprack.Unsupported, lambda: lt.netlist("ngspice"), "'plotwinsize=0' has no spelling in ngspice")


def _with_cache(fn):
    old = os.environ.get("SPRACK_CACHE")
    with tempfile.TemporaryDirectory() as cache:
        os.environ["SPRACK_CACHE"] = cache
        try:
            return fn(cache)
        finally:
            if old is None:
                del os.environ["SPRACK_CACHE"]
            else:
                os.environ["SPRACK_CACHE"] = old


def _netlist_xyce(stmts):
    c = sprack.Circuit("t")
    c.statements = stmts
    return str(c.netlist("xyce", strict=False))


def test_library_translated_on_the_fly():
    def body(cache):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "m"))
            top = os.path.join(d, "top.lib")
            with open(top, "w") as f:
                f.write('* lib\n.lib tt\n.include "m/nch.mod"\n.param vth=0.4\n.endl tt\n'
                        '.lib ff\n.include "m/nch.mod"\n.param vth=0.3\n.endl ff\n')
            with open(os.path.join(d, "m", "nch.mod"), "w") as f:
                f.write("* model\n.model nch nmos level=54 vth0={vth}\n")
            os.environ["SPRACK_TEST_LIB"] = d
            c = sprack.Circuit("t")
            c.code('.lib "$SPRACK_TEST_LIB/top.lib" tt\nM1 d g 0 0 nch w=1u l=1u\n.op\n')
            # The source dialect keeps the library as it is.
            assert top not in unwrap(c.netlist("ngspice")) and "$SPRACK_TEST_LIB/top.lib" in unwrap(c.netlist("ngspice"))
            xy = unwrap(c.netlist("xyce"))
            libs = os.path.join(cache, "libs")
            (key,) = os.listdir(libs)
            copy = os.path.join(libs, key, "tree", "top.lib")
            assert f'.lib "{copy}" tt\n' in xy, xy
            back = sprack.Circuit("back")
            back.code(open(copy).read(), "xyce")
            assert [s["kind"] for s in back.statements if s["kind"] != "comment"] == ["libsection", "libsection"]
            assert ".model nch nmos level=14" in open(os.path.join(libs, key, "tree", "m", "nch.mod")).read()
            # A second write is a cache hit: nothing is translated again.
            marker = os.path.join(libs, key, "sprack.json")
            stamp = os.stat(marker).st_mtime_ns
            assert unwrap(c.netlist("xyce")) == xy and os.stat(marker).st_mtime_ns == stamp
            # A changed file is translated again.
            with open(os.path.join(d, "m", "nch.mod"), "a") as f:
                f.write(".model pch pmos level=54\n")
            c.netlist("xyce")
            assert os.stat(marker).st_mtime_ns != stamp
            assert ".model pch pmos level=14" in open(os.path.join(libs, key, "tree", "m", "nch.mod")).read()
            # Writers in parallel on an empty cache all get a whole copy.
            shutil.rmtree(libs)
            import concurrent.futures as cf, multiprocessing as mp
            with cf.ProcessPoolExecutor(4, mp_context=mp.get_context("fork")) as pool:
                outs = list(pool.map(_netlist_xyce, [c.statements] * 8))
            assert len(set(outs)) == 1 and outs[0] == _netlist_xyce(c.statements), set(outs)
            # The entry is whole and valid, and the call just made swept what
            # the parallel writers (now gone) left: no .old-* and no temp dirs.
            assert os.listdir(libs) == [key], os.listdir(libs)
            assert sprack._cached(os.path.join(libs, key)) is not None
            # Leftovers of a dead writer, and old ones whose pid is alive
            # again, are swept; a live writer's recent temp dir is kept.
            dead = 2 ** 22 + 12345  # above pid_max's default, so never alive
            for n in (f"{key}.old-{dead}-ab", f".{key}-{dead}-cd", f".{key}-{os.getpid()}-ef", f".{key}-{os.getpid()}-old"):
                os.makedirs(os.path.join(libs, n, "tree"))
            hour_ago = time.time() - 2 * sprack._STALE_AGE
            os.utime(os.path.join(libs, f".{key}-{os.getpid()}-old"), (hour_ago, hour_ago))
            _netlist_xyce(c.statements)
            assert sorted(os.listdir(libs)) == sorted([key, f".{key}-{os.getpid()}-ef"]), os.listdir(libs)
            shutil.rmtree(os.path.join(libs, f".{key}-{os.getpid()}-ef"))
            # A library that is not there is an error naming it.
            c.code(".include nowhere.inc\n")
            raises(sprack.Unsupported, lambda: c.netlist("xyce"), "cannot open", "nowhere.inc")
    _with_cache(body)


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
    # Two lines that are not ngspice syntax, and a parameter named vt, which Xyce refuses.
    codes = sorted(x.code for x in xy.report.errors)
    assert codes == ["invalid", "untranslated", "untranslated"], codes
    assert any("pm3.spice" in x.file for x in xy.report.errors if x.code == "untranslated")
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
    # Spectre has no agauss(): written as statistics variations. What is
    # left is reported per file and line. Conditional blocks translate.
    e = raises(sprack.Unsupported, lambda: c.netlist("spectre"), "has no spelling in spectre")
    assert not any("agauss" in x.message or "cond_if" in x.message for x in e.report.errors)
    assert sprack.PDK("ihp", root=os.path.join(PDKS, "ihp"), corner="ss").entries()[0][1] == "mos_ss"


def test_pdk_asap7():
    p = pdk("ASAP7", "asap7", corner="ff")
    assert p.dialect == "hspice" and p.entries()[0][0].endswith("7nm_FF.pm")
    assert set(p.devices) == {f"{t}mos_{v}" for t in "np" for v in ("lvt", "rvt", "slvt", "sram")}
    assert p.device("nmos_rvt")["device"] == "mosfet" and p.device("nmos_rvt")["family"] == "bsimcmg"
    c = sprack.Circuit("asap7 inverter", pdk=p)
    c.nmos_rvt("M1", "out", "in", 0, 0, nfin=3)
    c.pmos_rvt("M2", "out", "in", "vdd", "vdd", nfin=3)
    # A model card takes the instance parameters HSPICE's MOSFET takes.
    raises(TypeError, lambda: c.nmos_rvt("M3", "out", "in", 0, 0, nfins=3), "nmos_rvt is a mosfet of a hspice model card, which takes no parameter 'nfins'")
    c.tran("1p", "1n")
    hs = unwrap(c.netlist("hspice"))
    assert f'.include "{p.root}/models/hspice/7nm_FF.pm"\n' in hs and "M1 out in 0 0 nmos_rvt nfin=3\n" in hs
    sp = c.netlist("spectre")
    assert "M1 (out in 0 0) nmos_rvt nfin=3\n" in sp
    tree = p.translate("spectre")
    assert "model nmos_rvt bsimcmg type=n" in open(os.path.join(tree, "7nm_FF.pm")).read()
    xy = open(os.path.join(p.translate("xyce"), "7nm_FF.pm")).read()
    assert ".model nmos_rvt nmos level=111" in xy
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


def test_pdk_sky130_library_on_the_fly():
    def body(cache):
        lib = os.path.join(PDKS, "sky130_fd_pr", "models", "sky130.lib.spice")
        c = sprack.Circuit("sky130 tt")
        c.code(f'.lib "{lib}" tt\n', "ngspice")
        t = time.perf_counter()
        first = c.netlist("xyce", strict=False)
        t_first = time.perf_counter() - t
        t = time.perf_counter()
        again = c.netlist("xyce", strict=False)
        t_hit = time.perf_counter() - t
        print(f"      sky130 tt -> xyce: first write {t_first:.2f} s, cache hit {t_hit:.3f} s, {len(first.report.errors)} errors")
        assert again == first and len(again.report.errors) == len(first.report.errors)
        assert all(e.file for e in first.report.errors)
        assert os.path.join(cache, "libs") in unwrap(first) and "sky130.lib.spice\" tt" in unwrap(first)
        raises(sprack.Unsupported, lambda: c.netlist("xyce"))
    _with_cache(body)


def test_pdk_gf180mcu():
    p = pdk("gf180mcu", "gf180mcu")
    assert p.name == "gf180mcuD" and p.dialect == "ngspice" and p.corners == ("tt", "ss", "ff", "sf", "fs")
    assert {"nfet_03v3", "pfet_03v3", "nfet_06v0", "nfet_10v0_asym", "ppolyf_u", "cap_mim_2f0ff", "npn_10p00x10p00"} <= set(p.devices)
    assert p.device("nfet_03v3")["family"] == "bsim4" and p.device("npn_10p00x10p00")["ports"] == ["c", "b", "e", "s"]
    c = sprack.Circuit("gf180 inverter", pdk=p)
    c.V("dd", "vdd", 0, 3.3)
    c.V("in", "in", 0, 1.65)
    c.pfet_03v3("Mp", "out", "in", "vdd", "vdd", w="2u", l="0.28u")
    c.nfet_03v3("Mn", "out", "in", 0, 0, w="1u", l="0.28u")
    c.op()
    c.print_("dc", sprack.v("out"))
    ng = unwrap(c.netlist("ngspice"))
    m = f"{p.root}/models/ngspice"
    assert f'.include "{m}/design.spice"\n.lib "{m}/sm141064.spice" typical\n' in ng and f'/smbb000149.spice" typical\n' in ng
    assert ng.count(".lib ") == 7 and "Mn out in 0 0 nfet_03v3 w=1u l=0.28u\n" in ng
    assert p.entries("sf")[1:3] == [(f"{m}/sm141064.spice", "sf"), (f"{m}/sm141064.spice", "bjt_typical")]
    assert abs(ngspice_op(ng) - 0.468) < 0.005   # Xyce, on the translated library: 0.46826
    # Xyce has agauss(); into Spectre it becomes statistics variations.
    xy = unwrap(c.netlist("xyce"))
    assert f'.lib "{p.translate("xyce")}/sm141064.spice" typical\n' in xy
    assert not p.library_errors("spectre")
    # The mismatch wrappers (subckt nfet_03v3 around model nfet_03v3.N):
    # Spectre would resolve the transistor's model to the subcircuit itself,
    # so the model is renamed, and the circuit's own M line follows it.
    tree = p.translate("spectre")
    lib = open(os.path.join(tree, "sm141064.spice")).read()
    assert "model nfet_03v3__m bsim4 {" in lib and "m0 (d g s b) nfet_03v3__m " in lib and "subckt nfet_03v3 (d g s b)\n" in lib
    assert "q0 (c b e) pnp_10p00x10p00__m " in lib
    sp = c.netlist("spectre")
    assert "Mn (out in 0 0) nfet_03v3__m w=1u l=0.28u\n" in sp and "Mp (out in vdd vdd) pfet_03v3__m " in sp


def test_pdk_inverters_solvable():
    """No false alarm from the topology check: real inverters, through every
    file of their PDK's library, have a DC path everywhere and no loop."""
    sky = sprack.Circuit("sky130 inverter", pdk=pdk("sky130A", "sky130_fd_pr"))
    sky.V("dd", "vdd", 0, 1.8)
    sky.V("in", "in", 0, pulse=(0, 1.8, "1n", "50p", "50p", "2n", "4n"))
    sky.pfet_01v8("Mp", "out", "in", "vdd", "vdd", w=1, l=0.15)
    sky.nfet_01v8("Mn", "out", "in", 0, 0, w=0.5, l=0.15)
    sky.tran("10p", "8n")
    ihp = sprack.Circuit("ihp inverter", pdk=pdk("IHP", "ihp"))
    ihp.V("dd", "vdd", 0, 1.2)
    ihp.V("in", "in", 0, 0.6)
    ihp.sg13_lv_pmos("Mp", "out", "in", "vdd", "vdd", w="2u", l="0.13u")
    ihp.sg13_lv_nmos("Mn", "out", "in", 0, 0, w="1u", l="0.13u")
    ihp.rppd("R1", "out", "r", 0, w="0.5u", l="2u")
    ihp.cap_cmim("C1", "r", 0, w="5u", l="5u")
    ihp.op()
    for c in (sky, ihp):
        for d in ("vacask", "spectre"):
            alarms = [e for e in c.netlist(d, strict=False).report if "DC path" in e.message or "form a loop" in e.message]
            assert not alarms, "\n".join(map(str, alarms))
    # And a real alarm: C1 alone leaves its node with no path.
    c = sprack.Circuit("island")
    c.V("1", "in", 0, 1)
    c.R("1", "in", 0, "1k")
    c.C("1", "in", "x", "1p")
    c.C("2", "x", 0, "1p")
    c.tran("1n", "10n")
    raises(sprack.Unsupported, lambda: c.netlist("vacask"), "node 'x' has no DC path to ground: only C1, C2 reach it")


INSTALLED = os.environ.get("SPRACK_TEST_PDKS_INSTALLED", "")


def ngspice_op(netlist):
    """Run an .op netlist in ngspice; return v(out)."""
    import re, subprocess
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "tb.spice")
        # ponytail: unwrap, as ngspice 45 takes no continuation line on .lib.
        with open(f, "w") as fh:
            fh.write(unwrap(netlist).replace(".end\n", ".control\nrun\nprint v(out)\n.endc\n.end\n"))
        r = subprocess.run(["ngspice", "-b", f], capture_output=True, text=True)
    m = re.search(r"^v\(out\) = (\S+)", r.stdout, re.M)
    assert r.returncode == 0 and m, r.stdout + r.stderr
    return float(m.group(1))


def test_pdk_installed_sky130():
    p = sprack.PDK("sky130A", root=os.path.join(INSTALLED, "sky130"), cache_dir=tempfile.mkdtemp(prefix="sprack-test-"))
    assert p.entries() == [(f"{p.root}/sky130A/libs.tech/ngspice/sky130.lib.spice", "tt")]
    nfet = p.device("nfet_01v8")
    assert nfet["ports"] == ["d", "g", "s", "b"] and "/sky130A/libs.ref/sky130_fd_pr/spice/" in nfet["file"]
    c = sprack.Circuit("sky130 inverter", pdk=p)
    c.V("dd", "vdd", 0, 1.8)
    c.V("in", "in", 0, 0.9)
    c.pfet_01v8("Mp", "out", "in", "vdd", "vdd", w=1, l=0.15)
    c.nfet_01v8("Mn", "out", "in", 0, 0, w=0.5, l=0.15)
    c.op()
    assert 0.1 < ngspice_op(c.netlist("ngspice")) < 1.7


def test_pdk_installed_sky130_combined():
    """open_pdks' combined layout, whose parameters read `{a} + b*agauss(...)`:
    one expression in ngspice, the braces dropped."""
    lib = os.path.join(INSTALLED, "sky130", "sky130A", "libs.tech", "combined", "sky130.lib.spice")

    def nfet(path):
        c = sprack.Circuit("sky130 combined nfet")
        c.code(f'.lib "{path}" tt\n')
        c.V("dd", "vdd", 0, 1.8)
        c.V("g", "g", 0, 0.9)
        c.R("l", "vdd", "out", "10k")
        c.code("Xmn out g 0 0 sky130_fd_pr__nfet_01v8 w=1 l=0.15\n")
        c.op()
        return c

    def body(cache):
        for d in ("spectre", "xyce", "hspice"):
            errs = nfet(lib).netlist(d, strict=False).report.errors
            bad = [e for e in errs if e.code in ("untranslated", "unsupported") and "/parameters_" in e.file]
            assert not bad, "\n".join(map(str, bad))
        native = ngspice_op(nfet(lib).netlist("ngspice"))
        copy, _ = sprack._library_copy(lib, "ngspice", "ngspice")
        assert copy.startswith(cache) and 0.1 < native < 1.7
        assert ngspice_op(nfet(copy).netlist("ngspice")) == native
    _with_cache(body)


def test_pdk_installed_ihp():
    def vout(corner):
        p = sprack.PDK("ihp", root=os.path.join(INSTALLED, "ihp"), corner=corner, cache_dir=tempfile.mkdtemp(prefix="sprack-test-"))
        c = sprack.Circuit("ihp inverter", pdk=p)
        c.V("dd", "vdd", 0, 1.2)
        c.V("in", "in", 0, 0.6)
        c.sg13_lv_pmos("Mp", "out", "in", "vdd", "vdd", w="2u", l="0.13u")
        c.sg13_lv_nmos("Mn", "out", "in", 0, 0, w="1u", l="0.13u")
        c.rppd("R1", "out", "r", 0, w="0.5u", l="2u")
        c.cap_cmim("C1", "r", 0, w="5u", l="5u")
        c.op()
        ng = c.netlist("ngspice")
        # The OSDI objects IHP's .spiceinit loads: psp103 for the CMOS cards, psp103_nqs for the rf ones.
        osdi = [s["path"] for s in p.statements("ngspice") if s["kind"] == "hdl"]
        assert [os.path.basename(x) for x in osdi] == ["psp103.osdi", "psp103_nqs.osdi", "r3_cmc.osdi", "mosvar.osdi", "cap_cmomi.osdi", "cap_cmomf.osdi"]
        assert all(x in unwrap(ng) for x in osdi)
        return ngspice_op(ng)
    v = {k: vout(k) for k in ("tt", "ss", "ff", "sf", "fs")}
    # A slow n and fast p pull the output up; the reverse pulls it down.
    assert v["fs"] < v["ss"] < v["tt"] < v["ff"] < v["sf"], v


def test_periodic_analyses():
    c = sprack.Circuit("t")
    c.V("in", "in", 0, 0, sin=(0, 1, "1k"))
    c.R("1", "in", "out", "1k")
    c.pss("1k", 5)
    c.pac("dec", 4, 10, "10k")
    c.pnoise("out", "Vin", "dec", 3, 10, "10k")
    c.add("pxf", "out", "dec", 4, 10, "10k", engine="hb")
    sp = c.netlist("spectre", strict=False)
    for line in ["pac1 pac start=10 stop=10k dec=4", "pnoise1 (out 0) pnoise iprobe=Vin refsideband=0 start=10 stop=10k dec=3",
                 "pxf1 (out 0) hbxf start=10 stop=10k dec=4"]:
        assert line + "\n" in sp, f"missing {line!r} in\n{sp}"
    assert ".snac dec 4 10 10k\n" in c.netlist("hspice")
    assert "ngspice has no periodic steady state" in sprack.why_not("pac", "ngspice")


def test_pdk_errors():
    raises(sprack.SprackError, lambda: sprack.PDK("tsmc28", root="/nowhere"), "no manifest for PDK 'tsmc28'; known: ASAP7, FreePDK45, gf180mcuD, ihp-sg13g2, sky130A")
    raises(sprack.SprackError, lambda: sprack.PDK("sky130A", root="/nowhere"), "no model library found", "sky130.lib.spice")
    if PDKS:
        raises(sprack.SprackError, lambda: sprack.PDK("ASAP7", root=os.path.join(PDKS, "asap7"), corner="fs"), "has no corner 'fs'; it has: tt, ff, ss")


if __name__ == "__main__":
    failed = skipped = 0
    for name, fn in list(globals().items()):
        if not name.startswith("test_"):
            continue
        if name.startswith("test_pdk_installed_") and not INSTALLED:
            print(f"skip  {name} (set SPRACK_TEST_PDKS_INSTALLED)")
            skipped += 1
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
