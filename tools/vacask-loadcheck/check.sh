#!/bin/sh
# Translate each deck here to VACASK and run vacask on the result.
#   tools/vacask-loadcheck/check.sh [sprack] [vacask]
# Run it in `nix develop .#verify`, whose vacask is upstream b2c1551. Without
# a sprack argument it builds zig-out/bin/sprack first.
# Decks: *.sp ngspice, *.xyce Xyce, *.scs Spectre. Every rule in
# grammars/vacask.spgrammar is used by at least one of them. tline.sp loads
# but its operating point fails, as VACASK's own demo/delay/tline.sim does
# with the OpenVAF-Reloaded 24.0.2 build.
here=$(cd "$(dirname "$0")" && pwd)
[ -n "$1" ] || (cd "$here/../.." && zig build) || exit 1
sprack=${1:-$here/../../zig-out/bin/sprack}
vacask=${2:-vacask}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
for deck in "$here"/*.sp "$here"/*.xyce "$here"/*.scs; do
    case $deck in *.sp) from=ngspice ;; *.xyce) from=xyce ;; *.scs) from=spectre ;; esac
    name=$(basename "$deck")
    dir=$out/${name%.*}
    "$sprack" project --from $from --to vacask --out "$dir" "$deck" >"$dir.log" 2>&1
    if (cd "$dir" && timeout 60 "$vacask" "$name" >>"$dir.log" 2>&1) && ! grep -qi "failed\|aborted" "$dir.log"; then
        echo "ok    $name"
    elif [ "$name" = tline.sp ] && grep -q "Operating point analysis failed" "$dir.log"; then
        echo "xfail $name (loads; the operating point fails as upstream's demo does)"
    else
        echo "FAIL  $name"; fail=1
        grep -iE "error|failed|aborted" "$dir.log" | head -3 | sed 's/^/      /'
    fi
done
exit $fail
