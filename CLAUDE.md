# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A Windows batch + MSYS2/bash build suite that compiles FFmpeg and ~100 other media tools as static Windows binaries via MinGW-w64/GCC. It runs exclusively inside an MSYS2 environment on Windows — the bash scripts require Cygwin-style paths and MSYS2 tooling. They cannot be executed on native Linux/macOS.

## Running the Suite

The user-facing entry point is `media-autobuild_suite.bat` (double-click on Windows). It bootstraps MSYS2 and then calls the bash scripts automatically. There is no separate test suite or linter to run.

To rerun just the compile phase inside an MSYS2 shell (for development/debugging):
```bash
bash /build/media-suite_compile.sh [options]
```

Options match the `--key=value` flags parsed at the top of `media-suite_compile.sh` (e.g. `--ffmpeg=y --build64=yes`).

## Architecture

### Script Execution Flow

```
media-autobuild_suite.bat
  └─ sets up MSYS2, reads/writes build/media-autobuild_suite.ini
  └─ calls media-suite_update.sh   (pacman updates every run)
  └─ calls media-suite_compile.sh  (the main build loop)
        ├─ sources media-suite_deps.sh        (SOURCE_REPO_* variables)
        ├─ sources media-suite_deps_extra.sh  (user URL overrides, if present)
        ├─ sources media-suite_helper.sh      (all helper functions)
        └─ calls buildProcess()
```

### Key Files

| File | Role |
|---|---|
| `media-autobuild_suite.bat` | Entry point; defines FFmpeg option presets (`ffmpeg_options_builtin/basic/zeranoe/full`) |
| `build/media-suite_deps.sh` | All `SOURCE_REPO_*` git URLs; supports `#branch=`, `#tag=`, `#commit=` suffixes |
| `build/media-suite_compile.sh` | Ordered build recipes for every library and tool |
| `build/media-suite_helper.sh` | Reusable bash functions used throughout compile |
| `build/media-suite_update.sh` | Pacman/MSYS2 environment updates |
| `build/media-suite_deps_extra.sh` | *(not committed)* User overrides for `SOURCE_REPO_*` variables |

### How a Library Build Works

Each library in `media-suite_compile.sh` follows this pattern:

```bash
_check=(foo.pc)          # files that signal "already built"
if do_vcs "$SOURCE_REPO_FOO" foo; then
    do_configure --prefix="$LOCALDESTDIR" ...
    do_makeinstall
    do_checkIfExist      # writes build_successful[32|64]bit
fi
```

- `do_vcs` clones/updates the repo and returns 0 only when a rebuild is needed.
- `do_pkgConfig "foo >= 1.0"` is an alternative check for tarball/release packages.
- `do_checkIfExist` stamps a `build_successful*` sentinel so the package is skipped on the next run.
- Build outputs land in `/local32/` or `/local64/` (`$LOCALDESTDIR`), mirroring a standard prefix layout (`lib/`, `include/`, `bin-audio/`, `bin-video/`, `bin-global/`).

### FFmpeg Option Handling

FFmpeg configure flags flow through:
1. `ffmpeg_options_builtin` + tier options from the `.bat` file (when `ffmpegChoice` is `n`/`z`/`f`)
2. Or from `/build/ffmpeg_options.txt` (custom mode)
3. `do_getFFmpegConfig` reads them into `FFMPEG_OPTS[]`
4. `do_changeFFmpegConfig` applies license constraints and CUDA validation
5. `enabled <flag>` / `disabled <flag>` helpers query `FFMPEG_OPTS[]` throughout the compile script

License tiers: `lgpl` → `gpl` → `gplv3` → `nonfree`. Some options (`cuda-nvcc`, `libnpp`, `decklink`, `fdk-aac`) are gated to `nonfree`.

### Pinned Dependency URLs

`build/media-suite_deps.sh` defines every source URL. To pin a dependency to an older version:
```bash
SOURCE_REPO_FOO=https://github.com/org/foo.git#tag=v1.2.3
SOURCE_REPO_FOO=https://github.com/org/foo.git#branch=release/1.x
SOURCE_REPO_FOO=https://github.com/org/foo.git#commit=abc1234
```

To override without editing the checked-in file, create `build/media-suite_deps_extra.sh` (gitignored) and redefine the variable there.

## Forcing a Rebuild

- **Most libraries** (use pkg-config): delete `/local[32|64]/lib/pkgconfig/<libname>.pc`
- **Non-pkgconfig libraries**: delete `/local[32|64]/lib/lib<name>.a`
- **Binaries/tools**: delete the `.exe` from the appropriate `bin-audio/`, `bin-video/`, or `bin-global/`
- **From inside the repo folder**: `touch recompile` or `touch custom_updated`

See `doc/forcing-recompilations.md` for the full list.

## Custom Patches and Extra Scripts

Place `/build/<reponame>_extra.sh` (e.g. `ffmpeg_extra.sh` for `ffmpeg-git`) to inject commands around build steps. Available hook functions:

```bash
_pre_configure()   # before ./configure or cmake
_post_configure()  # after configure
_pre_make()        # before make/ninja
_post_make()       # after make
_pre_install()     # before make install
_post_install()    # after make install
```

Use `touch do_not_reconfigure` inside the script to skip the configure step entirely (and take full control via `_pre_cmake` / `_pre_ninja`).

Variables available in extra scripts:
- `$REPO_DIR` — the cloned source directory (e.g. `ffmpeg-git`)
- `$LOCALDESTDIR` — install prefix (`local64` or `local32`)
- `$bits` — `64bit` or `32bit`

## Important Helper Functions

All defined in `build/media-suite_helper.sh`:

| Function | Purpose |
|---|---|
| `do_vcs "URL" folder` | Clone/update a git repo; returns 0 if rebuild needed |
| `do_wget [-h hash] URL` | Download and extract a tarball |
| `do_configure [args]` | Run `./configure` with logging |
| `do_cmakeinstall [dir] [args]` | Configure + build + install via CMake/Ninja |
| `do_makeinstall [args]` | `make && make install` |
| `do_checkIfExist` | Stamp build as complete |
| `do_pkgConfig "pkg >= ver"` | Check if a pkg-config package is up to date |
| `enabled / disabled` | Query FFmpeg options in `FFMPEG_OPTS[]` |
| `do_addOption / do_removeOption` | Modify `FFMPEG_OPTS[]` |
| `do_pacman_install pkg` | Install an MSYS2/MinGW package |
| `do_patch URL` | Download and apply a patch |
| `cd_safe dir` | `cd` with fatal error on failure |
| `log "label" cmd [args]` | Run command with per-step log file |
