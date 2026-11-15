#!/bin/sh
# Run one netlist in LTspice, in batch mode with no display.
#
#     nix develop .#ltspice -c tools/ltspice-batch.sh deck.net
#
# leaves deck.log and deck.raw beside the deck; the exit status is LTspice's
# (1 for a netlist it refuses, with file(line): message in the log).
# Needs wine, xvfb-run and timeout on PATH, LTSPICE_EXE (LTspice.exe) and
# LTSPICE_STATE (a directory for the wine prefix and LTspice's settings; the
# first run fills it, which takes about a minute). The flake's ltspice shell
# sets all of them. LTSPICE_TIMEOUT: seconds before a run is killed (300).
# Runs that share a state directory take turns: each ends by stopping the
# wine server of that prefix, which would take a neighbour's run with it.
set -eu
net=$(realpath "$1")
st=$(realpath -m "${LTSPICE_STATE:?}")
mkdir -p "$st/home"
exec 9> "$st/lock"
flock 9
# HOME is redirected so wine does not link the prefix to the real ~/Documents.
export WINEPREFIX="$st/pfx" HOME="$st/home" WINEARCH=win64 WINEDEBUG=-all
export WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree=d;mshtml=d"
# Without this setting a consent dialog waits for an answer, in batch mode too.
[ -f "$st/LTspice.ini" ] || printf '[Options]\nCaptureAnalytics=false\n' > "$st/LTspice.ini"
cd "$(dirname "$net")"
rc=0
# -b NETLIST comes before -ini: with -ini first LTspice ignores -b and opens its window.
timeout "${LTSPICE_TIMEOUT:-300}" xvfb-run -a wine "${LTSPICE_EXE:?}" -b "$(basename "$net")" \
    -ini "Z:$(printf %s "$st/LTspice.ini" | tr / '\\')" || rc=$?
timeout 20 wineserver -k || true
exit $rc
