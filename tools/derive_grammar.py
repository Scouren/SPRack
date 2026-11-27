"""A grammar that is another with less and more: written from a recipe.

    python3 -I tools/derive_grammar.py [--check] grammars/<name>.derive...

A recipe names its base grammar, the kinds and directive heads the derived
dialect leaves out, and the lines it adds:

    base ngspice
    drop op tf dc tran ...         # every line, block and section of these kinds
    drop-head needs libsections    # every directive with this head
    ---
    inert tran : ...               # added after the base's lines, as written

`grammars/<name>.spgrammar` is written beside the recipe, its first lines
saying what it was made from; edit the recipe and the base, never it.
`--check` writes nothing and exits 1 when a derived file is not what its
recipe makes (`zig build lint` runs it), so the two cannot drift apart.
"""

import os
import re
import sys

# Directives whose first argument is a kind (`rule tran = ...`, `no pz : ...`,
# `caveat subckt inline : ...`), the kind maybe with `[family]`, `@scope` or
# `.slot` after it.
KIND_FIRST = {
    "rule", "read", "write", "block", "no", "inert", "implied", "enum", "caveat", "invalid",
    "default", "omitted", "params", "spread", "rerun", "rewrite", "unique", "move", "once",
}
# Directives that open a section closed by a line `end`.
SECTIONS = {"block", "needs", "once", "params", "modelparams", "rewrite", "plugin", "signals",
            "functions", "variables", "operators", "models", "lexer", "header", "preamble"}


def kind_of(word):
    return re.split(r"[\[@.]", word, maxsplit=1)[0]


def parse(path):
    base, drop, heads, extra = None, set(), set(), []
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    for i, line in enumerate(lines):
        if line.strip() == "---":
            extra = lines[i + 1:]
            break
        words = line.split("#", 1)[0].split()
        if not words:
            continue
        if words[0] == "base" and len(words) == 2:
            base = words[1]
        elif words[0] == "drop":
            drop.update(words[1:])
        elif words[0] == "drop-head":
            heads.update(words[1:])
        else:
            sys.exit(f"{path}:{i + 1}: a recipe line is `base`, `drop`, `drop-head` or `---`")
    if base is None:
        sys.exit(f"{path}: no `base` line")
    return base, drop, heads, extra


def dropped(words, drop, heads):
    head = words[0]
    if head in heads:
        return True
    if head not in KIND_FIRST or len(words) < 2:
        return False
    if head == "move":
        return any(kind_of(w) in drop for w in words[1:] if "." in w)
    if head == "unique":
        return False
    # `lossyline[txl]`: the lines of that family; `lossyline`: of them all.
    return words[1].split("@")[0] in drop or kind_of(words[1]) in drop


def derive(recipe):
    name = os.path.basename(recipe)[: -len(".derive")]
    here = os.path.dirname(recipe)
    base, drop, heads, extra = parse(recipe)
    with open(os.path.join(here, base + ".spgrammar"), encoding="utf-8") as f:
        lines = f.read().rstrip("\n").split("\n")
    out = [
        f"# {name}: written by tools/derive_grammar.py from {name}.derive and",
        f"# {base}.spgrammar. Edit those, never this file.",
        "#",
    ]
    comments = []  # the comment lines before the next directive, which go with it
    skip = False
    for line in lines:
        if skip:
            skip = line != "end"
            continue
        stripped = line.strip()
        if stripped.startswith("#") or not stripped:
            comments.append(line)
            continue
        words = line.split("#", 1)[0].split()
        if words[0] == "dialect":
            out += comments + [f"dialect {name}"]
        elif line[0] in " \t":
            out += comments + [line]
        elif dropped(words, drop, heads):
            # The comments that explain a line go with it; a blank line ends them.
            keep = len(comments)
            while keep > 0 and comments[keep - 1].strip():
                keep -= 1
            out += comments[:keep]
            skip = words[0] in SECTIONS
        else:
            out += comments + [line]
        comments = []
    out += comments
    # Not named apart from its base where a message lists dialects.
    out += ["", f"variant {base}"] + extra
    text = "\n".join(out).rstrip("\n") + "\n"
    return os.path.join(here, name + ".spgrammar"), text


def main():
    check = "--check" in sys.argv[1:]
    stale = []
    for recipe in [a for a in sys.argv[1:] if a != "--check"]:
        path, text = derive(recipe)
        have = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if have == text:
            continue
        if check:
            stale.append(path)
        else:
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            print(f"wrote {path}")
    if stale:
        sys.exit("not what their recipes make (run tools/derive_grammar.py): " + ", ".join(stale))


if __name__ == "__main__":
    main()
