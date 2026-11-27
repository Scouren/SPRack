"""Tests for the Python package. Run: python3 test_sprack.py

The PDK tests need the model libraries of the five PDKs. Point
SPRACK_TEST_PDKS at a directory holding checkouts named sky130_fd_pr, ihp,
asap7, freepdk45 and gf180mcu (nix build .#test-pdks), and
SPRACK_TEST_PDKS_INSTALLED at installed sky130 and ihp trees
(nix build .#test-pdks-installed; those tests also run ngspice). Without
them those tests are skipped and say so.
"""
import atexit, copy, json, os, pathlib, shutil, sys, tempfile, time, traceback

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
               "Xyce has no pole-zero analysis", "Dialects that define it: hspice, ngspice, spectre")
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
    # Xyce runs one analysis a netlist, and says so; the save is a .print of each.
    xe = raises(sprack.Unsupported, lambda: c.netlist("xyce"), "runs one analysis a netlist")
    assert "Xyce records only what .PRINT lists" not in str(xe), xe
    # VACASK loads the BSIM4 module and takes the initial condition on the analysis.
    # Its BSIM4 takes version only as a string, so a numeric one is dropped, with a warning.
    va = c.netlist("vacask")
    assert any("version not written: VACASK ships BSIM4 4.8 only" in w.message for w in va.report.warnings)
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
    assert set(sprack.DIALECTS) == {"ngspice", "hspice", "xyce", "spectre", "vacask", "ltspice", "cdl", "cktimg", "espice", "verilog"}
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
    gone = os.path.abspath("/no/such.spgrammar")
    raises(ValueError, lambda: c.netlist(gone), f"cannot read {gone}")


def test_utf8_and_lf_on_every_platform():
    # Whatever the platform's code page and line end: a netlist with a
    # continuation line that reaches Spectre on Linux must not carry a CR.
    import subprocess
    c = sprack.Circuit("10 k\u03a9 divider")
    c.R("1", "a", 0, "10k")
    ng = c.netlist("ngspice")
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "tb.spice")
        c.write(path, "ngspice")
        assert open(path, "rb").read() == ng.encode() and "\u03a9" in ng
        # Read as UTF-8 too, from a file and from standard input; the script escapes it.
        for args, piped in (([path], None), ([], ng.encode())):
            r = subprocess.run([sys.executable, "-m", "sprack", "--from", "ngspice", *args], input=piped, capture_output=True)
            assert r.returncode == 0 and b'"10 k\\u03a9 divider"' in r.stdout, r


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
    # An ngspice .control block in a code block is a script (#50): written
    # back for ngspice; a script of commands only has no Xyce form.
    ctl = sprack.Circuit("ctl")
    ctl.R("1", "a", 0, "1k")
    ctl.code(".control\nrun\n.endc\n")
    assert ".control\nrun\n.endc\n" in ctl.netlist("ngspice")
    raises(sprack.Unsupported, lambda: ctl.netlist("xyce"), "statement 'script' cannot be written for xyce")
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
            with cf.ProcessPoolExecutor(4, mp_context=mp.get_context("spawn")) as pool:
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


def test_library_of_a_grammar_file_dialect():
    def body(cache):
        with tempfile.TemporaryDirectory() as d:
            # A dialect of one's own: ngspice under another name.
            mine = os.path.join(d, "mine.spgrammar")
            with open(os.path.join(GRAMMARS, "ngspice.spgrammar")) as f, open(mine, "w") as g:
                g.write(f.read().replace("\ndialect ngspice\n", "\ndialect mine\n"))
            lib = os.path.join(d, "x.lib")
            with open(lib, "w") as f:
                f.write("* lib\n.lib tt\n.model nch nmos level=54\n.endl tt\n")
            deck = f'.lib "{lib}" tt\nM1 d g 0 0 nch w=1u l=1u\n.op\n'
            c = sprack.Circuit("t")
            c.code(deck, mine)
            # Its own dialect keeps the library; another gets a translated copy.
            assert f'.lib "{lib}" tt\n' in unwrap(c.netlist(mine))
            libs = os.path.join(cache, "libs")
            for circuit in (c, sprack.read("t\n" + deck + ".end\n", mine)):
                out = circuit.netlist("xyce")
                (key,) = os.listdir(libs)
                assert f'.lib "{os.path.join(libs, key, "tree", "x.lib")}" tt\n' in unwrap(out), out
                assert not [e for e in out.report if "translate that file too" in e.message], out.report
            assert ".model nch nmos level=14" in open(os.path.join(libs, key, "tree", "x.lib")).read()
            # The copy is of that grammar's reading: another grammar, another copy.
            with open(mine, "a") as g:
                g.write("# changed\n")
            c.netlist("xyce")
            assert len(os.listdir(libs)) == 2, os.listdir(libs)
    _with_cache(body)


PDKS = os.environ.get("SPRACK_TEST_PDKS", "")


def unwrap(text):
    """Join continuation lines: the writer wraps at 100 columns, and PDK paths are long."""
    return text.replace("\n+ ", " ")


# One directory for the run, removed at its end (issue 67); the PDK tests
# share one cache in it, so a library is translated once per run, not once
# per test. A test of the cache itself makes its own.
RUN_DIR = tempfile.mkdtemp(prefix="sprack-test-")
atexit.register(shutil.rmtree, RUN_DIR, True)


def run_dir(name):
    """A directory of its own under the run's, for a test that needs one."""
    return tempfile.mkdtemp(prefix=name + "-", dir=RUN_DIR)


def pdk(name, sub, **kw):
    return sprack.PDK(name, root=os.path.join(PDKS, sub), cache_dir=os.path.join(RUN_DIR, "cache"), **kw)


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
    assert all(x.file for x in e.report.errors) and len(e.report.errors) <= 312, str(e)
    xy = c.netlist("xyce", strict=False)
    # The thirteen resistor cards with dw (ngspice's NARROW,
    # with no SHORT), which no Xyce card computes, the eighteen diode cards of ngspice's level 3,
    # which Xyce's diode has not, and the parameters Xyce's cards do not take: twenty on resistor
    # cards (ten of them the card's own value) and 261 on the BJT cards of the five npn and pnp
    # files tt reaches (temperature coefficients, dcap, subs, gap1, gap2, ...).
    # (A parameter named vt, which Xyce refuses, is renamed.)
    codes = sorted(x.code for x in xy.report.errors)
    # The pinned sky130_fd_pr has the two lines of #25 corrected; the third
    # (the pfet_pass alias) is read through the manifest's errata.
    assert codes == ["loss"] * 312, codes
    losses = [x.message for x in xy.report.errors if x.code == "loss"]
    assert sum("__res_generic_" in m and "dw=" in m for m in losses) == 13
    assert sum("level not written: Xyce 7.10's diode has levels 1, 2, 200 and 2002" in m for m in losses) == 18
    assert sum("r not written: Xyce lists R" in m for m in losses) == 10
    assert sum("the resistor card of xyce takes no such parameter" in m for m in losses) == 10
    assert sum("the bjt card of xyce takes no such parameter" in m for m in losses) == 261
    tree = p.translate("xyce", strict=False)
    assert f'.lib "{tree}/models/sky130.lib.spice" tt\n' in unwrap(xy)
    assert "warning[caveat]: read through an erratum of the PDK" in open(os.path.join(tree, "sprack.log")).read()
    lib = open(os.path.join(tree, "models", "sky130.lib.spice")).read()
    assert '.include "corners/tt.spice"' in lib
    tt = open(os.path.join(tree, "models", "corners", "tt.spice")).read()
    assert '.include "../../cells/nfet_01v8/sky130_fd_pr__nfet_01v8__tt.pm3.spice"' in tt
    assert os.path.isfile(os.path.join(tree, "cells/nfet_01v8/sky130_fd_pr__nfet_01v8__tt.pm3.spice"))
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
    # A circuit that sets no temperature means its PDK simulator's (ngspice's
    # TNOM 27), which HSPICE does not assume: an error, until it says it.
    raises(sprack.Unsupported, lambda: c.netlist("hspice"), "the circuit sets no tnom; its PDK's simulator (ngspice) assumes tnom=27 and hspice assumes tnom=25")
    c.options(temp=27, tnom=27)
    hs = unwrap(c.netlist("hspice"))  # translates the library: conditionals and all
    assert '/cornerMOSlv.lib\' mos_tt\n' in hs or '/cornerMOSlv.lib" mos_tt\n' in hs
    # Spectre has no agauss(): written as statistics variations. Conditional
    # blocks translate, and a diode's OFF, which changes no result, is left out.
    assert not c.netlist("spectre").report.errors
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
    # HSPICE runs the PDK at 25 degrees, the others at 27: until the circuit
    # says its temperature, that is an error (Xyce: 113.55 uA at 25, 113.40 at 27).
    raises(sprack.Unsupported, lambda: c.netlist("spectre"), "its PDK's simulator (hspice) assumes temp=25, tnom=25 and spectre assumes temp=27, tnom=27")
    c.options(temp=25, tnom=25)
    sp = c.netlist("spectre")
    assert "M1 (out in 0 0) nmos_rvt nfin=3\n" in sp
    tree = p.translate("spectre")
    assert "model nmos_rvt bsimcmg type=n" in open(os.path.join(tree, "7nm_FF.pm")).read()
    xy = open(os.path.join(p.translate("xyce"), "7nm_FF.pm")).read()
    # ASAP7's cards say version = 107: Xyce's level 107, which the level says (docs/verification.md 4.21).
    assert ".model nmos_rvt nmos level=107 " in xy and "version" not in xy
    # ngspice has no built-in BSIM-CMG: an error that names the option for a module (docs/verification.md 4.43).
    raises(sprack.Unsupported, lambda: c.netlist("ngspice"), "ngspice has no built-in bsimcmg", "--provide bsimcmg=FILE")


