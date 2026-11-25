"""Line coverage of the Python package by its tests, with the standard
library alone (issue 65).

Usage: python3 tools/py_coverage.py [out.tsv]      (the tests' environment:
SPRACK_TEST_PDKS and the rest, as python/test_sprack.py takes them)

Every line executed in python/sprack/*.py while python/test_sprack.py runs
is recorded with sys.settrace (threads too); the executable lines are those
of each function's code objects. Lines run only in other processes are not
seen. Prints the table and the lines missed per function; with an argument,
writes `file<TAB>percent<TAB>covered<TAB>lines` for tools/coverage_floor.py.
"""
import os, runpy, sys, threading, types

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.realpath(os.path.join(HERE, "..", "python", "sprack"))
seen = {}


real = {}


def tracer(frame, event, arg):
    raw = frame.f_code.co_filename
    path = real.get(raw)
    if path is None:
        path = real[raw] = os.path.realpath(raw)
    if not path.startswith(PKG):
        return None
    lines = seen.setdefault(path, set())

    def local(frame, event, arg):
        if event == "line":
            lines.add(frame.f_lineno)
        return local

    lines.add(frame.f_lineno)
    return local


def executable(code):
    """The line numbers that can run in a code object and those it holds."""
    out = {ln for _, _, ln in code.co_lines() if ln is not None and ln > 0}
    for c in code.co_consts:
        if isinstance(c, types.CodeType):
            out |= executable(c)
    return out


def bodies(code):
    """(function name, its own lines) of every function under `code`."""
    for c in code.co_consts:
        if isinstance(c, types.CodeType):
            yield c.co_qualname, {ln for _, _, ln in c.co_lines() if ln is not None and ln > c.co_firstlineno}
            yield from bodies(c)


def main():
    sys.path.insert(0, os.path.join(HERE, "..", "python"))
    os.chdir(os.path.join(HERE, "..", "python"))
    threading.settrace(tracer)
    sys.settrace(tracer)
    status = 0
    try:
        runpy.run_path("test_sprack.py", run_name="__main__")
    except SystemExit as e:
        status = e.code or 0
    finally:
        sys.settrace(None)
        threading.settrace(None)
    rows = []
    for name in sorted(os.listdir(PKG)):
        if not name.endswith(".py"):
            continue
        path = os.path.join(PKG, name)
        code = compile(open(path).read(), path, "exec")
        # Function bodies only: module-level lines run at import, before the
        # tracer is on.
        funcs = list(bodies(code))
        want = set().union(*(lines for _, lines in funcs)) if funcs else set()
        got = seen.get(path, set()) & want
        pct = 100.0 * len(got) / len(want) if want else 100.0
        rows.append((f"python/sprack/{name}", pct, len(got), len(want)))
        print(f"python/sprack/{name}: {len(got)} of {len(want)} lines ({pct:.1f}%)")
        for fn, lines in funcs:
            miss = sorted(lines - got)
            if miss:
                print(f"    {fn}: {len(miss)} not run ({', '.join(map(str, miss[:12]))}{', ...' if len(miss) > 12 else ''})")
    if len(sys.argv) > 1:
        with open(sys.argv[1], "w") as f:
            f.write("file\tpercent\tcovered\tlines\n" + "".join(f"{n}\t{p:.1f}\t{c}\t{w}\n" for n, p, c, w in rows))
    sys.exit(status)


if __name__ == "__main__":
    main()
