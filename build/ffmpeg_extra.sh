#!/bin/bash
# media-autobuild_suite extra script for ffmpeg-git
#
# Purpose: keep FFmpeg compatible with the older ffnvcodec (n9.1.23.1)
# that the suite pins for Kepler GPU support (GTX 770 NVENC/NVDEC).
#
# FFmpeg's configure rejects ffnvcodec 9.x by default — it accepts a set of
# specific version ranges with a gap between 8.2 and 11.0.10.3. This hook
# inserts a fallback `check_pkg_config` line that allows the 9.x series.
#
# DO NOT "fix" this by upgrading ffnvcodec — that would break Kepler support.

_pre_configure() {
    # Only patch if our fallback line isn't already there (idempotent)
    if ! grep -q 'ffnvcodec >= 9.0 ffnvcodec < 11.0' configure; then
        # Insert before the existing 8.1.24.15 line so 9.x is tried first in the gap
        sed -i '/check_pkg_config ffnvcodec "ffnvcodec >= 8.1.24.15/i\      check_pkg_config ffnvcodec "ffnvcodec >= 9.0 ffnvcodec < 11.0" "$ffnv_hdr_list" "" || \\' configure
        echo "ffmpeg_extra.sh: patched configure to accept ffnvcodec 9.x (Kepler GPU support)"
    fi

    # ffnvcodec 9.x headers are missing cuCtxGetCurrent which newer FFmpeg requires.
    # Patch the installed headers so ffmpeg compiles without upgrading ffnvcodec.
    local _hdr="$LOCALDESTDIR/include/ffnvcodec/dynlink_cuda.h"
    local _ldr="$LOCALDESTDIR/include/ffnvcodec/dynlink_loader.h"
    if ! grep -q 'tcuCtxGetCurrent' "$_hdr" 2>/dev/null; then
        sed -i 's/typedef CUresult CUDAAPI tcuCtxPopCurrent_v2(CUcontext \*pctx);/&\ntypedef CUresult CUDAAPI tcuCtxGetCurrent(CUcontext *pctx);/' "$_hdr"
        echo "ffmpeg_extra.sh: added cuCtxGetCurrent typedef to dynlink_cuda.h"
    fi
    if ! grep -q 'cuCtxGetCurrent' "$_ldr" 2>/dev/null; then
        sed -i 's/tcuCtxPopCurrent_v2 \*cuCtxPopCurrent;/&\n    tcuCtxGetCurrent *cuCtxGetCurrent;/' "$_ldr"
        sed -i 's/LOAD_SYMBOL(cuCtxPopCurrent, tcuCtxPopCurrent_v2, "cuCtxPopCurrent_v2");/&\n    LOAD_SYMBOL(cuCtxGetCurrent, tcuCtxGetCurrent, "cuCtxGetCurrent");/' "$_ldr"
        echo "ffmpeg_extra.sh: added cuCtxGetCurrent to CudaFunctions and loader in dynlink_loader.h"
    fi
}