BSIMCMG = os.environ.get("SPRACK_BSIMCMG_OSDI", "")


def test_pdk_bsimcmg_asap7():
    """ASAP7 with BSIM-CMG 107.0.0 compiled by the flake (tools/bsimcmg-osdi.sh),
    named by the manifest's `provide` through $BSIMCMG_OSDI (issue 53)."""
    import re, subprocess
    was = os.environ.pop("BSIMCMG_OSDI", None)
    try:
        for d in ("ngspice", "vacask"):
            raises(sprack.Unsupported, lambda: pdk("ASAP7", "asap7").translate(d), f"{d} has no built-in bsimcmg")
        os.environ["BSIMCMG_OSDI"] = BSIMCMG
        p = pdk("ASAP7", "asap7")
        for d in ("ngspice", "vacask"):
            # The three corners' files at once: 0 errors, one caveat a file.
            log = open(os.path.join(p.translate(d), "sprack.log")).read()
            assert log.count(f"written for the module {BSIMCMG} given to the translation") == 3, log
        c = sprack.Circuit("asap7 nmos_rvt", pdk=p)
        c.V("d", "d", 0, 0.7)
        c.V("g", "g", 0, 0.7)
        c.nmos_rvt("M1", "d", "g", 0, 0, nfin=3, l="20n")
        c.options(temp=25, tnom=25)  # the PDK's own simulator's (HSPICE)
        c.op()
        net = c.netlist("ngspice")
    finally:
        os.environ.pop("BSIMCMG_OSDI", None)
        if was is not None:
            os.environ["BSIMCMG_OSDI"] = was
    assert f"pre_osdi {BSIMCMG}\n" in net and "NM1 d g 0 0 nmos_rvt nfin=3 l=20n\n" in net
    with tempfile.TemporaryDirectory() as t:
        f = os.path.join(t, "tb.spice")
        with open(f, "w") as fh:
            fh.write(net.replace(".end\n", ".control\nset numdgt=10\nrun\nprint i(vd)\n.endc\n.end\n"))
        r = subprocess.run(["ngspice", "-b", f], capture_output=True, text=True)
    m = re.search(r"^i\(vd\) = (\S+)", r.stdout, re.M)
    assert m, r.stdout + r.stderr
    # Xyce 7.10's level 107 on the same card at 25 degrees: -113.550354 uA
    # (docs/verification.md 4.21, 4.43).
    assert abs(float(m.group(1)) / -113.550354e-6 - 1) < 1e-6, m.group(1)


def test_pdk_freepdk45():
    p = pdk("FreePDK45", "freepdk45")
    assert p.dialect == "hspice" and p.corner == "nom"
    assert {"NMOS_VTL", "PMOS_VTL", "NMOS_VTG", "NMOS_VTH", "NMOS_THKOX"} <= set(p.devices)
    c = sprack.Circuit("freepdk45 inverter", pdk=p)
    c.NMOS_VTL("M1", "out", "in", 0, 0, w="90n", l="50n")
    c.pmos_vtl("M2", "out", "in", "vdd", "vdd", w="180n", l="50n")       # any case
    c.tran("1p", "1n")
    raises(sprack.Unsupported, lambda: c.netlist("ngspice"), "its PDK's simulator (hspice) assumes temp=25, tnom=25 and ngspice assumes temp=27")
    c.options(temp=25, tnom=25)
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
    assert {"nfet_03v3", "pfet_03v3", "nfet_06v0", "nfet_10v0_asym", "ppolyf_u", "cap_mim_2f0_m4m5_noshield", "npn_10p00x10p00"} <= set(p.devices) and "cap_mim_2f0ff" not in p.devices
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
    # Xyce has agauss(); into Spectre it becomes statistics variations. The library's diode
    # cards are ngspice's level 3, which Xyce's diode has not: an error each, though the
    # inverter uses none of them (Xyce, on the translated library: 0.46826).
    xyn = c.netlist("xyce", strict=False)
    # ... and its MIM capacitors take their value from the card (cap=), and some resistor cards
    # carry noise parameters, which Xyce's cards do not take.
    assert xyn.report.errors and all("level not written: Xyce 7.10's diode" in x.message or "card of xyce takes no such parameter" in x.message or "has no such parameter" in x.message for x in xyn.report.errors)
    assert sum("cap=" in x.message for x in xyn.report.errors) == 15
    xy = unwrap(xyn)
    assert f'.lib "{p.translate("xyce", strict=False)}/sm141064.spice" typical\n' in xy
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


def test_topology_needs_an_analysis():
    """Schemify's component decks: a cell netlisted on its own, no analysis,
    built from `code` blocks and written back in their own dialect."""
    def alarms(c, d):
        return [e for e in c.netlist(d, strict=False).report if "DC path" in e.message or "form a loop" in e.message]
    def inv(extra=""):
        c = sprack.Circuit("inv (schemify ngspice)")
        c.global_("vdd!")
        c.param(wn=1, wp=2)
        c.code("MMN Y A 0 0 nmos W=wn L=1\nMMP Y A vdd! vdd! pmos W=wp L=1\n.model nmos nmos level=1\n.model pmos pmos level=1\n" + extra, "ngspice")
        return c
    # No analysis: nothing to report, in its own dialect or another.
    assert "MMN Y A 0 0 nmos" in inv().netlist("ngspice")
    assert not alarms(inv(), "vacask")
    # Same dialect in and out: no report even with an operating point.
    assert not alarms(inv(".op\n"), "ngspice")
    # Translated, an operating point refuses it.
    c = sprack.Circuit("inv")
    c.code("MMN Y A 0 0 nmos W=1 L=1\n.model nmos nmos level=1\n.op\n", "ngspice")
    raises(sprack.Unsupported, lambda: c.netlist("vacask"), "node 'A' has no DC path to ground")
    # A transient alone: VACASK's operating point fails on an island.
    c = sprack.Circuit("island")
    c.V("1", "in", 0, 1)
    c.C("1", "in", "x", "1p")
    c.C("2", "x", 0, "1p")
    c.tran("1n", "10n")
    raises(sprack.Unsupported, lambda: c.netlist("vacask"), "node 'x' has no DC path to ground")


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
    p = sprack.PDK("sky130A", root=os.path.join(INSTALLED, "sky130"), cache_dir=run_dir("installed"))
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
            bad = [e for e in errs if e.code in ("untranslated", "unsupported") and "/parameters" in e.file]
            assert not bad, "\n".join(map(str, bad))
        native = ngspice_op(nfet(lib).netlist("ngspice"))
        copy, _ = sprack._library_copy(lib, "ngspice", "ngspice")
        assert copy.startswith(cache) and 0.1 < native < 1.7
        assert ngspice_op(nfet(copy).netlist("ngspice")) == native
    _with_cache(body)


def test_pdk_installed_ihp():
    def vout(corner):
        p = sprack.PDK("ihp", root=os.path.join(INSTALLED, "ihp"), corner=corner, cache_dir=run_dir("installed"))
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


# A PDK small enough to write here: one ngspice library whose section holds
# model cards and includes a file of subcircuits.
TINY = {"name": "tiny", "dialect": "ngspice", "layouts": [{"probe": "m.lib"}], "corners": {"tt": [["m.lib", "tt"]]},
        "define": {"CELLS": "{root}"}}


