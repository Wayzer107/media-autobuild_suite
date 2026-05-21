# OBS Studio Kepler Build — Design Spec

**Date:** 2026-05-21  
**Repo to be created:** `C:\media\obs-studio-kepler\`  
**Related:** `C:\media\media-autobuild_suite\` (read-only dependency — provides `local64/`)

---

## Context

The GTX 770 is a Kepler-generation NVIDIA GPU. NVIDIA dropped Kepler from NVENC SDK ≥10.x,
meaning OBS built against obs-deps' bundled NVENC headers (SDK ≥11.x) will fail to find a
capable device at runtime.

`media-autobuild_suite` already solves this for FFmpeg by pinning ffnvcodec to n9.1.23.1 and
backporting the missing `cuCtxGetCurrent` symbol. The output (`local64/`) contains:

- Kepler-compatible FFmpeg static libs
- Patched ffnvcodec 9.x headers at `local64/include/ffnvcodec/`

This repo builds OBS 30.x linked against that output instead of obs-deps' bundled FFmpeg,
and patches OBS's direct NVENC plugin to use the same headers.

---

## Constraints

- **No changes to media-autobuild_suite** — only its `local64/` output is consumed
- **Compiler:** VS 2026 Community (v18.0), `C:\Program Files\Microsoft Visual Studio\18\Community`
- **CMake generator:** `"Visual Studio 18 2026"`
- **Non-FFmpeg deps:** obs-deps pre-built binaries (Qt6, mbedTLS, curl, etc.)
- **OBS version:** 30.x (pinned tag, e.g. `30.2.2`)

---

## Repo Structure

```
C:\media\obs-studio-kepler\
├── build.ps1                    # Main build script
├── patches\
│   └── nvenc-sdk9.patch         # Redirect obs-nvenc NVENC headers to local64/include/ffnvcodec/
├── cmake\
│   └── FindFFmpeg.cmake         # CMake module override — points FFmpeg finder at local64/
├── CLAUDE.md
└── .gitignore                   # Ignores obs-studio/, build/, deps/
```

---

## build.ps1 Flow

```
1. Clone OBS 30.x (pinned tag)
2. Fetch obs-deps (Qt6, mbedTLS, curl, etc.) via OBS's own CI dep script
3. Apply patches/nvenc-sdk9.patch to obs-studio/
4. CMake configure (see flags below)
5. cmake --build build --config RelWithDebInfo
6. Output: build\rundir\RelWithDebInfo\
```

### CMake flags

```powershell
cmake -S obs-studio -B build `
  -G "Visual Studio 18 2026" -A x64 `
  -DCMAKE_PREFIX_PATH="C:\media\media-autobuild_suite\local64" `
  -DFFMPEG_ROOT="C:\media\media-autobuild_suite\local64" `
  -DCMAKE_MODULE_PATH="$PSScriptRoot\cmake;<obs-deps-cmake-path>" `
  -DENABLE_BROWSER=OFF
```

`CMAKE_MODULE_PATH` prepends `cmake/` so `FindFFmpeg.cmake` is found before OBS's bundled finder.

---

## Kepler NVENC — Two Patch Points

OBS has two independent NVENC code paths. Both must use SDK 9.x headers.

### 1. obs-ffmpeg (FFmpeg encode path)

Covered automatically by linking against `local64/`. The suite's FFmpeg already has:
- ffnvcodec 9.x version range accepted in `configure`
- `cuCtxGetCurrent` backported into `local64/include/ffnvcodec/`

No patch needed for this path.

### 2. obs-nvenc (direct NVENC API path)

OBS's `plugins/obs-nvenc` includes NVENC SDK headers fetched from obs-deps (SDK ≥11.x).
`patches/nvenc-sdk9.patch` rewrites the relevant `CMakeLists.txt` include path to use
`C:\media\media-autobuild_suite\local64\include\ffnvcodec\` instead.

The Kepler capability check inside obs-nvenc may also need a version guard relaxed — this
mirrors what was done to FFmpeg's `configure` script.

---

## cmake/FindFFmpeg.cmake

Thin override read before OBS's own FFmpeg finder:

```cmake
set(FFMPEG_ROOT "C:/media/media-autobuild_suite/local64" CACHE PATH "")
set(FFMPEG_INCLUDE_DIRS "${FFMPEG_ROOT}/include")
# Enumerate static libs from local64/lib/
file(GLOB FFMPEG_LIBRARIES "${FFMPEG_ROOT}/lib/libav*.a" "${FFMPEG_ROOT}/lib/libsw*.a")
# Parse version from pkgconfig
# ... set FFMPEG_FOUND, FFMPEG_VERSION
```

---

## CLAUDE.md (for the new repo)

Will document:
- How to run `build.ps1` (prerequisites, first run vs. incremental)
- How to update the pinned OBS tag
- Where build output lands
- What the two patch points do and when to re-apply them
- How `local64/` from the suite is consumed (read-only)

---

## Verification

1. Launch `build\rundir\RelWithDebInfo\bin\64bit\obs64.exe`
2. Settings → Output → Recording: NVENC encoder appears in dropdown
3. Start recording — no `[obs-nvenc] No capable devices found` in OBS log
4. Check `[ffmpeg]` log lines confirm `h264_nvenc` encoder initialised
