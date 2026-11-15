"""Run the python blocks of the pages and compare what they print with the
block that follows each.

    python3 docs/check/checkpage.py [page.md ...]      (default: every page)

Each page runs in one namespace, in a fresh copy of docs/src/examples, with
the package from python/ and the cache in that directory. The examples on the
SKY130 library run when SPRACK_TEST_PDKS names the PDK checkouts
(`nix build .#test-pdks --no-link --print-out-paths`); otherwise they are
skipped, with the blocks that use what they define.
"""
import ast, contextlib, glob, io, os, re, shutil, sys, tempfile, traceback

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "docs", "src")
PDKS = os.environ.get("SPRACK_TEST_PDKS", "")
BLOCK = re.compile(r"```(\w+)\n(.*?)```", re.S)


def pages(args):
    return [os.path.abspath(a) for a in args] or sorted(glob.glob(os.path.join(SRC, "*.md")))


def workdir():
    """A fresh copy of the examples, made the current directory."""
    d = os.path.realpath(tempfile.mkdtemp(prefix="sprack-docs-"))
    shutil.copytree(os.path.join(SRC, "examples"), d, dirs_exist_ok=True)
    if PDKS:
        os.symlink(PDKS, os.path.join(d, "pdks"))
    os.environ["SPRACK_CACHE"] = os.path.join(d, "cache")
    os.chdir(d)
    return d


def normal(text, d):
    """Output as the pages show it: the run's directory is `…`, cache keys
    (which hash absolute paths) are all one, blank lines do not count."""
    text = re.sub(r"(?<=-)[0-9a-f]{16}\b", "<key>", text.replace(d, "…"))
    return [line.rstrip() for line in text.splitlines() if line.strip()]


def names(body):
    tree = ast.parse(body)
    stored = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store)}
    return stored, {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)} - stored


def check(page):
    blocks = BLOCK.findall(open(page).read())
    if not any(lang == "python" for lang, _ in blocks):
        return 0, 0, 0
    d, ns, missing = workdir(), {}, set()
    ran = bad = skipped = i = 0
    while i < len(blocks):
        lang, body = blocks[i]
        i += 1
        if lang != "python":
            continue
        stored, used = names(body)
        if not PDKS and ("pdks/" in body or used & missing):
            missing |= stored
            skipped += 1
            # A block that prints is followed by what it printed.
            i += "print(" in body and i < len(blocks) and blocks[i][0] in ("text", "python")
            continue
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            try:
                exec(body, ns)
            except Exception:
                traceback.print_exc(file=out)
        ran += 1
        got = normal(out.getvalue(), d)
        if not got:
            continue
        want = normal(blocks[i][1], d) if i < len(blocks) and blocks[i][0] in ("text", "python") else None
        i += want is not None
        if got != want:
            bad += 1
            print(f"=== MISMATCH in {os.path.basename(page)} after:\n{body}--- got:\n" + "\n".join(got)
                  + "\n--- the page says:\n" + "\n".join(want or ["(no block)"]))
    os.chdir(ROOT)
    shutil.rmtree(d)
    return ran, bad, skipped


if __name__ == "__main__":
    sys.path.insert(0, os.path.join(ROOT, "python"))
    total = [0, 0, 0]
    for page in pages(sys.argv[1:]):
        for k, n in enumerate(check(page)):
            total[k] += n
    print(f"{total[0]} python blocks run, {total[1]} mismatches, {total[2]} skipped" + ("" if PDKS or not total[2] else " (set SPRACK_TEST_PDKS)"))
    sys.exit(total[1] > 0)
