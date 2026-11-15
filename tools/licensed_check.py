"""Load-check error-free translations to Spectre and HSPICE on a licensed host.

Usage (local):
  python3 -I tools/licensed_check.py <sprack> <suite/tests> <audit.tsv> <out.tsv>
      --host HOST --env SCRIPT --dir DIR [--targets spectre,hspice] [--only REGEX] [--jobs N] [--keep]

HOST is the ssh host with the licensed tools, SCRIPT a file on it that the
login shell sources to put `spectre` and `hspice` on PATH, and DIR a scratch
directory under the remote home that this script owns (it is wiped first).
Each may instead come from SPRACK_LC_HOST, SPRACK_LC_ENV and SPRACK_LC_DIR.

Every run in <audit.tsv> from ngspice or hspice to a target with rc 0 and
0 errors is translated here, shipped with the suite tree to the host, and
run there in batch mode, at most 4 jobs at once (--jobs or SPRACK_LC_JOBS
to change it) and 60 s each. As a control,
each hspice-source deck is also run natively in HSPICE, and each
ngspice-source deck in the local ngspice (when one is on PATH). A target
failure counts as a translation failure only when the control loaded.

Output columns: deck, from, to, role (translation | control), status
(loaded | syntax | runtime | timeout), and the error lines, ' | '-joined.
The remote side is this same file, run with --remote by the host's
python3 (3.6 there, so nothing newer is used).
"""
import csv, os, re, shutil, signal, subprocess, sys, tarfile, tempfile
from concurrent.futures import ThreadPoolExecutor

JOBS, TIMEOUT = 4, 60
EXT = {"spectre": ".scs", "hspice": ".sp", "ngspice": ".sp"}
INCLUDES = re.compile(r"(?im)^\s*\.(inc|include|lib)\b")


def run(cmd, cwd, timeout=TIMEOUT):
    """(rc or None on timeout, combined output). Kills the whole process group."""
    p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        out = p.communicate(timeout=timeout)[0]
        return p.returncode, out.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return None, ""


def spectre_errors(text):
    """Each `ERROR (...)` message with its indented continuation lines."""
    errs, cur = [], None
    for line in text.splitlines():
        if re.match(r"\s*(ERROR|FATAL)\b", line):
            cur = [line.strip()]
            errs.append(cur)
        elif cur is not None and line.startswith("        ") and line.strip():
            cur.append(line.strip())
        else:
            cur = None
    msgs = [" ".join(e) for e in errs]
    # SFE-874 only says "there were syntax errors"; keep it last if alone.
    return [m for m in msgs if "SFE-874" not in m] or msgs


def classify(tool, rc, text):
    if rc is None:
        return "timeout", []
    if tool == "spectre":
        errs = spectre_errors(text)
        if any("(SFE-" in e for e in errs):
            return "syntax", errs
    elif tool == "hspice":
        errs = [l.strip() for l in text.splitlines() if "**error**" in l.lower()]
        if any(re.search(r"\(\S+:\d+\)|syntax", e) for e in errs):
            return "syntax", errs
    else:  # ngspice
        errs = [l.strip() for l in text.splitlines() if re.match(r"\s*error\b", l, re.I)]
        if rc == 0 and not errs:
            return "loaded", []
        return "syntax" if any("line" in e.lower() for e in errs) else "runtime", errs
    if errs or rc != 0:
        return "runtime", errs or ["exit status %d" % rc]
    return "loaded", []


def simulate(tool, deck, scratch):
    """Run one deck in its own directory; outputs go to `scratch`, then are deleted."""
    os.makedirs(scratch, exist_ok=True)
    cwd = os.path.dirname(os.path.abspath(deck))
    try:
        if tool == "spectre":
            rc, out = run(["spectre", "-64", os.path.basename(deck), "-raw", os.path.join(scratch, "s.raw"),
                           "-ahdllibdir", os.path.join(scratch, "ahdl"), "+log", os.path.join(scratch, "s.log")], cwd)
        elif tool == "hspice":
            rc, out = run(["hspice", "-i", os.path.basename(deck), "-o", os.path.join(scratch, "h")], cwd)
            lis = os.path.join(scratch, "h.lis")
            if os.path.exists(lis):
                out += open(lis, errors="replace").read()
        else:
            # -r: without a raw file, batch mode refuses a deck that prints nothing.
            rc, out = run(["ngspice", "-b", "-r", os.path.join(scratch, "x.raw"), os.path.abspath(deck)], scratch)
        return classify(tool, rc, out)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def version(cmd):
    rc, out = run(cmd, ".")
    return next((l.strip() for l in out.splitlines() if "ersion" in l), "?")


def remote(jobs_tsv, out_tsv, n=JOBS):
    jobs = list(csv.reader(open(jobs_tsv), delimiter="\t"))
    print("spectre:", version(["spectre", "-V"]), "| hspice:", version(["hspice", "-v"]), flush=True)

    def one(i_job):
        i, (rel, frm, to, role, deck, tool) = i_job
        status, errs = simulate(tool, deck, os.path.abspath("scratch/%d" % i))
        return [rel, frm, to, role, status, " | ".join(errs)[:2000]]

    with ThreadPoolExecutor(max_workers=n) as ex:
        rows = list(ex.map(one, enumerate(jobs)))
    with open(out_tsv, "w") as f:
        for r in rows:
            f.write("\t".join(c.replace("\t", " ").replace("\n", " ") for c in r) + "\n")
    shutil.rmtree("scratch", ignore_errors=True)


def ssh(host, cmd):
    r = subprocess.run(["ssh", host, cmd])
    if r.returncode:
        sys.exit("ssh %s %r failed" % (host, cmd))


