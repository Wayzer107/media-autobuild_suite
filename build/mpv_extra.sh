#!/bin/bash
# media-autobuild_suite extra script for mpv-git
#
# Fix: ucrt64's libarchive.a is compiled against the zlib DLL (uses __declspec(dllimport)
# for inflate/crc32 etc.), producing __imp_inflate references that can't be satisfied by
# the static libz.a. The suite renames the zlib DLL import stub to libz.dll.a.dyn to
# prevent unintended DLL linkage; we need to re-enable it specifically for this link.
#
# This hook runs after meson generates build.ninja and replaces libz.a with
# libz.dll.a.dyn so libarchive's __imp_inflate etc. resolve against zlib1.dll.

_post_meson() {
    local _build_ninja="$REPO_DIR/build-${bits}/build.ninja"
    local _zdyn="$MINGW_PREFIX/lib/libz.dll.a.dyn"

    if [[ ! -f "$_build_ninja" ]]; then
        echo "mpv_extra.sh: WARNING: build.ninja not found at $_build_ninja"
        return 1
    fi

    if [[ ! -f "$_zdyn" ]]; then
        echo "mpv_extra.sh: WARNING: $_zdyn not found, skipping libarchive zlib DLL fix"
        return 0
    fi

    # build.ninja uses mixed Windows paths like C$:/path/to/lib.a
    # Match /libz.a (end of any path) and replace with the .dyn import stub path.
    # Only idempotent if libz.dll.a.dyn is not already present.
    if grep -q 'libz\.dll\.a\.dyn' "$_build_ninja"; then
        echo "mpv_extra.sh: build.ninja already patched for libz.dll.a.dyn, skipping"
        return 0
    fi

    local _zdyn_escaped
    _zdyn_escaped=$(printf '%s' "$_zdyn" | sed 's|[&/\]|\\&|g')

    if grep -q 'libz\.a' "$_build_ninja"; then
        sed -i "s|libz\.a|${_zdyn_escaped}|g" "$_build_ninja"
        echo "mpv_extra.sh: patched build.ninja: libz.a -> ${_zdyn} (resolves libarchive __imp_inflate)"
    else
        echo "mpv_extra.sh: libz.a not found in build.ninja, no patch needed"
    fi
}
