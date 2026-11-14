"""PEP 517 backend for the sprack wheel: `zig build py`, then zip python/sprack/.

Zig must be on PATH. The extension uses only CPython's limited API (3.10), so
one wheel, tagged cp310-abi3-<platform>, serves Python 3.10 and later.
"""
import base64, hashlib, io, os, re, subprocess, sysconfig, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "python", "sprack")


def _version():
    with open(os.path.join(ROOT, "build.zig.zon")) as f:
        return re.search(r'\.version\s*=\s*"([^"]+)"', f.read()).group(1)


def _metadata():
    return f"Metadata-Version: 2.1\nName: sprack\nVersion: {_version()}\nRequires-Python: >=3.10\n"


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    subprocess.run(["zig", "build", "py", "-Doptimize=ReleaseSafe"], cwd=ROOT, check=True)
    # ponytail: the tag is the interpreter's own platform (linux_x86_64,
    # macosx_11_0_arm64); manylinux/delocate retagging is for a PyPI upload.
    plat = sysconfig.get_platform().replace("-", "_").replace(".", "_")
    tag = f"cp310-abi3-{plat}"
    dist = f"sprack-{_version()}.dist-info"
    files = {}
    for dirpath, dirnames, filenames in os.walk(PKG):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for n in filenames:
            if n.endswith((".py", ".json", ".abi3.so")):
                p = os.path.join(dirpath, n)
                with open(p, "rb") as f:
                    files[os.path.relpath(p, os.path.dirname(PKG))] = f.read()
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
