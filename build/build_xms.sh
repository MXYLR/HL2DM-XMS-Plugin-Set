#!/bin/bash
# Build the plugin suite in this tree.
#
#   ./build/build_xms.sh [sourcemod-dir]
#
# sourcemod-dir is an unpacked SourceMod install (the folder holding
# addons/sourcemod, or addons/sourcemod itself) and can also be given as
# $SM_DIR.  Only its compiler and its stock includes are used -- nothing is
# read from its plugins folder.
#
# The .smx files are written to addons/sourcemod/plugins/ in this tree, which
# is the folder a server operator copies into hl2mp/addons/sourcemod/plugins/.
# A build that overwrites the one you are already running from is deliberate:
# an .smx left somewhere else is one the server never sees.
#
# This is the 64-bit port, so the compiler has to be the 64-bit one that ships
# with the SourceMod build the server runs (spcomp64.exe).  The 32-bit spcomp
# produces a plugin the 64-bit SourceMod will not load.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/addons/sourcemod/scripting"
DEST="$ROOT/addons/sourcemod/plugins"
LOCALINC="$ROOT/build/include"

# The plugins this tree builds, in the order they are reported.
PLUGINS="xms.sp xfix.sp xfov.sp xfootsteps.sp xms_bots.sp xms_custom_gamemode.sp xshadows.sp xms_matchtest.sp"

SM="${1:-${SM_DIR:-}}"

if [ -z "$SM" ]; then
    # A SourceMod install unpacked next to this repo, which is where the
    # README's setup step puts it.
    for candidate in "$ROOT/../deps/sm-official" "$ROOT/../sm" "$ROOT/../sourcemod"; do
        if [ -e "$candidate" ]; then SM="$candidate"; break; fi
    done
fi

if [ -z "$SM" ]; then
    echo "no SourceMod install given: pass one, or set SM_DIR" >&2
    echo "  ./build/build_xms.sh /path/to/sourcemod/addons/sourcemod" >&2
    exit 1
fi

# Accept the install root, addons/, addons/sourcemod or scripting/ itself --
# an unpacked SourceMod archive already lays the compiler out in scripting/.
for probe in "$SM" "$SM/scripting" "$SM/addons/sourcemod" "$SM/addons/sourcemod/scripting"; do
    if [ -f "$probe/spcomp64.exe" ] || [ -f "$probe/spcomp64" ]; then
        SMINC="$probe/include"
        SPCOMP="$(ls "$probe"/spcomp64.exe "$probe"/spcomp64 2>/dev/null | head -1)"
        break
    fi
done

if [ -z "${SPCOMP:-}" ] || [ ! -d "$SMINC" ]; then
    echo "no spcomp64 or no include/ under $SM" >&2
    exit 1
fi

mkdir -p "$DEST"

fail=0
for p in $PLUGINS; do
    name="${p%.sp}"

    # The stock includes come first so a plugin's own include/ is still
    # searched, and the vendored set (smlib and friends, which SourceMod does
    # not ship) is last.
    log="$(cd "$SRC" && "$SPCOMP" -i"$SMINC" -i"$SRC/include" -i"$LOCALINC" \
              -o"$DEST/$name.smx" "$p" 2>&1)"
    errs="$(printf '%s\n' "$log" | grep -c ": error")"

    if [ "$errs" -eq 0 ] && [ -f "$DEST/$name.smx" ]; then
        echo "OK    $name.smx"
    else
        echo "FAIL  $name  ($errs errors)"
        printf '%s\n' "$log" | grep -E ": error" -A3 | head -30
        fail=1
    fi
done

exit $fail
