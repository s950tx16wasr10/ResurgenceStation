#!/bin/bash
# TGS PostCompile event script — called after DM compilation succeeds.
# $1 = directory containing the freshly-compiled game files.
#
# BYOND's call_ext() resolution on Linux is finicky: it checks the game
# working directory under several name variants (bare, .so, lib- prefix),
# falls back to LD_LIBRARY_PATH and the ldconfig cache, and fails closed
# with a confusing "libbyond.so: undefined symbol: <fn>" runtime error if
# none of the expected paths satisfy. We scatter every native lib to
# every location BYOND has historically searched (game dir, BYOND bin
# dir, /usr/local/lib, /usr/lib/i386-linux-gnu) so call_ext succeeds
# regardless of which path BYOND tries first.
set -euo pipefail

GAME_DIR="$1"

# Locate the active BYOND install dir under the TGS instance volume so we
# can scatter alongside DreamDaemon. The path includes the version number
# (e.g. /tgs_instances/ResurgenceStation/Byond/516.1680/byond/bin).
BYOND_BIN=""
if [ -f "/tgs_instances/ResurgenceStation/Byond/ActiveVersion.txt" ]; then
    ACTIVE_VERSION=$(cat /tgs_instances/ResurgenceStation/Byond/ActiveVersion.txt)
    CANDIDATE="/tgs_instances/ResurgenceStation/Byond/$ACTIVE_VERSION/byond/bin"
    [ -d "$CANDIDATE" ] && BYOND_BIN="$CANDIDATE"
fi

scatter() {
    # scatter <source> <basename without prefix or extension>
    local SRC="$1"
    local BASE="$2"
    local DEST
    local DESTS=(
        "$GAME_DIR/$BASE"
        "$GAME_DIR/$BASE.so"
        "$GAME_DIR/lib$BASE.so"
        "/usr/local/lib/$BASE.so"
        "/usr/local/lib/lib$BASE.so"
        "/usr/lib/i386-linux-gnu/$BASE.so"
        "/usr/lib/i386-linux-gnu/lib$BASE.so"
    )
    if [ -n "$BYOND_BIN" ]; then
        DESTS+=(
            "$BYOND_BIN/$BASE"
            "$BYOND_BIN/$BASE.so"
            "$BYOND_BIN/lib$BASE.so"
        )
    fi
    for DEST in "${DESTS[@]}"; do
        # Skip when source and destination are the same file (cp errors otherwise).
        if [ "$(readlink -f "$SRC")" = "$(readlink -f "$DEST" 2>/dev/null || echo "")" ]; then
            continue
        fi
        mkdir -p "$(dirname "$DEST")"
        # ATOMIC REPLACE, not in-place truncate.
        #
        # The active DreamDaemon process has these .so files mmap'd into its
        # address space. Plain `cp -f $SRC $DEST` opens $DEST with O_TRUNC and
        # rewrites the bytes in place — the kernel reuses the same inode, so
        # the running process's mmap'd pages now point at half-written content.
        # Next time DD page-faults on a code page (e.g. the next call into
        # rust_g), it reads garbage and segfaults with BYOND printing
        # "BUG: Crashing due to an illegal operation!".
        #
        # Copy to a sibling tempfile, then `mv` to atomically swap inodes.
        # The old inode stays alive for any process that already had it open;
        # new opens see the new file. No corrupted code pages.
        cp -f "$SRC" "$DEST.tmp.$$"
        mv -f "$DEST.tmp.$$" "$DEST"
    done
}

scatter "$GAME_DIR/rust_g"           rust_g
scatter "$GAME_DIR/libBSQL.so"       BSQL
scatter "$GAME_DIR/libquickwrite.so" quickwrite

# Refresh the ldconfig cache so dlopen-by-soname (librust_g.so etc.) finds
# the freshly scattered files in /usr/local/lib and /usr/lib/i386-linux-gnu.
ldconfig

# ── Self-install sibling event scripts ───────────────────────────────────────
# Every TGS deploy hot-swaps a fresh copy of the source tree into the game
# directory. Use that to keep Configuration/EventScripts/ in lockstep with
# tools/tgs4_scripts/ in the repo: copy each sibling script into the
# instance's EventScripts dir, KEEPING the .sh extension.
#
# TGS6 only enumerates event scripts whose filename matches `<EventName>*.<ext>`
# where `<ext>` is `.sh` on Linux / `.bat` on Windows. See:
#   https://github.com/tgstation/tgstation-server/blob/master/src/Tgstation.Server.Host/System/PlatformIdentifier.cs
# An earlier revision of this loop dropped the .sh, which made the auto-installed
# siblings invisible to TGS even though PostCompile was running. Preserving the
# extension is what actually makes the chain work.
#
# Without this self-install, every change to one of the sibling scripts requires
# a manual `docker cp` into the instance volume. With it, an update merged to
# master takes effect on the next deploy automatically (with a one-deploy lag
# for PostCompile itself, since the currently running PostCompile installs the
# new one).
EVENT_DST="$(dirname "$(dirname "$GAME_DIR")")/Configuration/EventScripts"
if [ -d "$EVENT_DST" ]; then
    for SCRIPT in PostCompile DreamDaemonPreLaunch RoundStart RoundEnd; do
        SRC="$GAME_DIR/tools/tgs4_scripts/$SCRIPT.sh"
        if [ -f "$SRC" ]; then
            # Atomic-replace, not in-place truncate. The running PostCompile
            # script IS this file. cp -f opens with O_TRUNC and rewrites in
            # place; if the new script is shorter, bash hits EOF mid-execution
            # and dies. mv allocates a new inode; bash keeps the old one open
            # and finishes cleanly.
            cp -f "$SRC" "$EVENT_DST/$SCRIPT.sh.tmp.$$"
            chmod +x "$EVENT_DST/$SCRIPT.sh.tmp.$$"
            mv -f "$EVENT_DST/$SCRIPT.sh.tmp.$$" "$EVENT_DST/$SCRIPT.sh"
        fi
    done
fi