def _tiny(fn, **manifest):
    """Run `fn(make, d)` with the tiny PDK's files in directory `d`;
    `make(**kw)` is that PDK, its cache in `d` too."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "m.lib"), "w") as f:
            f.write('* tiny\n.lib tt\n.model rmod r rsh=10\n.model cmod c cj=1m\n.model lmod l ind=1n\n'
                    '.model nch nmos level=54\n.include "$CELLS/cells.inc"\n.endl tt\n')
        with open(os.path.join(d, "cells.inc"), "w") as f:
            f.write("* cells\n.subckt cell a b\nR1 a b 1k\n.ends cell\n")
        return fn(lambda **kw: sprack.PDK("tiny", **{"root": d, "cache_dir": os.path.join(d, "cache"), "manifest": {**TINY, **manifest}, **kw}), d)


def test_tiny_pdk_model_cards():
    def body(make, d):
        c = sprack.Circuit("t", pdk=make())
        # The model is the device's model, also where a value could stand.
        c.rmod("R1", "a", 0, w="1u", l="10u")
        c.cmod("C1", "a", 0, w="1u", l="10u")
        c.lmod("L1", "a", 0, "2n", tc1=0.01)
        c.lmod("L2", "a", 0)
        c.nch("M1", "a", "a", 0, 0, w="1u", l="1u")
        c.cell("X1", "a", 0)
        c.V("1", "a", 0, 1)
        c.op()
        assert ("R1 a 0 rmod w=1u l=10u\nC1 a 0 cmod w=1u l=10u\nL1 a 0 lmod 2n tc1=0.01\nL2 a 0 lmod\n"
                "M1 a a 0 0 nch w=1u l=1u\nX1 a 0 cell\n") in c.netlist("ngspice")
        # An inductor's model has a measured form in ngspice, Xyce, VACASK and Spectre; HSPICE takes none.
        assert ("R1 (a 0) rmod w=1u l=10u\nC1 (a 0) cmod w=1u l=10u\nL1 (a 0) lmod l=2n tc1=0.01\nL2 (a 0) lmod\n"
                in c.netlist("spectre", strict=False))
        assert not any("inductor" in e.message for e in c.netlist("spectre", strict=False).report.errors)
        raises(sprack.Unsupported, lambda: c.netlist("hspice"), "inductor.master = lmod has no spelling in hspice")
    _tiny(body)

    # A source's model (VACASK has them) holds no parameter: nothing to instantiate.
    def sources(make, d):
        with open(os.path.join(d, "m.lib"), "w") as f:
            f.write("model vm vsource\nmodel im isource\n")
        c = sprack.Circuit("t", pdk=make())
        raises(TypeError, lambda: c.vm("V1", "a", 0), "vm is a model card for kind 'vsource', which takes no model: such a model holds no parameter")
        raises(TypeError, lambda: c.im("I1", "a", 0), "im is a model card for kind 'isource', which takes no model")
    _tiny(sources, dialect="vacask", corners={"tt": [["m.lib", None]]})


def test_tiny_pdk_names_are_known_to_the_writer():
    def body(make, d):
        # The libraries also declare a function, and a cell of theirs holds a diode.
        with open(os.path.join(d, "cells.inc"), "a") as f:
            f.write(".func twice(x) {2*x}\n.subckt dcell a b\nD1 a b dd\n.model dd d is=1e-14\n.ends dcell\n")
            # And a model Spectre has to rename: a subcircuit has the name too.
            f.write(".model rm r rsh=10\n.subckt rm a b\nR1 a b rm w=1u\n.ends rm\n")
        c = sprack.Circuit("t", pdk=make())
        c.rmod("R1", "a", 0, w="1u")
        c.R("2", "a", 0, model="nowhere", w="1u")
        c.R("4", "a", 0, model="rm", w="1u")
        c.V("1", "a", 0, sprack.expr("twice(1)"))
        c.op()
        for target in ("hspice", "spectre", "vacask"):
            out = c.netlist(target, strict=False)
            said = [e.message for e in out.report]
            # A model of the PDK is declared; one that is nowhere is still said.
            assert not [m for m in said if "'rmod' on R1" in m], out.report
            # Nor is the one renamed: it is declared under the name it is written as.
            assert not [m for m in said if "on R4 is a model name" in m], out.report
            assert f"R4 (a 0) {'rm__m' if target == 'spectre' else 'rm'} w=1u\n" in out or target == "hspice", out
            assert [m for m in said if f"'nowhere' on R2 is a model name in sprack, but no model of that name is declared here; {target} will read it as a parameter" in m], out.report
            assert not [m for m in said if "function 'twice' has no spelling" in m], out.report
        # What only the libraries use is loaded by the netlist that includes them.
        assert 'load "spice/diode.osdi"\n' in out and 'load "spice/bsim4v8.osdi"\n' in out, out
        # Read from another dialect's text, a device of a PDK model is that device.
        c.code("M1 (a a 0 0) nch w=1u l=1u\nR3 (a 0) rmod w=2u\n", "spectre")
        assert "M1 a a 0 0 nch w=1u l=1u\nR3 a 0 rmod w=2u\n" in c.netlist("ngspice"), c.netlist("ngspice")
        del c.statements[-2:]
        # A netlist for the PDK's own dialect is the one it was.
        assert c.netlist("ngspice") == f't\n.lib "{os.path.join(d, "m.lib")}" tt\nR1 a 0 rmod w=1u\nR2 a 0 nowhere w=1u\nR4 a 0 rm w=1u\nV1 a 0 dc {{twice(1)}}\n.op\n.end\n', c.netlist("ngspice")
    _tiny(body)


def test_tiny_pdk_subcircuit_for_each_branch():
    def body(make, d):
        # A cell that picks its model by a parameter: Xyce, which has no
        # conditional blocks, holds it once for each branch.
        with open(os.path.join(d, "cells.inc"), "a") as f:
            f.write(".model rmod2 r rsh=20\n.subckt msel a b w=1u rfmode=0\n.if (rfmode == 0)\nR1 a b rmod w=w\n.else\nR1 a b rmod2 w=w\n.endif\n.ends msel\n")
        pdk = make()
        c = sprack.Circuit("t", pdk=pdk)
        c.msel("X1", "a", 0)
        c.msel("X2", "a", 0, w="2u", rfmode=1)
        c.V("1", "a", 0, 1)
        c.op()
        # An instance is the one its parameters select, as the PDK's files declare it.
        out = c.netlist("xyce")
        assert "X1 a 0 msel\nX2 a 0 msel__1 params: w=2u rfmode=1\n" in out, out
        copy = "".join(open(os.path.join(at, n)).read() for at, _, names in os.walk(pdk.translate("xyce")) for n in names)
        assert "* [sprack] 'msel' where !(rfmode == 0)\n.subckt msel__1 a b params: w=1u rfmode=0\nR1 a b rmod2 w={w}\n.ends msel__1\n" in copy, copy
        assert ".subckt msel a b params: w=1u rfmode=0\nR1 a b rmod w={w}\n.ends msel\n" in copy, copy
        # Where the block has a form, nothing changes.
        assert "X2 a 0 msel w=2u rfmode=1\n" in c.netlist("ngspice")
        # A catalogue kept by another build of the core is not this one's.
        stamp, at = pdk._stamp(), sprack._core.__file__
        sprack._core.__file__ = os.path.join(d, "m.lib")
        try:
            assert pdk._stamp() != stamp
        finally:
            sprack._core.__file__ = at
    _tiny(body)


def test_tiny_pdk_manifest():
    def body(make, d):
        # A manifest says what it lacks, and what one needs.
        raises(sprack.SprackError, lambda: make(manifest={"name": "tiny", "layouts": [{}]}),
               "the manifest for PDK 'tiny' lacks dialect, corners, probe (of a layout); a manifest needs: name, dialect, layouts, corners")
        # With no `env`, the root is $PDK_ROOT, as the message says.
        old = os.environ.pop("PDK_ROOT", None)
        try:
            raises(sprack.SprackError, lambda: make(root=None), "tiny: give root=, or set $PDK_ROOT")
            os.environ["PDK_ROOT"] = d
            assert make(root=None).root == d
            raises(sprack.SprackError, lambda: make(root=None, manifest={**TINY, "env": ["TINY_ROOT"]}), "set $TINY_ROOT")
        finally:
            os.environ.pop("PDK_ROOT", None)
            if old is not None:
                os.environ["PDK_ROOT"] = old
    _tiny(body)


def test_tiny_pdk_cache_is_not_stale():
    def body(make, d):
        def xyce(pdk):
            return "".join(open(os.path.join(at, n)).read() for at, _, names in os.walk(pdk.translate("xyce")) for n in names)
        assert "cell" in make().devices and ".subckt cell a b" in xyce(make())
        # A file reached through an include changes: the catalogue and the copy follow.
        with open(os.path.join(d, "cells.inc"), "a") as f:
            f.write(".subckt more a b\nR1 a b 2k\n.ends more\n")
        assert "more" in make().devices and ".subckt more a b" in xyce(make())
        # The manifest reads the files another way: nothing of the old reading is kept.
        os.mkdir(os.path.join(d, "alt"))
        with open(os.path.join(d, "alt", "cells.inc"), "w") as f:
            f.write("* others\n.subckt other a b\nR1 a b 3k\n.ends other\n")
        alt = lambda: make(manifest={**TINY, "define": {"CELLS": "{root}/alt"}})
        assert "other" in alt().devices and "cell" not in alt().devices
        assert ".subckt other a b" in xyce(alt())
    _tiny(body)


def test_tiny_pdk_dialect_is_resolved():
    def body(make, d):
        def own(pdk, target):
            """The netlist for the PDK's own dialect names the PDK's own file."""
            c = sprack.Circuit("t", pdk=pdk)
            c.cell("X1", "a", 0)
            c.V("1", "a", 0, 1)
            c.op()
            return f'.lib "{os.path.join(d, "m.lib")}" tt\n' in unwrap(c.netlist(target))
        # A name in any case is the dialect, as everywhere else.
        pdk = make(manifest={**TINY, "dialect": "NGSPICE"})
        assert pdk.dialect == "ngspice" and own(pdk, "ngspice")
        raises(ValueError, lambda: make(manifest={**TINY, "dialect": "pspice"}), "unknown dialect 'pspice'")
        # A grammar file is looked for from the manifest file that names it.
        os.mkdir(os.path.join(d, "g"))
        mine = os.path.join(d, "g", "mine.spgrammar")
        with open(os.path.join(GRAMMARS, "ngspice.spgrammar")) as f, open(mine, "w") as g:
            g.write(f.read().replace("\ndialect ngspice\n", "\ndialect mine\n"))
        manifest = os.path.join(d, "tiny.json")
        with open(manifest, "w") as f:
            json.dump({**TINY, "dialect": "g/mine.spgrammar"}, f)
        pdk = make(manifest=manifest)
        assert pdk.dialect == mine and "cell" in pdk.devices and own(pdk, mine)
    _tiny(body)


def test_cache_follows_include_variables():
    def body(make, d):
        # Two sets of cells; $TINY_CELLS in the library's include path says which.
        for sub, cell in (("one", "first"), ("two", "second")):
            os.mkdir(os.path.join(d, sub))
            with open(os.path.join(d, sub, "cells.inc"), "w") as f:
                f.write(f"* {sub}\n.subckt {cell} a b\nR1 a b 1k\n.ends {cell}\n")
        with open(os.path.join(d, "m.lib"), "w") as f:
            f.write('* tiny\n.lib tt\n.include "$TINY_CELLS/cells.inc"\n.endl tt\n')
        pdk = lambda: make(manifest={**TINY, "define": {}})
        c = sprack.Circuit("t")
        c.code(f'.lib "{d}/m.lib" tt\n')

        def included(tree):
            path = os.path.join(tree, open(os.path.join(tree, "m.lib")).read().split('.include "')[1].split('"')[0])
            text = open(path).read() if os.path.isfile(path) else ""
            return [n for n in ("first", "second") if f".subckt {n} a b" in text]

        def read():
            """The subcircuits in the catalogue, in what the PDK's copy for
            Xyce includes, and in what the copy of a code block's library does."""
            copy = unwrap(c.netlist("xyce", strict=False)).split('.lib "')[1].split('"')[0]
            return [sorted(pdk().devices), included(pdk().translate("xyce", strict=False)), included(os.path.dirname(copy))]
        try:
            os.environ["TINY_CELLS"] = os.path.join(d, "one")
            assert read() == [["first"]] * 3, read()
            assert read() == [["first"]] * 3
            # Another value reaches other files: nothing read with the old one is kept.
            os.environ["TINY_CELLS"] = os.path.join(d, "two")
            assert read() == [["second"]] * 3, read()
            del os.environ["TINY_CELLS"]
            assert read() == [[]] * 3, read()
            os.environ["TINY_CELLS"] = os.path.join(d, "one")
            assert read() == [["first"]] * 3, read()
            # A variable no include path names is not looked at: the entries stay.
            marks = lambda: sorted((p, os.stat(p).st_mtime_ns) for at, _, names in os.walk(d) for n in names if n.endswith(".json") for p in [os.path.join(at, n)])
            before = marks()
            os.environ["TINY_OTHER"] = "x"
            assert read() == [["first"]] * 3 and marks() == before and len(before) == 2
        finally:
            os.environ.pop("TINY_CELLS", None)
            os.environ.pop("TINY_OTHER", None)
    _with_cache(lambda cache: _tiny(body))


