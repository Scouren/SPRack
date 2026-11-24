"""PEP 517 backend for sprack: `zig build py`, then zip python/sprack/.

Zig must be on PATH. The extension uses only CPython's limited API (3.10), so
one wheel, tagged cp310-abi3-<platform>, serves Python 3.10 and later.

The extension links nothing but libc, and Zig builds against the libc
version it is told to, so the tag is the build target, not the build host:

- Linux: glibc 2.28, tagged manylinux_2_28_<arch>, without auditwheel.
- macOS: $MACOSX_DEPLOYMENT_TARGET, default 11.0 (the first release on
  arm64), tagged macosx_<major>_<minor>_<arch>.
- Windows on x86_64 and ARM64: tagged win_amd64 and win_arm64 (the second
  built by cross-compiling, as no CI runner has one yet). The extension there is _core.pyd,
  and it links python3.dll, the stable ABI's DLL.
- Anything else: the interpreter's own platform and Zig's native target.

The config setting `target` builds for another platform than the
interpreter's, named <arch>-<os> as Zig spells them:
`pip wheel . --config-settings target=x86_64-windows`.
"""
import base64, hashlib, io, os, platform, re, subprocess, sys, sysconfig, tarfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "python", "sprack")
# What `zig build py` needs, and what the sdist ships.
SDIST = ["build.zig", "build.zig.zon", "src", "grammars", "python", "tools/wheel_backend.py",
         "pyproject.toml", "LICENSE", "README.md"]
GLIBC = "2.28"


def _version():
    with open(os.path.join(ROOT, "build.zig.zon")) as f:
        return re.search(r'\.version\s*=\s*"([^"]+)"', f.read()).group(1)


def _metadata():
    return f"Metadata-Version: 2.2\nName: sprack\nVersion: {_version()}\nRequires-Python: >=3.10\n"


def _target(cross=None):
    """(Zig -Dtarget or None for native, wheel platform tag), for `cross`
    ("<arch>-<os>") or else for this interpreter."""
    arch = {"amd64": "x86_64", "arm64": "aarch64"}.get(platform.machine().lower(), platform.machine().lower())
    system = {"linux": "linux", "darwin": "macos", "win32": "windows"}.get(sys.platform)
    if cross:
        arch, _, system = cross.partition("-")
    if system == "linux" and arch in ("x86_64", "aarch64"):
        return f"{arch}-linux-gnu.{GLIBC}", f"manylinux_{GLIBC.replace('.', '_')}_{arch}"
    if system == "macos" and arch in ("x86_64", "aarch64"):
        major, minor = (os.environ.get("MACOSX_DEPLOYMENT_TARGET", "11.0").split(".") + ["0"])[:2]
        return f"{arch}-macos.{major}.{minor}", f"macosx_{major}_{minor}_{'arm64' if arch == 'aarch64' else arch}"
    # A named target, not Zig's native one: that would build for the CPU of
    # the machine the wheel was made on.
    if system == "windows" and arch == "x86_64":
        return "x86_64-windows", "win_amd64"
    if system == "windows" and arch == "aarch64":
        return "aarch64-windows", "win_arm64"
    if cross:
        sys.exit(f"no wheel for target {cross!r}; one is x86_64-windows or aarch64-windows")
    return None, sysconfig.get_platform().replace("-", "_").replace(".", "_")


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    target, plat = _target((config_settings or {}).get("target"))
    cmd = ["zig", "build", "py", "-Doptimize=ReleaseSafe"] + ([f"-Dtarget={target}"] if target else [])
    subprocess.run(cmd, cwd=ROOT, check=True)
    tag = f"cp310-abi3-{plat}"
    # Only the extension this build made: python/sprack/ may hold another target's.
    ext = "_core.pyd" if plat.startswith("win") else "_core.abi3.so"
    dist = f"sprack-{_version()}.dist-info"
    files = {}
    for dirpath, dirnames, filenames in os.walk(PKG):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for n in filenames:
            if n.endswith((".py", ".json")) or n == ext:
                p = os.path.join(dirpath, n)
                with open(p, "rb") as f:
                    files[os.path.relpath(p, os.path.dirname(PKG)).replace(os.sep, "/")] = f.read()
    files[f"{dist}/METADATA"] = _metadata().encode()
    files[f"{dist}/WHEEL"] = f"Wheel-Version: 1.0\nGenerator: sprack\nRoot-Is-Purelib: false\nTag: {tag}\n".encode()
    record = io.StringIO()
    for name, data in files.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        record.write(f"{name},sha256={digest},{len(data)}\n")
    record.write(f"{dist}/RECORD,,\n")
    files[f"{dist}/RECORD"] = record.getvalue().encode()
    name = f"sprack-{_version()}-{tag}.whl"
    with zipfile.ZipFile(os.path.join(wheel_directory, name), "w", zipfile.ZIP_DEFLATED) as z:
        for arc, data in files.items():
            z.writestr(arc, data)
    return name


def build_sdist(sdist_directory, config_settings=None):
    base = f"sprack-{_version()}"

    def keep(info):
        # No build output: caches, bytecode, the extension `zig build py` leaves in python/sprack/.
        parts = info.name.split("/")
        if "__pycache__" in parts or info.name.endswith((".so", ".pyd", ".pyc")):
            return None
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        return info

    name = f"{base}.tar.gz"
    with tarfile.open(os.path.join(sdist_directory, name), "w:gz", format=tarfile.PAX_FORMAT) as t:
        for p in SDIST:
            t.add(os.path.join(ROOT, p), f"{base}/{p}", filter=keep)
        pkg_info = _metadata().encode()
        info = tarfile.TarInfo(f"{base}/PKG-INFO")
        info.size = len(pkg_info)
        t.addfile(info, io.BytesIO(pkg_info))
    return name
