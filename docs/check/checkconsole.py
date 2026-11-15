"""Run the `$ command` lines of the pages' console blocks and compare what
they print, exit statuses included, with what the pages show.

    python3 docs/check/checkconsole.py [page.md ...]   (default: every page)

Each page runs in a fresh copy of docs/src/examples with zig-out/bin first
on PATH. A line `...` in a page stands for any number of lines. In the guide
that grows mini.spgrammar, the working copy of the grammar ends where the
last fragment shown ends, so each command sees the file as far as the page
has got. Needs `jq` for two commands; the SKY130 one runs when
SPRACK_TEST_PDKS is set (see checkpage.py).
"""
import os, shutil, subprocess, sys

from checkpage import BLOCK, PDKS, ROOT, SRC, normal, pages, workdir

GRAMMAR = open(os.path.join(SRC, "examples", "mini.spgrammar")).read()


def check(page):
    blocks = BLOCK.findall(open(page).read())
    if not any(lang == "console" for lang, _ in blocks):
        return 0, 0, 0
    d = workdir()
    os.mkdir(".bin")
    os.symlink(sys.executable, ".bin/python")
    env = {**os.environ, "PYTHONPATH": os.path.join(ROOT, "python"),
           "PATH": os.pathsep.join([os.path.join(d, ".bin"), os.path.join(ROOT, "zig-out", "bin"), os.environ["PATH"]])}
    ran = bad = skipped = 0
    for lang, body in blocks:
        if lang != "console":
            at = GRAMMAR.find(body)
            if at >= 0 and body.startswith(("dialect ", "rule ", "block ", "no ", "functions")):
                with open("mini.spgrammar", "w") as f:
                    f.write(GRAMMAR[:at + len(body)])
            continue
        cmds, shown = [], []
        for line in body.splitlines():
            if line.startswith("$ "):
                cmds.append(line[2:])
                shown.append([])
            else:
                shown[-1].append(line)
        # One shell per block, so `echo $?` sees the command before it.
        script = "__s=0\n"
        for c in cmds:
            skip = ("pdks/" in c and not PDKS) or ("| jq" in c and not shutil.which("jq"))
            script += "printf '\\002\\001'\n" if skip else f"(exit $__s); {c} 2>&1; __s=$?; printf '\\001'\n"
        out = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=env).stdout.split("\001")
        for c, want, got in zip(cmds, shown, out):
            if got == "\002":
                skipped += 1
                continue
            ran += 1
            got, want = normal(got, d), normal("\n".join(want), d)
            if "..." in want:
                cut = want.index("...")
                tail = want[cut + 1:]
                same = got[:cut] == want[:cut] and (not tail or got[-len(tail):] == tail)
            else:
                same = got == want
            if not same:
                bad += 1
                print(f"=== MISMATCH in {os.path.basename(page)}: $ {c}\n--- got:\n" + "\n".join(got) + "\n--- the page says:\n" + "\n".join(want))
    os.chdir(ROOT)
    shutil.rmtree(d)
    return ran, bad, skipped


if __name__ == "__main__":
    if not os.path.isfile(os.path.join(ROOT, "zig-out", "bin", "sprack")):
        sys.exit("zig-out/bin/sprack is not built: run `zig build` first")
    total = [0, 0, 0]
    for page in pages(sys.argv[1:]):
        for k, n in enumerate(check(page)):
            total[k] += n
    print(f"{total[0]} commands run, {total[1]} mismatches, {total[2]} skipped")
    sys.exit(total[1] > 0)