def test_tiny_pdk_corner_must_be_there():
    def body(make, d):
        corners = {**TINY["corners"], "ff": [["m.lib", "ff"]], "ss": [["gone.lib", "ss"]]}
        pdk = lambda **kw: make(manifest={**TINY, "corners": corners}, **kw)
        # A corner the PDK is not asked for may be incomplete.
        assert "cell" in pdk().devices
        # A file that is not there: said when the corner is chosen.
        raises(sprack.SprackError, lambda: pdk(corner="ss"), "tiny: corner 'ss' names", "gone.lib, which is not there")
        # A section that is not there: said when the files are read, whatever the target.
        raises(sprack.SprackError, lambda: pdk(corner="ff").devices, "tiny: corner 'ff' names section 'ff' of", "m.lib, which defines: tt")
        c = sprack.Circuit("t", pdk=pdk(corner="ff"))
        c.op()
        for target in ("ngspice", "xyce"):
            raises(sprack.SprackError, lambda: c.netlist(target, strict=False), "names section 'ff'")
        raises(sprack.Unsupported, lambda: pdk(corner="ff").translate("xyce"), "section 'ff' is asked for, but no file read defines it")
    _tiny(body)


def test_netlist_leaves_the_circuit_as_it_is():
    def body(make, d):
        # A library whose model Spectre has to rename: a subcircuit has the name too.
        with open(os.path.join(d, "both.lib"), "w") as f:
            f.write("* both\n.model dm d is=1e-14\n.subckt dm a b\nD1 a b dm\n.ends dm\n")
        # And the PDK has one of its own.
        with open(os.path.join(d, "cells.inc"), "a") as f:
            f.write(".model pm d is=1e-14\n.subckt pm a b\nD1 a b pm\n.ends pm\n")
        c = sprack.Circuit("t", pdk=make())
        c.code(f'.include "{d}/both.lib"\n')
        with c.subckt("wrap", "a", "b") as s:
            s.code(f'.include "{d}/both.lib"\n')
            s.D("1", "a", "b", "dm")
        c.D("2", "a", 0, "dm")
        c.D("3", "a", 0, "pm")
        c.cell("X1", "a", 0)
        c.V("1", "a", 0, 1)
        c.op()
        before = copy.deepcopy(c.statements)
        out = unwrap(c.netlist("spectre", strict=False))
        # The translated copy and the renamed model are in the netlist only.
        assert out.count(f'include "{os.path.join(os.environ["SPRACK_CACHE"], "libs", "")}') == 2 and f"{d}/both.lib" not in out, out
        assert "D1 (a b) dm__m\n" in out and "D2 (a 0) dm__m\n" in out and "D3 (a 0) pm__m\n" in out, out
        assert c.statements == before
    _with_cache(lambda cache: _tiny(body))


def test_tiny_pdk_library_is_not_foreign():
    def body(make, d):
        # Also for a circuit in another dialect's terms than the PDK's.
        for own in (None, "hspice"):
            c = sprack.Circuit("t", pdk=make(), dialect=own)
            c.cell("X1", "a", 0)
            c.V("1", "a", 0, 1)
            c.op()
            # The PDK's own file, or its translated copy: neither is left to translate.
            for target, path in (("ngspice", os.path.join(d, "m.lib")), ("xyce", os.path.join(d, "cache", "tiny"))):
                out = c.netlist(target)
                assert f'.lib "{path}' in unwrap(out), out
                assert not [e for e in out.report if "translate that file too" in e.message], out.report
    _tiny(body)


# One deck that says a bit of everything, in ngspice.
DECK = """Rich deck
* a comment
.param vdd=1.8 rload=2k
.model nch nmos level=54 version=4.5 vth0=0.4
.model dm d is=1e-14
.subckt inv in out vdd wn=1u
Mn out in 0 0 nch w={wn} l=180n
Rb out 0 1MEG
.ends inv
Vdd vdd 0 {vdd}
Vin in 0 DC 0 AC 1 PULSE(0 1.8 1n 50p 50p 2n 4n)
I1 0 out DC 1M $ one milliamp
X1 in mid vdd inv wn=2u
R1 mid out {rload} tc1=1m
C1 out 0 10f

D1 out 0 dm
E1 e 0 mid 0 2
L1 out l2 10n
.options reltol=1e-4 temp=27 method=gear
.ic v(out)=0
.save v(out) i(Vdd)
.print tran v(in,out)
.op
.dc Vin 0 1.8 0.01
.ac dec 10 1 1G
.tran 10p 8n uic
.end
"""


def _decks():
    """DECK as each dialect says it (what a dialect cannot say is left out);
    structural Verilog is written, never read."""
    for d in sprack.DIALECTS:
        if d == "verilog":
            continue
        yield d, (DECK if d == "ngspice" else str(sprack.translate(DECK, frm="ngspice", to=d, strict=False)))


def _same(a, b):
    """Two netlists with their reports, blank lines aside."""
    lines = lambda t: [l for l in str(t).split("\n") if l.strip()]
    said = lambda t: [(e.severity, e.code, e.message) for e in t.report]
    return lines(a) == lines(b) and said(a) == said(b)


