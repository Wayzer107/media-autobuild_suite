# Build Watcher Design

**Date:** 2026-05-20  
**Project:** media-autobuild_suite  
**Scope:** Scheduled Claude Code agent that monitors the FFmpeg build, detects and diagnoses errors, sends Windows toast notifications, and self-cancels when the build finishes.

---

## 1. Architecture

Four components:

| Component | Path | Role |
|---|---|---|
| State file | `build/watcher_state.json` | Persists log byte-offsets and seen-error hashes between agent runs |
| Notify script | `build/notify.ps1` | PowerShell helper that fires Windows toast notifications |
| Error summary | `build/watch_errors.log` | Append-only log of every error found, with timestamps and diagnosis |
| Scheduled agent | Claude Code routine | Wakes every 5 min, reads new log data, analyzes errors, notifies, self-cancels on completion |

The agent is stateless per-run — all state lives in `watcher_state.json`. Each 5-minute wake-up reads only log content it hasn't seen before (via byte offsets).

---

## 2. Per-run Agent Logic

Each wake-up executes in order:

1. **Load state** — read `build/watcher_state.json`; if missing, initialize:
   ```json
   {
     "compile_log_offset": 0,
     "pkg_log_offsets": {},
     "reported_error_hashes": [],
     "stale_count": 0,
     "build_done": false,
     "errors_seen": 0,
     "schedule_job_id": "<id stored at creation>"
   }
   ```

2. **Read new `compile.log` bytes** — seek to `compile_log_offset`, read to EOF, strip ANSI escape codes, update offset in state.

3. **Scan new package logs** — find all `build/<pkg>-git/ab-suite.*.log` files; for each, read only bytes since its last offset in `pkg_log_offsets`.

4. **Detect errors** — match error patterns (see Section 3) against all new text. Deduplicate via SHA256 hash of `(filepath, matched_line)` against `reported_error_hashes`.

5. **For each new error:**
   - Read ±30 lines of surrounding context from the log file
   - Also read the full `ab-suite.configure.log`, `ab-suite.make.log`, or `ab-suite.cmake.log` for that package if the error came from a make/configure step
   - **Analyze**: reason about likely cause (missing dependency, version mismatch, patch failure, network issue, compiler flag problem, linker error, etc.)
   - Append a structured entry to `build/watch_errors.log`:
     ```
     [HH:MM:SS] ERROR in <pkg> (<logfile>)
     Raw:    <matched line>
     Context: <±30 lines>
     Likely cause: <agent diagnosis>
     Suggested fix: <if determinable>
     ---
     ```
   - Fire toast: `notify.ps1 error "<pkg>: <one-line diagnosis>"`
   - Increment `errors_seen`, add hash to `reported_error_hashes`

6. **Detect completion** — see Section 4. If build is done, go to step 7; otherwise save state and exit.

7. **On completion:**
   - Classify outcome: success / partial failure / hard stop (see Section 4)
   - Compute elapsed time from first and last timestamps in `compile.log`
   - Fire toast: `notify.ps1 success "Build done: <N> packages, <M> failed, <elapsed>"`  
     or `notify.ps1 error "Build FAILED: <M> errors — see build/watch_errors.log"`
   - Cancel scheduled routine using `schedule_job_id`
   - Set `build_done: true` in state and save

---

## 3. Error Detection Patterns

All matching runs on ANSI-stripped text.

### In `compile.log`
| Pattern | Meaning |
|---|---|
| `[Failed]` in a `└ <pkg>` status line | Suite's own failure indicator |
| `died with` / `exited with` | Process crash |

### In per-package `ab-suite.*.log` files
| Pattern | Meaning |
|---|---|
| `make: ***` | Make rule failure |
| `configure: error:` | Autoconf configure failure |
| `CMake Error` | CMake configuration failure |
| `error:` preceded by a file path (e.g. `foo.c:42: error:`) | Compiler error |
| `undefined reference to` | Linker error |
| `fatal error:` | Missing header |
| `No package '...' found` | Missing pkg-config dependency |
| `Permission denied` / `No such file or directory` in critical paths | Filesystem/env error |

### False-positive exclusions
- Lines starting with `#`
- Lines containing `error` inside a URL
- Lines within `make check` / `make test` sections — flagged as warnings, not errors (test failures don't always block the build)

---

## 4. Completion Detection

Two signals — either triggers "build done":

**Primary — stale log detection:**  
If `compile.log` byte count hasn't changed for two consecutive 5-minute runs, set `stale_count += 1`. When `stale_count >= 2`, declare the build complete.

**Secondary — process check (runs every wake-up):**  
`Get-Process -Name mintty,bash -ErrorAction SilentlyContinue` — if no MSYS2/mintty process exists, the build has exited.

**Outcome classification:**
| Condition | Classification |
|---|---|
| Done + `errors_seen == 0` | **Success** |
| Done + `errors_seen > 0` | **Partial failure** |
| Done + `[Failed]` on a core dep (ogg, zlib, x264, etc.) | **Hard stop** — noted explicitly since downstream packages cascade-fail |

The completion toast includes: packages built, packages failed, elapsed time.

---

## 5. Notification Script (`build/notify.ps1`)

```powershell
param(
    [string]$type,    # "error" | "success" | "warning"
    [string]$message
)

[Windows.UI.Notifications.ToastNotificationManager,
 Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null

$template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)
$xml.GetElementsByTagName("text")[0].InnerText = "Build Watcher [$type]"
$xml.GetElementsByTagName("text")[1].InnerText = $message
$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("media-autobuild_suite").Show($toast)
```

No external modules required — uses the WinRT API built into Windows 10/11.

The agent calls it via:
```
powershell.exe -NonInteractive -File build/notify.ps1 error "vorbis: missing ogg dependency"
```

---

## 6. Self-Cancellation

At schedule creation time, the job ID is stored in `watcher_state.json` as `schedule_job_id`. When the build is detected as complete, the agent calls the schedule skill's delete API with this ID to remove the routine automatically.

---

## 7. Files Created by This Feature

```
build/
  notify.ps1            # toast notification helper
  watcher_state.json    # runtime state (gitignored)
  watch_errors.log      # error summary with diagnoses (gitignored)
```

`watcher_state.json` and `watch_errors.log` should be added to `.gitignore` (or the suite's equivalent ignore list) since they are ephemeral build artifacts.

---

## 8. Constraints & Assumptions

- The build runs in MSYS2 on Windows 10/11 — WinRT toast API is available.
- `compile.log` and per-package logs are written in real time by the build process.
- The Claude Code schedule skill can store and cancel jobs by ID.
- The agent has read access to all files under `c:\media\media-autobuild_suite\build\`.
- Toast notifications are enabled in Windows notification settings for the running user.
