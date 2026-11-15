"""`python -m sprack --from DIALECT [file]`: the netlist as a Python script
that builds it with this package. The report of reading it goes to stderr."""
import argparse
import sys

import sprack

p = argparse.ArgumentParser(prog="python -m sprack", description=__doc__)
p.add_argument("--from", dest="frm", required=True, help="the dialect of the netlist: " + ", ".join(sprack.DIALECTS) + ", or a .spgrammar path")
p.add_argument("file", nargs="?", help="the netlist; standard input when left out")
a = p.parse_args()
# A netlist is UTF-8 whatever the code page; 0 is standard input.
with open(a.file or 0, encoding="utf-8") as f:
    out = sprack.to_python(f.read(), a.frm)
sys.stdout.write(out)
if out.report:
    print(out.report, file=sys.stderr)