def test_read_then_write_is_translate():
    # The Python path (read to statements, write them) is the translator.
    for d, src in _decks():
        for t in sprack.DIALECTS:
            direct = sprack.translate(src, frm=d, to=t, strict=False)
            assert str(sprack.read(src, d).netlist(t, strict=False)) == str(direct), f"{d} -> {t}"
    # Spectre's insensitive=yes is the netlist's, not a statement's: it stays.
    scs = "// t\nsimulator lang=spectre insensitive=yes\nR1 (a 0) resistor r=1k\n"
    assert "insensitive=yes" in sprack.read(scs, "spectre").netlist("spectre")
    # Through the statements as JSON: a dotted version stays a word, a
    # parameter given twice stays twice, a negated signal an expression.
    for src, want in [("t\n.model n3 nmos level=49 version=3.3.0\n.end\n", "version=3.3.0\n"),
                      ("t\n.model p1 pmos level=54 toxref=1.26n vsat=69000 toxref=1.3n\n.end\n", "vsat=69000 toxref=1.3n\n"),
                      ("t\n.print dc -i(vc) v(a)\n.end\n", ".print dc -i(vc) v(a)\n")]:
        out = sprack.read(src, "ngspice").netlist("ngspice", strict=False)
        assert want in out, out
        assert _same(out, sprack.translate(src, frm="ngspice", to="ngspice", strict=False)), out.report


def test_a_node_is_not_the_source_on_it():
    # A source Vdd on a node vdd: two names, each with its own spelling,
    # read from a dialect that ignores case or built here.
    deck = "t\nVdd vdd 0 1\nR1 vdd out 1k\nR2 out 0 1k\n.op\n.end\n"
    read = sprack.read(deck, "ngspice")
    assert [(s["name"], s["pos"]) for s in read.statements[:2]] == [("Vdd", "vdd"), ("R1", "vdd")]
    c = sprack.Circuit("t")
    c.folds_case = True
    c.vsource("Vdd", "vdd", 0, dc=1)
    c.resistor("R1", "vdd", "out", r="1k")
    c.resistor("R2", "out", 0, r="1k")
    c.op()
    for t in ("ngspice", "xyce", "spectre"):
        out = c.netlist(t)
        assert not list(out.report), out.report
        assert ("Vdd (vdd 0) vsource dc=1\n" if t == "spectre" else "Vdd vdd 0 dc 1\nR1 vdd out 1k\n") in out, out
        assert str(out) == str(read.netlist(t)), t


def _flat(code):
    """Only imports, assignments, calls and `with` blocks: no def, no class."""
    import ast

    def ok(nodes):
        return all(isinstance(n, (ast.Import, ast.Assign, ast.Expr, ast.Pass)) or isinstance(n, ast.With) and ok(n.body) for n in nodes)
    return ok(ast.parse(code).body)


def _run(code):
    scope = {}
    exec(code, scope)
    return scope["c"]


def test_to_python():
    # Any dialect to a script of builder calls; the script builds a circuit
    # that every dialect is written from exactly as from the netlist.
    for d, src in _decks():
        code = sprack.to_python(src, d)
        assert _flat(code), code
        assert ".code(" not in code and "statements.append" not in code, code
        c2 = _run(code)
        for t in sprack.DIALECTS:
            assert _same(c2.netlist(t, strict=False), sprack.read(src, d).netlist(t, strict=False)), f"{d} -> python -> {t}\n{code}"
    code = sprack.to_python(DECK, "ngspice")
    for line in ['c = sprack.Circuit("Rich deck", dialect="ngspice")', 'c.param(vdd=1.8, rload="2k")',
                 'c.model("nch", "bsim4", "n", version=4.5, vth0=0.4)', 'c.model("dm", "diode", **{"is": 1e-14})',
                 'with c.subckt("inv", "in", "out", "vdd", wn="1u") as s:', '    s.M("n", "out", "in", 0, 0, "nch", w="wn", l="180n")',
                 'c.V("in", "in", 0, 0, ac=1, pulse=(0, 1.8, "1n", "50p", "50p", "2n", "4n"))',
                 'c.I("1", 0, "out", "1m").tail("one milliamp")', 'c.R("1", "mid", "out", "rload", tc1="1m")',
                 'c.ic({"out": 0})', 'c.save("v(out)", "i(Vdd)")', 'c.print_("tran", "v(in,out)")',
                 'c.dc("Vin", 0, 1.8, 0.01)', 'c.tran("10p", "8n", uic=True)']:
        assert line + "\n" in code, f"missing {line!r} in\n{code}"
    assert "\n\nc.D(" in code  # a blank line of the netlist is one of the script
    # A circuit built here says itself the same way, and the script of the
    # script's circuit is the script.
    assert _run(build().python()).statements == build().statements
    assert _run(code).python() == code.replace("\n\nc.D(", "\nc.D(")
    # Statements that hold others are `with` blocks: an alter, a sweep, a
    # conditional, a library section.
    hs = "t\n.param rv=1k\nV1 a 0 1\nR1 a 0 rv\n.op\n.alter hot\n.param rv=2k\n.temp 85\n.end\n"
    code = sprack.to_python(hs, "hspice")
    assert 'with c.alter("hot") as s:\n    s.param(rv="2k")\n    s.options(temp=85)\n' in code, code
    assert _same(_run(code).netlist("spectre", strict=False), sprack.translate(hs, frm="hspice", to="spectre", strict=False))
    ng = "t\n.lib tt\n.param a=1\n.if (a > 1)\nR1 a 0 1k\n.else\nR1 a 0 2k\n.endif\n.endl tt\n"
    code = sprack.to_python(ng, "ngspice")
    assert 'with c.libsection("tt") as s:' in code and "        s2.cond_else()\n" in code and ".code(" not in code, code
    assert _same(_run(code).netlist("ngspice", strict=False), sprack.translate(ng, frm="ngspice", to="ngspice", strict=False))
    # The one thing with no call: a line no rule of the dialect understood.
    # A control script is a block of its own (#50).
    out = sprack.to_python("t\nR1 a 0 1k\n.bogus 1 2\n.control\nrun\n.endc\n.end\n", "ngspice")
    assert 'c.code(".bogus 1 2\\n")\n' in out and 'with c.script() as s:\n    s.simctl("run")\n' in out, out
    assert out.report == []  # kept as they are: nothing to report until another dialect is asked for
    assert ".bogus 1 2\n" in _run(out).netlist("ngspice")
    assert ".control\nrun\n.endc\n" in _run(out).netlist("ngspice")


def test_xyce_plugins():
    # #52: a Verilog-A instance into Xyce is a Y line only with a plugin.
    cir = "t\n.model rmod r3_cmc rsh=100\nN1 a b c rmod w=1u\nv1 a 0 1\n.op\n.end\n"
    raises(sprack.Unsupported, lambda: sprack.translate(cir, frm="ngspice", to="xyce"), "only through a plugin of it")
    d = run_dir("plugins")
    open(os.path.join(d, "m.lib"), "w").write(".model rmod r3_cmc rsh=100\n.subckt rs a c\nN1 a b c rmod w=1u\n.ends\n")
    m = {"name": "x", "dialect": "ngspice", "layouts": [{"probe": "m.lib"}], "corners": {"tt": [["{root}/m.lib", ""]]},
         "xyce_plugins": {"r3_cmc": "r3.so", "mosvar": "{root}/missing.so"}}
    pdk = sprack.PDK("x", root=d, manifest=m, cache_dir=os.path.join(d, "cache"))
    assert pdk.run_options("xyce") == []
    raises(sprack.Unsupported, lambda: pdk.translate("xyce"), "only through a plugin of it")
    # A plugin built since: the libraries are translated again, for it.
    open(os.path.join(d, "r3.so"), "w").write("")
    pdk = sprack.PDK("x", root=d, manifest=m, cache_dir=os.path.join(d, "cache"))
    assert pdk.run_options("ngspice") == []
    assert pdk.run_options("xyce") == ["-plugin", os.path.join(d, "r3.so")]
    out = pdk.translate("xyce")
    assert "Yr3_cmc N1 a b c rmod w=1u" in open(os.path.join(out, os.path.relpath(pdk.entries()[0][0], pdk._roots["xyce"][1]))).read()


def test_pdk_env_reserved_params():
    # #71: a library parameter named like a Xyce variable (vt) is renamed in
    # the library's copy; a circuit on the PDK renames its uses the same
    # way, as `sprack project` does on the same files.
    d = run_dir("envjson")
    os.makedirs(os.path.join(d, "lib"))
    open(os.path.join(d, "lib", "models.lib"), "w").write("* toy\n.lib tt\n.param vt=0.4\n.model nch nmos level=54 vth0={vt}\n.endl tt\n")
    m = {"name": "toy", "dialect": "ngspice", "layouts": [{"probe": "models.lib"}], "corners": {"tt": [["models.lib", "tt"]]}}
    pdk = sprack.PDK("toy", root=os.path.join(d, "lib"), manifest=m, cache_dir=os.path.join(d, "cache"))
    assert "vt" in pdk._env["params"] and pdk._env["family_of"]["nch"] == "bsim4", pdk._env
    c = sprack.Circuit("toy", pdk=pdk)
    c.param(x="2*vt")
    c.V("dd", "d", 0, 1)
    c.nch("M1", "d", "d", 0, 0, w="1u", l="1u")
    c.R("1", "d", 0, "x")
    c.op()
    py = str(c.netlist("xyce", strict=False))
    top = os.path.join(d, "top.sp")
    open(top, "w").write('toy\n.lib "lib/models.lib" tt\n.param x={2*vt}\nVdd d 0 dc 1\nM1 d d 0 0 nch w=1u l=1u\nR1 d 0 {x}\n.op\n.end\n')
    sprack._core.project("ngspice", "xyce", top, os.path.join(d, "out"), "", False, "", "[]")
    proj = open(os.path.join(d, "out", "top.sp")).read()
    body = lambda t: [l for l in t.splitlines() if not l.startswith(".lib")]
    assert ".param x={2*vt__p}" in py and body(py) == body(proj), (py, proj)


