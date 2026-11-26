#!/bin/sh
# Compile BSIM-CMG 107.0.0 for ngspice and VACASK (issue 53):
#
#     tools/bsimcmg-osdi.sh XYCE_SRC OUT.osdi
#
# XYCE_SRC is a Xyce source tree (7.10 ships the model, in
# utils/ADMS/examples/bsimcmg_107.0.0/code). Writes OUT.osdi, module
# `bsimcmg`, which `--provide bsimcmg=OUT.osdi` or ASAP7's manifest
# ($BSIMCMG_OSDI) gives a translation. Needs openvaf-r and python3, as the
# flake's verify shell has; the flake builds it as packages.bsimcmg-osdi.
# The source is written for ADMS; three edits make it standard Verilog-A
# that openvaf-r compiles and ASAP7's cards load (docs/verification.md 4.43).
set -eu
src=$1/utils/ADMS/examples/bsimcmg_107.0.0/code
out=$(realpath "$2")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$src"/*.va "$src"/*.include "$tmp"/
chmod u+w "$tmp"/*
cd "$tmp"
# 1. ADMS attributes after the port list: openvaf-r stops at them.
sed -i 's/^module bsimcmg(d, g, s, e) `attr(.*);/module bsimcmg(d, g, s, e);/' bsimcmg_main.va
# 2. ADMS writes `attr(a="x" b="y") after a declaration; the standard is
#    (* a="x", b="y" *) before it.
python3 -I - bsimcmg_body.include <<'PY'
import re, sys, pathlib
decl = re.compile(r'^(\s*)(.*?)\s*`attr\((.*)\)\s*;(\s*//.*)?$')
p = pathlib.Path(sys.argv[1])
out = []
for line in p.read_text(errors="replace").splitlines():
    m = decl.match(line.rstrip())
    out.append(f"{m[1]}(* {re.sub(r'\"\s+(?=\w+=)', '\", ', m[3])} *) {m[2]};{m[4] or ''}" if m else line)
p.write_text("\n".join(out) + "\n")
PY
# 3. 0.1n parses above 1e-10, so ASAP7's eotacc = 1e-010 fell outside
#    [0.1n:inf): "Parameter EOTACC is out of bounds!".
sed -i 's/parameter real EOTACC    =  EOT from \[0\.1n:inf)/parameter real EOTACC    =  EOT from [1.0e-10:inf)/' bsimcmg_body.include
grep -q '^module bsimcmg(d, g, s, e);' bsimcmg_main.va
grep -q 'EOTACC    =  EOT from \[1.0e-10:inf)' bsimcmg_body.include
if grep -q '`attr' bsimcmg_body.include; then exit 1; fi
openvaf-r --target_cpu generic bsimcmg.va -o "$out"
# openvaf-r exits 0 when its linker is missing.
test -f "$out"