def main(argv):
    if argv[1] == "--remote":
        return remote(argv[2], argv[3], int(argv[4]) if len(argv) > 4 else JOBS)
    sprack, suite, audit, out_tsv = (os.path.abspath(a) for a in argv[1:5])
    opts = argv[5:]
    get = lambda k, d: opts[opts.index(k) + 1] if k in opts else d
    host, env, rdir = (get("--" + k, os.environ.get("SPRACK_LC_" + k.upper())) for k in ("host", "env", "dir"))
    if not (host and env and rdir):
        sys.exit("--host, --env and --dir (or SPRACK_LC_HOST, _ENV, _DIR) are required")
    targets, only = get("--targets", "spectre,hspice").split(","), get("--only", "")
    njobs = int(get("--jobs", os.environ.get("SPRACK_LC_JOBS", JOBS)))

    picked = [r for r in csv.DictReader(open(audit), delimiter="\t", quoting=csv.QUOTE_NONE)
              if r["from"] in ("ngspice", "hspice") and r["to"] in targets and r["from"] != r["to"] and r["rc"] == "0"
              and r["errors"] == "0" and re.search(only, r["file"])]
    work = tempfile.mkdtemp(prefix="sprack-lc-")
    remote_jobs, local_rows, controls = [], [], set()
    for r in picked:
        rel, frm, to = r["file"], r["from"], r["to"]
        src = os.path.join(suite, rel)
        base = os.path.splitext(rel)[0]
        if INCLUDES.search(open(src, errors="replace").read()):
            # Its includes are translated too, into a tree of its own.
            pdir = os.path.join(work, "tests", os.path.dirname(rel), "_%s_%s2%s" % (os.path.basename(base), frm, to))
            t = subprocess.run([sprack, "project", "--from", frm, "--to", to, "--out", pdir, src],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            out = os.path.join(pdir, os.path.basename(rel))
        else:
            out = os.path.join(work, "tests", "%s_%s2%s%s" % (base, frm, to, EXT[to]))
            os.makedirs(os.path.dirname(out), exist_ok=True)
            t = subprocess.run([sprack, "translate", "--from", frm, "--to", to, src, "-o", out],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if t.returncode:
            local_rows.append([rel, frm, to, "translation", "translate-error", t.stderr.decode()[:500].replace("\n", " ")])
            continue
        remote_jobs.append([rel, frm, to, "translation", os.path.join("tests", os.path.relpath(out, os.path.join(work, "tests"))), to])
        controls.add((rel, frm))
    for rel, frm in sorted(controls):
        if frm == "hspice":
            remote_jobs.append([rel, frm, frm, "control", os.path.join("tests", rel), "hspice"])
        elif shutil.which("ngspice"):
            status, errs = simulate("ngspice", os.path.join(suite, rel), os.path.join(work, "ng"))
            local_rows.append([rel, frm, frm, "control", status, " | ".join(errs)[:2000]])

    with open(os.path.join(work, "jobs.tsv"), "w") as f:
        for j in remote_jobs:
            f.write("\t".join(j) + "\n")
    tgz = os.path.join(work, "batch.tgz")
    def writable(ti):  # the suite comes read-only from the nix store
        ti.mode |= 0o200
        return ti

    with tarfile.open(tgz, "w:gz") as tf:
        tf.add(suite, "tests", filter=writable)
        tf.add(os.path.join(work, "tests"), "tests")
        tf.add(os.path.join(work, "jobs.tsv"), "jobs.tsv")
        tf.add(os.path.abspath(__file__), "licensed_check.py")
    print("%d remote jobs, %d local rows; shipping %s" % (len(remote_jobs), len(local_rows), tgz), flush=True)
    ssh(host, "rm -rf ~/%s && mkdir -p ~/%s" % (rdir, rdir))
    subprocess.run(["scp", "-q", tgz, "%s:%s/" % (host, rdir)], check=True)
    # `source A && B` reads the same in csh and sh login shells.
    ssh(host, "source %s && cd ~/%s && tar xzf batch.tgz && rm batch.tgz && "
              "python3 licensed_check.py --remote jobs.tsv results.tsv %d" % (env, rdir, njobs))
    subprocess.run(["scp", "-q", "%s:%s/results.tsv" % (host, rdir), os.path.join(work, "results.tsv")], check=True)
    if "--keep" not in opts:
        ssh(host, "rm -rf ~/%s/tests" % rdir)

    rows = local_rows + list(csv.reader(open(os.path.join(work, "results.tsv")), delimiter="\t", quoting=csv.QUOTE_NONE))
    ctl = {(r[0], r[1]): r[4] for r in rows if r[3] == "control"}
    with open(out_tsv, "w") as f:
        f.write("deck\tfrom\tto\trole\tstatus\tsource_loads\terrors\n")
        for r in sorted(rows, key=lambda r: (r[3], r[2], r[1], r[0])):
            f.write("\t".join(r[:5] + [ctl.get((r[0], r[1]), "?"), r[5]]) + "\n")
    summary = {}
    for r in rows:
        if r[3] == "translation":
            key = "%s->%s" % (r[1], r[2])
            s = r[4] if r[4] == "loaded" or ctl.get((r[0], r[1])) in ("loaded", None) else "source-fails"
            summary.setdefault(key, {}).setdefault(s, 0)
            summary[key][s] += 1
    for k, v in sorted(summary.items()):
        print(k, " ".join("%s=%d" % kv for kv in sorted(v.items())))
    print("->", out_tsv, "(work dir %s)" % work)


if __name__ == "__main__":
    main(sys.argv)