def test_no_code_for_dialect_only_statements():
    # #51: a statement only its dialect has is a call of its words, not text.
    hs = "t\nr1 d 0 1k\n.acmatch v(d)\n.check edge (a b) 1n 2n\ns1 p1 p2 mname=smod\n.meas tran g1 find v(d) at=1m goal=2\n.end\n"
    out = sprack.to_python(hs, "hspice")
    assert ".code(" not in out and 'c.native("hspice", ".acmatch", "v(d)")' in out, out
    assert _same(_run(out).netlist("hspice"), sprack.translate(hs, frm="hspice", to="hspice"))
    raises(sprack.Unsupported, lambda: _run(out).netlist("xyce"), "is a hspice statement and cannot be written for xyce")
    v = 't\ncontrol\n  print stats\nendc\nembed "runme.py" <<<FILE\nprint(1)\n>>>FILE\n'
    out = sprack.to_python(v, "vacask")
    assert ".code(" not in out and 'c.embed("runme.py", "print(1)\\n")' in out, out
    assert 'embed "runme.py" <<<FILE\nprint(1)\n>>>FILE\n' in _run(out).netlist("vacask")


def _sample(slot, n=0):
    """A value of the JSON form for a slot of the vocabulary: of a closed
    word slot, one of its words, which is all the builder takes there."""
    if slot["type"] == "atom" and slot.get("closed"):
        one = slot["atoms"][0]
        return [one, one] if slot["list"] else one
    one = {"name": "x1", "node": f"n{n}", "ident": "m1", "ref": "V1", "value": "1.5e-9", "atom": "a1", "text": "some text",
           "path": {"str": "lib/f.inc"}, "signal": "v(n1)", "params": {"k1": "1e3", "is": "2*k1", "flag": None}}[slot["type"]]
    return [one, _sample({**slot, "list": False}, 1)] if slot["list"] else one


def test_everything_has_a_function():
    # The builder says the whole vocabulary: for every kind, a statement
    # with all its slots given, and one per slot with that slot alone, is
    # rebuilt by a call. No netlist text, no statement written by hand.
    holds = ("subckt", "libsection", "cond_if", "step", "statistics", "statgroup", "montecarlo", "library", "alter")
    count = 0
    for kind, info in sprack.KINDS.items():
        if kind in ("opaque", "comment", "annotation"):
            continue
        full = {"kind": kind, **{sl["name"]: _sample(sl) for sl in info["slots"]}}
        # A device is its name and, where it has one, its model: the builder refuses one without.
        # (And a print has a style: the builder says "print" where none is given.)
        least = {k: full[k] for k in ("name", "master") if k in full and info["class"] == "device"}
        if kind == "print":
            least["style"] = "plot"
        cases = [full] + [{"kind": kind, **least, sl["name"]: _sample(sl)} for sl in info["slots"]]
        if kind in holds:
            cases.append({**full, "body": [{"kind": "resistor", "name": "R1", "pos": "a", "neg": "0", "r": "1e3", "tail": "note"}]})
        for st in cases:
            c = sprack.Circuit("t")
            c.statements = [st]
            code = c.python()
            assert _flat(code) and "statements.append" not in code and ".code(" not in code, f"no call for {st}\n{code}"
            assert sprack._deep(_run(code).statements[0]) == sprack._deep(st), f"{st}\n{code}"
            count += 1
    assert count > 600, count
    # What a plain value cannot say has a function too.
    c = sprack.Circuit("t")
    c.model("n3", "bsim3", "n", version="3.3.0", flavour=sprack.word("a.b"), file=sprack.quoted("m.dat"), k=sprack.expr("13"))
    c.print_("dc", "-i(vc)", sprack.v("a"))
    c.add("param", params=[("czero", "1p"), ("dev/gauss", "0.1p"), ("cone", "2p"), ("dev/gauss", "0.2p")])
    c.tran("1n", "1u", ic={"out": 0.5})
    with c.subckt("cell", "a", "b", inline=True) as s:
        s.R("1", "a", "b", "1k").tail("the only one")
    ng = c.netlist("ngspice", strict=False)
    for line in [".model n3 nmos level=8 version=3.3.0 flavour=a.b file=\"m.dat\" k={13}", ".print dc -i(vc) v(a)",
                 # Each dev/gauss is the parameter's before it: both are kept.
                 ".param czero={agauss(1p, 0.1p, 1)} cone={agauss(2p, 0.2p, 1)}", "R1 a b 1k $ the only one"]:
        assert line + "\n" in ng, f"missing {line!r} in\n{ng}"
    assert ".param czero=1p dev/gauss=0.1p cone=2p dev/gauss=0.2p\n" in c.netlist("hspice", strict=False)
    assert "inline subckt cell (a b)\n" in c.netlist("spectre", strict=False)
    assert "ic={\"out\",0.5}" in c.netlist("vacask", strict=False)
    # A slot an alias would hide is still its own: `model` of a `vary` is not a device's model.
    assert c.vary("vth0", "gauss", "0.01", model="nch")["model"] == "nch"


def _peak_mib():
    """This process's peak resident memory so far, in MiB (None where unknown)."""
    try:
        import resource
    except ImportError:
        return None
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak / (1 << 20) if sys.platform == "darwin" else peak / 1024


def _rss_mib():
    """Resident memory now, in MiB, from /proc (None elsewhere)."""
    try:
        with open("/proc/self/statm") as f:
            return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE") / (1 << 20)
    except (OSError, ValueError, AttributeError):
        return None


def test_memory():
    # Bounds about three times what was measured (issue 63), so a runaway is
    # a failed test, not a machine out of memory.
    # Reading a 4 MB deck whole: under 60 times its size (38 measured).
    deck = "t\n" + "".join(f"R{k} n{k} n{k + 1} 1k\nC{k} n{k + 1} 0 1p\n" for k in range(100000)) + ".tran 1n 1u\n.end\n"
    before = _rss_mib()
    c = sprack.Circuit.read(deck, "ngspice")
    after = _rss_mib()
    if before is not None:
        assert after - before < 60 * len(deck) / (1 << 20), f"reading {len(deck) >> 20} MiB took {after - before:.0f} MiB"
    del c
    # 1,000 translations: resident memory grows by less than 4 MiB.
    small = "t\nR1 a 0 1k\nC1 a 0 1p\nV1 a 0 1\n.tran 1n 1u\n.end\n"
    for _ in range(50):
        sprack.translate(small, frm="ngspice", to="spectre")
    start = _rss_mib()
    for _ in range(1000):
        sprack.translate(small, frm="ngspice", to="spectre")
    if start is not None:
        grew = _rss_mib() - start
        assert grew < 4, f"1000 translations grew resident memory by {grew:.1f} MiB"
    # A PDK's catalogue and one netlist per target: peak under 150 MiB.
    if PDKS:
        pdk = sprack.PDK("ihp-sg13g2", root=os.path.join(PDKS, "ihp"), cache_dir=run_dir("memory"))
        n = sprack.Circuit("one", pdk=pdk)
        n.sg13_lv_nmos("M1", "d", "g", 0, 0)
        n.V("d", "d", 0, 1.2)
        n.op()
        for d in ("ngspice", "hspice", "xyce", "spectre", "vacask"):
            n.netlist(d, strict=False)
        peak = _peak_mib()
        if peak is not None:
            # The deck above was read in this process too: its peak counts.
            assert peak < 150 + 60 * len(deck) / (1 << 20), f"peak {peak:.0f} MiB"


def _limit_memory(gib):
    """An address-space limit for this run, where the platform has one: a
    runaway raises MemoryError in the test that caused it (issue 63)."""
    try:
        import resource
        soft, hard = resource.getrlimit(resource.RLIMIT_AS)
        want = gib << 30
        if hard == resource.RLIM_INFINITY or hard > want:
            resource.setrlimit(resource.RLIMIT_AS, (want, hard))
    except (ImportError, ValueError, OSError, AttributeError):
        pass


