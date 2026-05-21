---
name: run-media-autobuild-suite
description: Launch and monitor the FFmpeg + media tools Windows build suite; programmatic driver for long-running batch builds.
---

# Running media-autobuild_suite

This Windows build harness compiles FFmpeg and ~100 media tools as static MinGW-w64 binaries. The build takes **hours** and runs unattended in the background.

The driver (`driver.ps1`) launches the build, monitors progress via the compile log, and reports status. This is the way agents (and humans) drive the suite programmatically — no window-watching required.

## Prerequisites

- **Windows 10+** (required — MSYS2 and MinGW-w64 only on Windows)
- **MSYS2** — installed by the batch file; first run takes time to initialize
- **~50 GB free disk** — FFmpeg + 100 tools + build artifacts
- **PowerShell 5.0+** — for the driver script

Nothing else to install. The batch file bootstraps MSYS2 automatically.

## Build

```powershell
# Build step 1: download MSYS2 and media-autobuild_suite base packages
cd C:\Users\<user>\Documents\repo\media-autobuild_suite
.\media-autobuild_suite.bat

# The batch file will:
# 1. Download and initialize MSYS2 (once, slow)
# 2. Update pacman packages (every run)
# 3. Launch media-suite_compile.sh (the main build loop)
# 4. Run for 2-8 hours depending on options and network
```

Pre-configured **FFmpeg option tiers** in the batch file:
- `n` (basic) — minimal options
- `z` (zeranoe-compat) — common defaults
- `f` (full) — all codecs/filters
- Custom mode — edit `build/ffmpeg_options.txt`

## Run (Agent Path)

Use the `driver.ps1` script to launch and monitor the build programmatically:

```powershell
# Launch build in background
.\.claude\skills\run-media-autobuild-suite\driver.ps1 -Action launch

# Monitor progress (tails compile.log, reports every 5 seconds)
.\.claude\skills\run-media-autobuild-suite\driver.ps1 -Action monitor -Timeout 14400

# Check current status (packages completed, errors detected)
.\.claude\skills\run-media-autobuild-suite\driver.ps1 -Action status

# Stop the build
.\.claude\skills\run-media-autobuild-suite\driver.ps1 -Action stop
```

**Output files:**
- **`build/compile.log`** — main suite progress (tailed by `monitor`)
- **`build/<pkg>-git/ab-suite.*.log`** — per-package logs (configure, make, install)
- **`local64/`** / **`local32/`** — compiled binaries, libraries, headers
- **`build/watcher_state.json`** — build completion status and error tracking

## Run (Human Path)

Double-click `media-autobuild_suite.bat` → a terminal window opens → watch it build → Ctrl-C to stop.

**Note:** This is a long process; the window must stay open. Use the agent path (above) to launch in the background and monitor via script.

## Direct Invocation

To rebuild one package after a failure, use the compile script directly:

```bash
# In MSYS2 shell:
cd /c/media/media-autobuild_suite/build
bash media-suite_compile.sh --only=x264

# Force a complete rebuild of one package:
rm -f /local64/lib/pkgconfig/x264.pc
bash media-suite_compile.sh --only=x264
```

## Gotchas

1. **MSYS2 initialization is slow.** First run downloads ~500 MB and configures the environment. Subsequent runs are much faster (pacman updates only).

2. **Compilation failures are often transient.** Network timeouts, git fetch interruptions, or stale package repos can cause failures. Before debugging, try rebuilding the failed package:
   ```bash
   rm /local64/lib/pkgconfig/<pkg>.pc
   bash media-suite_compile.sh --only=<pkg>
   ```

3. **Paths are Unix-style inside MSYS2.** `C:\path\to\file` becomes `/c/path/to/file`. The batch file handles this translation, but if you manually re-run `media-suite_compile.sh`, use `/c/media/...` paths.

4. **Build output goes to `/local64/` (or `/local32/`)** inside the MSYS2 environment, which maps to `local64/` relative to the project root. Final binaries are in `local64/bin-audio/`, `local64/bin-video/`, `local64/bin-global/`.

5. **FFmpeg options are baked in at configure time.** Changing options requires a clean rebuild:
   ```bash
   rm /local64/lib/pkgconfig/ffmpeg.pc
   # Then re-run the build
   ```

6. **Pacman package conflicts can occur.** If MSYS2 fails to update, try a clean pacman database:
   ```bash
   pacman -Sc  # clear cache
   pacman -Syu  # update
   ```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| MSYS2 download stuck / timeout | Network issue | Wait / retry; MSYS2 init can take 10+ minutes on slow networks |
| `configure: error: ... not found` | Missing build dependency | Likely a MSYS2/MinGW package; try `pacman -Syu` and rebuild |
| `make: *** ... Error 1` | Compilation failed in package source | Check `build/<pkg>-git/ab-suite.make.log`; may be a known issue with that version |
| `undefined reference to` | Linker error; missing library | Ensure dependent packages built first; check build order in `media-suite_compile.sh` |
| Process hangs indefinitely | Stalled (git fetch, network I/O) | Kill via driver (`-Action stop`) and retry; try `pacman -Syu` first |
| `Permission denied` during install | File permission issue (rare on Windows) | Delete package `.pc` file and force rebuild |
| No output for 5+ minutes | Normal for slow network or large compilation | Use `driver.ps1 -Action status` to check progress; don't interrupt |

## Monitoring Errors Programmatically

The build logs are written to `build/compile.log` and per-package `build/<pkg>-git/ab-suite.*.log` files. To detect errors automatically:

```powershell
# Check for [Failed] markers in the compile log
Select-String '\[Failed\]' build/compile.log

# Check package-specific logs for common errors
Get-ChildItem build -Recurse -Filter "ab-suite.*.log" |
  ForEach-Object {
    $errors = Select-String '(make: \*\*\*|configure: error:|CMake Error)' $_
    if ($errors) {
      Write-Host "Errors in $_"
      $errors
    }
  }
```

For an automated error-detection agent that runs every 5 minutes and fires Windows toasts, see `build/watcher_prompt.md`.