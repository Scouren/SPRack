"""The example files the pages print are the files in docs/src/examples.

    python3 docs/check/checkfiles.py
"""
import os, re, sys

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")
SHOWN = [("index.md", "rc.sp"), ("cli.md", "rc.sp"), ("adding-a-simulator.md", "inv.sp"), ("adding-a-simulator.md", "ac.sp"),
         ("pdks.md", "mine/models.lib"), ("adding-a-pdk.md", "mine.json")]


def blocks(page):
    return [body for _, body in re.findall(r"```(\w+)\n(.*?)```", open(os.path.join(SRC, page)).read(), re.S)]


def example(name):
    return open(os.path.join(SRC, "examples", name)).read()


bad = 0
for page, name in SHOWN:
    ok = example(name) in blocks(page)
    bad += not ok
    print("ok  " if ok else "BAD ", page, "shows", name)
# The fragments of the guide, in order, are the grammar file.
fragments = [b for b in blocks("adding-a-simulator.md") if b.startswith(("dialect ", "rule ", "block ", "no ", "functions"))]
lines = lambda text: [l for l in text.splitlines() if l.strip() and not l.startswith("#")]
ok = lines("".join(fragments)) == lines(example("mini.spgrammar"))
bad += not ok
print("ok  " if ok else "BAD ", f"the {len(fragments)} grammar fragments of adding-a-simulator.md are mini.spgrammar")
sys.exit(bad)