def test_hints_are_annotation_lines_in_their_scope():
    c = sprack.Circuit("amp")
    c.hint("order", "m1", "m2")
    with c.subckt("inv", "a", "y", "vdd") as s:
        s.hint("left", "a")
        s.M("1", "y", "a", "vdd", "vdd", model="pmos", w="1u")
    c.X("1", "in", "out", "vdd", model="inv")
    c.tran("1n", "1u")
    c.hints.append(sprack.Hint("face", ("m1.g", "left"), weak=True))
    assert [h.verb for h in c.hints] == ["order", "face"]
    assert c.subckt_hints("inv")[0] == sprack.Hint("left", ("a",), scope="inv")
    # A rename reaches the hints: a name, and the device before `.pin`; never
    # a keyword.
    c.rename("m1", "mp")
    assert list(c.hints)[1].args == ("mp.g", "left")
    ng = c.netlist("ngspice", strict=False)
    assert "*@ order mp m2\n*@ weak face mp.g left\n.subckt inv a y vdd\n*@ left a\n" in ng
    assert "// *@ left a\n" in c.netlist("spectre", strict=False)
    # The drawing target: the circuit only, the hints as they are.
    ck = c.netlist("cktimg", strict=False)
    assert ".tran" not in ck and "*@ left a\n" in ck
    assert any("not written: cktimg draws the circuit" in e.message for e in ck.report)
    del c.hints[0]
    c.hints.insert(0, sprack.Hint("order", ("m2", "mp")))
    assert [h.args for h in c.hints] == [("m2", "mp"), ("mp.g", "left")]


def test_api_research_proposals():
    # The changes of the API review, each as its user writes it.
    c = sprack.Circuit("t")
    assert "tran" in dir(c) and c.measure.__name__ == "measure" and "op" in c.measure.__doc__
    raises(AttributeError, lambda: c.trans, "Did you mean")
    vin = c.V("in", "in", 0, 1)
    r1 = c.R("1", "in", "out", "1k")
    c.dc(vin, 0, 1, 0.1)
    c.save(sprack.i(vin))
    c.hint("order", vin, r1)
    assert c.hints[0].args == ("Vin", "R1")
    c.measure("tran", "vpp", "pp", "v(out)", from_="1n", to="2n")
    c.model("d1", "diode", lambda_=0.02, is_=1e-14)
    c.vsource("V2", "a", 0, pulse=(0, 1.8, 0, "50p", "50p", "2n", "4n"))
    c.hints.append("weak face R1.n left")
    assert sprack.Hint("order", "m1 m2").text() == "order m1 m2"
    raises(ValueError, lambda: c.measure("tran", "x", "average", "v(out)"), "measure.op is one of")
    raises(TypeError, lambda: c.V("3", "a", 0, pulse=dict(rise_time="1n")), "pulse has no 'rise_time'")
    ng = c.netlist("ngspice")
    assert ".dc Vin 0 1 0.1\n" in ng and "*@ order Vin R1\n" in ng and "lambda=0.02" in ng and "from=1n" in ng, ng
    assert ng.report.ok
    # A value: one error, which says what was meant, not a second for the slot.
    d = sprack.Circuit("t")
    d.R("1", "a", 0, "1g")
    assert [e.message.split(";")[0] for e in d.check("ngspice").errors] == ["'1g' is not a number: write 1G"]
    # One error for a measure that says what only one word's forms say.
    m = sprack.Circuit("t")
    m.measure("tran", "tpd", trig="v(in)", trigval=0.5, targ="v(out)", targval=0.5)
    errs = m.check("ngspice").errors
    assert len(errs) == 1 and "'op' is not given" in errs[0].message, errs
    # Paths are paths; text that names a file is refused.
    with tempfile.TemporaryDirectory() as d2:
        p = os.path.join(d2, "deck.sp")
        with open(p, "w") as f:
            f.write("rc\nR1 a 0 1k\n.end\n")
        assert sprack.read(pathlib.Path(p), "ngspice").statements[0]["name"] == "R1"
        raises(sprack.SprackError, lambda: sprack.read(p, "ngspice"), "pathlib.Path")
    # A subcircuit of a netlist read, edited; written as a file to include.
    r = sprack.read("t\n.subckt inv a y\nR1 a y 1k\n.ends\n.end\n", "ngspice")
    r.scope("inv").C("1", "y", 0, "1p")
    lib = r.netlist("ngspice", library=True)
    assert "C1 y 0 1p\n" in lib and ".end\n" not in lib, lib
    # rename by name space, in one scope; what it does not follow comes back.
    r = sprack.read("t\n.param b=2\nRb b 0 {b}\nB1 x 0 v={v(b)*2}\n.save v(b)\n.model b d\nD1 b 0 b\n.end\n", "ngspice")
    left = r.rename("b", "vout", space="node")
    n = r.netlist("ngspice", strict=False)
    assert "Rb vout 0 {b}\n" in n and ".save v(vout)\n" in n and ".model b d\n" in n and "D1 vout 0 b\n" in n, n
    assert [s["name"] for s in left] == ["B1"]


def test_place_and_draw_go_to_cktimg_package():
    # cktImg's own package, where it can be imported: the deck as text, the
    # keywords passed through, the command named as `exe`.
    import types
    seen = {}
    fake = types.ModuleType("cktimg")
    def place(deck, **kw):
        seen["place"] = (deck, kw)
        return {"devices": []}, {"requests": []}
    def draw(deck, **kw):
        seen["draw"] = (deck, kw)
        return "<svg/>", {"requests": []}
    fake.place, fake.draw = place, draw
    sys.modules["cktimg"] = fake
    try:
        c = sprack.Circuit("t")
        c.R("1", "a", 0, "1k")
        c.hint("order", "R1")
        assert c.place(symbols="s.zon", start="last.json") == ({"devices": []}, {"requests": []})
        deck, kw = seen["place"]
        assert "*@ order R1\n" in deck and kw == dict(symbols="s.zon", target=None, start="last.json", config=None, exe=None)
        assert c.draw(cktimg="/opt/cktimg-json")[0] == "<svg/>" and seen["draw"][1]["exe"] == "/opt/cktimg-json"
    finally:
        del sys.modules["cktimg"]


def test_schemify_script_keeps_run():
    # A command built here is the target's own: ngspice keeps its `run`.
    c = sprack.Circuit("t")
    c.R("1", "a", 0, "1k")
    c.V("1", "a", 0, 1)
    with c.script() as s:
        s.op()
        s.simctl("run")
    assert ".control\nop\nrun\n.endc\n" in c.netlist("ngspice"), c.netlist("ngspice")


def test_schemify_hdl_is_the_compiled_module_for_ngspice():
    # ngspice loads what OpenVAF compiles x.va to; VACASK compiles it itself.
    c = sprack.Circuit("t")
    c.hdl("x.va")
    c.R("1", "a", 0, "1k")
    assert "pre_osdi x.osdi\n" in c.netlist("ngspice"), c.netlist("ngspice")
    assert 'load "x.va"\n' in c.netlist("vacask"), c.netlist("vacask")


def test_schemify_save_is_a_print_for_xyce():
    # Xyce prints what an analysis records: a save is a .print of each.
    c = sprack.Circuit("t")
    c.R("1", "a", 0, "1k")
    c.V("1", "a", 0, 1)
    c.save("v(a)")
    c.tran("1n", "10n")
    assert ".print tran v(a)\n" in c.netlist("xyce"), c.netlist("xyce")
    # Xyce prints an operating point with .print dc: one line for .op and .dc.
    o = sprack.Circuit("t")
    o.R("1", "a", 0, "1k")
    o.V("1", "a", 0, 1)
    o.save("v(a)")
    o.op()
    assert ".print dc v(a)\n" in o.netlist("xyce"), o.netlist("xyce")


def test_a_stage_name_is_never_renamed():
    # cktImg's `stage <name>`: a stage may be named as a device is.
    c = sprack.Circuit("t")
    c.hint("stage", "M1", "M2")
    c.hint("order", "M1", "M2")
    c.M("1", "y", "a", 0, 0, "nch")
    c.M("2", "y", "a", 0, 0, "nch")
    assert c.hints.stages == {"M1"}
    c.rename("M1", "MA")
    c.rename("M2", "MB")
    assert [h.text() for h in c.hints] == ["stage M1 MB", "order M1 MB"]
    assert c.statements[2]["name"] == "MA"
    with c.subckt("s", "a") as s:
        s.hint("weak", "x")
        s.hint("order", "M1")
    c.scope("s").rename("M1", "MZ", space="instance")
    assert c.scope("s").hints[1].args == ("MZ",)  # no stage M1 in that scope
    assert sprack.Hint("stage", ("M1",)).renamed("m1", "X") == sprack.Hint("stage", ("M1",))
    assert sprack.Hint("face", ("M1.g",)).renamed("m1", "X", {"M1"}).args == ("M1.g",)
    # The net of `wire`/`label <net> at <dev>.<pin> ...` is no device.
    assert sprack.Hint("wire", ("r1", "at", "R1.p", "R2.n")).renamed("r1", "RX").args == ("r1", "at", "RX.p", "R2.n")
    # face <block> <port> <side>: the block is a device, the port is not.
    assert sprack.Hint("face", ("X1", "X1", "left")).renamed("x1", "XA").args == ("XA", "X1", "left")
    f = sprack.Circuit("t")
    f.hint("face", "X1", "in", "left")
    f.rename("in", "vin")
    assert f.hints[0].args == ("X1", "in", "left")


