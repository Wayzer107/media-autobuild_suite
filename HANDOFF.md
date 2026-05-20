# Session Handoff

## What Was Done

### Goal
Make the suite always compile FFmpeg against legacy `nv-codec-headers` (SDK 9.1) so that the resulting FFmpeg binary works on Kepler-generation NVIDIA GPUs (GTX 770, GK104, etc.) with CUDA 10.2 and driver ≤ 470.x.

### Change Made
**`build/media-suite_deps.sh` — `SOURCE_REPO_FFNVCODEC`**

| Before | After |
|--------|-------|
| `https://code.ffmpeg.org/FFmpeg/nv-codec-headers.git` (tracks HEAD) | `https://github.com/FFmpeg/nv-codec-headers.git#tag=n9.1.23.1` (pinned to SDK 9.1) |

The old URL pulled the latest headers (currently SDK 12.x), which require drivers that dropped Kepler support. The new URL is pinned to the last SDK that is compatible with Kepler hardware and CUDA 10.2.

### Why SDK 9.1 Specifically
- Kepler GPUs (compute capability 3.x) are supported up to CUDA 10.2 and driver 470.x (Linux) / 472.x (Windows)
- SDK 9.1 headers declare `NVENCAPI_MAJOR_VERSION 9` — within the API range those drivers expose
- SDK 9.2+ adds NVENC B-frame support and lookahead; Kepler hardware has neither, so nothing is lost
- NVDEC is not present on Kepler (GK104/GK110 era); `cuvid` (the older decode path) remains available

### What Was Verified
- Tag `n9.1.23.1` exists on GitHub and resolves to a specific commit
- The `#tag=` URL format parses correctly through `do_vcs` (same format used for `fontconfig`, `freetype`, `libressl`, `openal` in the same file)
- The cloned headers confirm `NVENCAPI_MAJOR_VERSION 9`, `NVENCAPI_MINOR_VERSION 1`
- FFmpeg default options in the bat file (`cuvid`, `nvenc`, `nvdec`, `ffnvcodec`) were already correct — no changes needed there

### Merged
PR #1 was merged to master via the GitHub UI.

## Current State

- **master** has the `ffnvcodec` pin (`build/media-suite_deps.sh`)
- **master** has `CLAUDE.md` (project architecture guide for Claude sessions)
- The feature branch `claude/ffmpeg-legacy-nvidia-support-bGJGt` can be deleted

## If You Want to Test the Build

On a Windows machine with a Kepler GPU and CUDA 10.2 / driver ≤ 470.x:

1. Pull master
2. Double-click `media-autobuild_suite.bat`
3. Select 64-bit, your desired license tier, CPU count
4. After the build completes, verify:
   ```
   local64\bin-video\ffmpeg.exe -encoders | findstr nvenc
   local64\bin-video\ffmpeg.exe -decoders | findstr cuvid
   ```
5. Test actual NVENC encode:
   ```
   ffmpeg -i input.mp4 -c:v h264_nvenc output.mp4
   ```

## Potential Future Work

- **If FFmpeg configure fails with missing NVENC API symbols**: a newer FFmpeg version may have hard-required SDK 10+ symbols. In that case, bump the pin to `n10.0.26.2` (SDK 10.0) and re-verify
- **If you also need to pin FFmpeg itself**: add `#tag=n6.1` or similar to `SOURCE_REPO_FFMPEG` in `media-suite_deps.sh` to freeze the FFmpeg version alongside the headers
- **To override without editing the checked-in file**: create `build/media-suite_deps_extra.sh` (gitignored) and redefine `SOURCE_REPO_FFNVCODEC` there