def test_statement_in_a_dialects_own_terms():
    c = sprack.Circuit("t")
    c.R("1", "a", 0, "1k")
    # Without a dialect the vocabulary is closed; with one, its own options.
    raises(TypeError, lambda: c.options(plotwinsize=0), "options has no 'plotwinsize'")
    o = c.options(dialect="ltspice", plotwinsize=0, numdgt=15)
    assert o["dialect"] == "ltspice" and o["params"] == {"plotwinsize": "0", "numdgt": "15"}
    assert ".options plotwinsize=0 numdgt=15\n" in c.netlist("ltspice")
    # For another dialect it is reported as any line of another dialect is.
    errs = c.check("ngspice").errors
    assert [e.message for e in errs] == ["options: 'plotwinsize=0' has no spelling in ngspice",
                                         "options: 'numdgt=15' has no spelling in ngspice"], errs
    raises(ValueError, lambda: c.options(dialect="nosuch", x=1), "unknown dialect")
    # A library in a dialect's terms: as is for that dialect, translated for another.
    with tempfile.TemporaryDirectory() as d:
        lib = os.path.join(d, "kit.lib")
        with open(lib, "w") as f:
            f.write(".lib tt\n.model nch nmos level=8\n.endl tt\n")
        k = sprack.Circuit("t")
        k.lib(lib, "tt", dialect="ngspice")
        assert k.statements[0]["dialect"] == "ngspice"
        assert f'.lib "{lib}" tt\n' in k.netlist("ngspice")
        hs = k.netlist("hspice", strict=False)
        assert lib not in hs and ".lib " in hs, hs
    # The script says it again.
    assert 'c.options(dialect="ltspice", plotwinsize=0, numdgt=15)' in c.python()


def test_to_python_title_and_node_case():
    # The title line a dialect reads as a comment is that comment's text;
    # where `*` is no comment (VACASK), the title is the line.
    for d in ("ngspice", "hspice", "xyce", "ltspice"):
        assert 'sprack.Circuit("My Title"' in sprack.to_python("* My Title\nR1 Out 0 1k\n.end\n", d), d
    assert 'sprack.Circuit("My Title"' in sprack.to_python("My Title\nR1 Out 0 1k\n.end\n", "ngspice")
    # A node keeps its case in its own scope, through every built-in reader:
    # the top level's in and out are not the subcircuit's IN and OUT.
    src = "* tb\nVVIN in 0 dc 0.9\nX1 in out vdd! chain\n.subckt chain IN OUT VDD\nR1 IN OUT 1k\n.ends chain\n.end\n"
    for d in sprack.DIALECTS:
        if d == "verilog":  # written, never read back
            continue
        script = sprack.to_python(sprack.translate(src, frm="ngspice", to=d, strict=False), d)
        assert 'c.X("1", "in", "out", "vdd!", "chain")' in script, (d, script)
        assert 'with c.subckt("chain", "IN", "OUT", "VDD") as s:\n    s.R("1", "IN", "OUT", "1k")' in script, (d, script)
    ng = sprack.read(src, "ngspice").netlist("ngspice")
    assert "VVIN in 0 dc 0.9\nX1 in out vdd! chain\n" in ng, ng


def test_device_parameter_signal():
    c = sprack.Circuit("t")
    m1 = c.M("1", "d", "g", 0, 0, "nch")
    c.model("nch", "bsim4", "n")
    c.save(sprack.p(m1, "gm"), sprack.p("M2", "vth"), sprack.v("d"))
    assert c.statements[-1]["signals"][0] == "p(M1,gm)"
    assert ".save @M1[gm] @M2[vth] v(d)\n" in c.netlist("ngspice")
    # A target with no spelling for it reports it, as any signal it cannot say.
    raises(sprack.Unsupported, lambda: c.netlist("hspice"), "can say the signal p(M1,gm)")
    # Read back from ngspice, and renamed with the device, never the parameter.
    r = sprack.read("t\nM1 d g 0 0 nch\n.save @m1[gm]\n.end\n", "ngspice")
    # The device as the netlist declares it.
    assert r.statements[-1]["signals"] == ["p(M1,gm)"]
    r.rename("m1", "mx", space="instance")
    assert ".save @mx[gm]\n" in r.netlist("ngspice", strict=False)
    assert 'c.save("p(m1,gm)")' in sprack.to_python("t\n.save @m1[gm]\n.end\n", "ngspice")


def _dig_tb():
    # Schemify's dig_tb: an inverter of Verilog at the top and in a subcircuit.
    c = sprack.Circuit("dig_tb")
    inv = dict(file="dinv.v", pins=["A", "Y"], dirs=["in", "out"])
    c.verilog("UX", "q[0]", "qb", "dinv", code="module dinv(input A, output Y);\n  assign Y = ~A;\nendmodule", **inv)
    c.instance("B[0]", "d[0]", "q[0]", "dbuf")
    c.instance("B[1]", "d[1]", "q[1]", "dbuf")
    with c.subckt("dbuf", "A", "Y") as s:
        s.verilog("U1", "A", "net_0w0001", "dinv", **inv)
        s.verilog("U2", "net_0w0001", "Y", "dinv", **inv)
    return c


def test_schemify_verilog_is_d_cosim_in_ngspice_and_an_n_card_in_espice():
    out = _dig_tb().netlist("ngspice")
    assert "AUX [ q[0] ] [ qb ] dinv\nXB[0] d[0] q[0] dbuf\n" in out, out
    assert "AU1 [ A ] [ net_0w0001 ] dinv\n" in out, out
    assert '.ends dbuf\n.model dinv d_cosim simulation="dinv.vvp"\n.end\n' in out, out
    # sar_tb: a bus bit by bit from its left index, the bridge's parameters.
    c = sprack.Circuit("sar_tb")
    c.hdl("cdac.va")
    c.model("cdac_m", type="cdac")
    c.N("DAC", *[f"d[{i}]" for i in range(7, -1, -1)], "vdac", "cdac_m")
    bits = [f"d[{i}]" for i in range(7, -1, -1)]
    c.verilog("U1", "clk", "rst", "cmp", *bits, "eoc", "sar_m", module="sar", file="sar.v",
              pins=["clk", "rst", "cmp"] + ["d"] * 8 + ["eoc"], dirs=["in"] * 3 + ["out"] * 9,
              vdd=1.8, vth=0.9, rout=100)
    es = c.netlist("espice")
    assert "NDAC d[7] d[6] d[5] d[4] d[3] d[2] d[1] d[0] vdac cdac_m\n" in es, es
    assert "NU1 clk rst cmp d[7] d[6] d[5] d[4] d[3] d[2] d[1] d[0] eoc sar_m vdd=1.8 vth=0.9 rout=100\n" in es, es
    assert '.hdl "cdac.va"\n.model cdac_m cdac\n' in es and '.model sar_m sar\n.verilog "sar.v"\n.end\n' in es, es
    ng = c.netlist("ngspice", strict=False)
    assert "AU1 [ clk rst cmp ] [ d[7] d[6] d[5] d[4] d[3] d[2] d[1] d[0] eoc ] sar_m\n" in ng, ng
    # A dialect without Verilog refuses it, naming who has it.
    raises(sprack.Unsupported, lambda: _dig_tb().netlist("xyce"), "Xyce has no digital Verilog", "ngspice")


def test_schemify_structural_verilog():
    out = _dig_tb().netlist("verilog")
    assert out.startswith("// dig_tb\nmodule dig_tb ();\n  wire \\d[0] ;\n"), out
    assert "  dbuf \\B[0]  (.A(\\d[0] ), .Y(\\q[0] ));\n" in out, out
    assert "module dbuf (A, Y);\n  input A;\n  output Y;\n  wire net_0w0001;\n" in out, out
    assert out.endswith("endmodule\nmodule dinv(input A, output Y);\n  assign Y = ~A;\nendmodule\n"), out
    # A bus port is joined; a source is left out with a note, a resistor refused.
    c = sprack.Circuit("t")
    c.verilog("U1", "clk", "q[1]", "q[0]", "cnt", file="cnt.v", pins=["clk", "q", "q"], dirs=["in", "out", "out"], vdd=1.8)
    c.V("1", "clk", 0, 1.8)
    assert "  cnt U1 (.clk(clk), .q({\\q[1] , \\q[0] }));\n" in c.netlist("verilog"), c.netlist("verilog")
    c.R("1", "clk", 0, "1k")
    raises(sprack.Unsupported, lambda: c.netlist("verilog"), "structural Verilog holds only modules")


if __name__ == "__main__":
    # Room for the ngspice runs the tests start (separate processes with
    # their own limit, inherited); SPRACK_TEST_MEMORY_GIB changes it.
    _limit_memory(int(os.environ.get("SPRACK_TEST_MEMORY_GIB", "8")))
    failed = skipped = 0
    for name, fn in list(globals().items()):
        if not name.startswith("test_"):
            continue
        if name.startswith("test_pdk_installed_") and not INSTALLED:
            print(f"skip  {name} (set SPRACK_TEST_PDKS_INSTALLED)")
            skipped += 1
            continue
        if name.startswith("test_pdk_bsimcmg_") and not (PDKS and BSIMCMG):
            print(f"skip  {name} (set SPRACK_TEST_PDKS and SPRACK_BSIMCMG_OSDI)")
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

