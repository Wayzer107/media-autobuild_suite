# Build Watcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a Claude Code scheduled agent that monitors the media-autobuild_suite FFmpeg build every 5 minutes, detects and diagnoses errors in build logs, sends Windows toast notifications, and self-cancels when the build finishes.

**Architecture:** A PowerShell notification helper (`notify.ps1`) handles Windows toasts via the built-in WinRT API. A detailed agent prompt (`watcher_prompt.md`) defines exactly what each scheduled Claude wake-up must do: load line-offset state, read new log content, pattern-match errors, analyze with reasoning, notify, and detect completion. All runtime state persists in `watcher_state.json` so each 5-minute agent run is stateless.

**Tech Stack:** PowerShell 7 (WinRT toast API), Claude Code `/schedule` skill, JSON state file, MSYS2 build log conventions.

---

## Task 1: Create `build/notify.ps1`

**Files:**
- Create: `build/notify.ps1`

- [ ] **Step 1: Write `build/notify.ps1`**

```powershell
param(
    [Parameter(Mandatory)][ValidateSet("error","success","warning")][string]$type,
    [Parameter(Mandatory)][string]$message
)

Add-Type -AssemblyName System.Runtime.WindowsRuntime

$null = [Windows.UI.Notifications.ToastNotificationManager,
         Windows.UI.Notifications,
         ContentType=WindowsRuntime]

$icons = @{ error = ""; success = ""; warning = "" }
$title = "Build Watcher [$($type.ToUpper())]"

$template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)
$nodes = $xml.GetElementsByTagName("text")
$nodes[0].InnerText = $title
$nodes[1].InnerText = $message

$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("media-autobuild_suite").Show($toast)
Write-Host "Notified: [$type] $message"
```

Save to: `C:\media\media-autobuild_suite\build\notify.ps1`

- [ ] **Step 2: Validate — fire a test toast for each type**

Run each line, verify a Windows toast appears in the bottom-right corner:

```powershell
powershell.exe -NonInteractive -File "C:\media\media-autobuild_suite\build\notify.ps1" error "vorbis: test error notification"
powershell.exe -NonInteractive -File "C:\media\media-autobuild_suite\build\notify.ps1" success "Build complete — 42 packages, 0 failed"
powershell.exe -NonInteractive -File "C:\media\media-autobuild_suite\build\notify.ps1" warning "make check failure in opus (non-blocking)"
```

Expected: three toast pop-ups appear with the correct title and message. Console prints `Notified: [<type>] <message>`.

If toasts don't appear, check Windows Settings → System → Notifications → ensure notifications are enabled for PowerShell/your terminal app.

- [ ] **Step 3: Validate error on bad type**

```powershell
powershell.exe -NonInteractive -File "C:\media\media-autobuild_suite\build\notify.ps1" badtype "should fail"
```

Expected: PowerShell validation error — `badtype` is not in the ValidateSet. Exit code non-zero.

---

## Task 2: Write the watcher agent prompt

**Files:**
- Create: `build/watcher_prompt.md`

This file is the complete, self-contained instruction set for the scheduled Claude agent. Every 5-minute wake-up reads and follows this prompt.

- [ ] **Step 1: Write `build/watcher_prompt.md`**

Save the following content exactly to `C:\media\media-autobuild_suite\build\watcher_prompt.md`:

````markdown
# Build Watcher Agent — Per-Run Instructions

You are a scheduled build monitoring agent for media-autobuild_suite. Execute the following steps in order every time you are invoked.

## Paths

- Build dir (Windows): `C:\media\media-autobuild_suite\build\`
- Build dir (MSYS2/bash): `/c/media/media-autobuild_suite/build/`
- State file: `C:\media\media-autobuild_suite\build\watcher_state.json`
- Error log: `C:\media\media-autobuild_suite\build\watch_errors.log`
- Notify script: `C:\media\media-autobuild_suite\build\notify.ps1`
- Compile log: `C:\media\media-autobuild_suite\build\compile.log`

## Step 1 — Load State

Read `watcher_state.json`. If missing or empty, use these defaults:

```json
{
  "compile_log_line": 0,
  "pkg_log_lines": {},
  "reported_error_hashes": [],
  "stale_count": 0,
  "build_done": false,
  "errors_seen": 0,
  "schedule_job_id": ""
}
```

If `build_done` is `true`, stop immediately — the build is already finished.

## Step 2 — Read New `compile.log` Content

Read `compile.log` using the Read tool with `offset: <compile_log_line>`. Capture all new lines. Update `compile_log_line` to the new total line count of the file.

Strip ANSI escape sequences from all text before processing. Use this bash command to get clean content:

```bash
tail -n +<compile_log_line> /c/media/media-autobuild_suite/build/compile.log \
  | sed 's/\x1b\[[0-9;]*[mBCDHJKmnsu]//g; s/\x1b\][^a-zA-Z]*[a-zA-Z]//g; s/\r//g; s/\[?[0-9]*[hl]//g; s/\[6n//g'
```

## Step 3 — Scan New Package Logs

Find all package build logs:

```bash
find /c/media/media-autobuild_suite/build -name "ab-suite.*.log" | sort
```

For each file path, read from line `pkg_log_lines[filepath]` (default 0) to EOF. Update `pkg_log_lines[filepath]` to the new line count. Strip ANSI from content.

## Step 4 — Detect Errors

For each block of new text, check for these patterns:

**In `compile.log` new lines:**
- Line matches `└` AND contains `[Failed]` → suite failure marker

**In `ab-suite.*.log` new lines:**
- `make: \*\*\*` → make rule failure
- `configure: error:` → autoconf failure
- `CMake Error` → cmake failure
- A file path followed by a line/column number followed by ` error:` → compiler error (e.g. `foo.c:42:5: error:`)
- `undefined reference to` → linker error
- `fatal error:` and the line is not a comment → missing header
- `No package '` → missing pkg-config dep
- `Permission denied` → filesystem error
- `No such file or directory` on a path that is not inside a `make check` or `make test` block

**Exclusions — skip lines that:**
- Start with `#`
- Contain `error` only inside a URL (`http://` or `https://`)
- Appear between a line containing `make check` or `make test` and the next blank line or `make:` line (test output — log as warning, not error)

**Deduplication:**
For each matched line, compute: `sha256("<filepath>|<matched_line_stripped>")`. If this hash is already in `reported_error_hashes`, skip it.

## Step 5 — Analyze and Report Each New Error

For each new (non-duplicate) error:

**a. Gather context:**
- Note the file path and matched line
- Read ±30 lines around the match from the same file
- Identify the package: extract the directory name between `build/` and the next `/` in the file path (e.g. `build/vorbis-git/ab-suite.make.log` → package is `vorbis`)
- In the package directory, read whichever of these exists: `ab-suite.configure.log`, `ab-suite.make.log`, `ab-suite.cmake.log` — pick the one most relevant to the error type

**b. Diagnose:**
Using the matched line, context, and full relevant log, determine:
- The most likely cause (examples: "ogg dependency not found in pkg-config path", "C++17 required but compiler flag not set", "network timeout during git fetch", "patch rejected — upstream changed")
- A concrete suggested fix if determinable (examples: "rebuild ogg first", "add -std=c++17 to CXXFLAGS", "retry — transient network issue")

**c. Write to `watch_errors.log`** (append):

```
[HH:MM:SS] ERROR in <package> (<logfile name>)
Raw:     <matched line>
Context: <±30 surrounding lines>
Likely cause: <your diagnosis>
Suggested fix: <fix or "Unable to determine from available context">
---
```

**d. Fire toast:**

```
powershell.exe -NonInteractive -File "C:\media\media-autobuild_suite\build\notify.ps1" error "<package>: <one-sentence diagnosis>"
```

**e. Update state:**
- Add hash to `reported_error_hashes`
- Increment `errors_seen`

## Step 6 — Check for Build Completion

Run both checks:

**Check A — Process check:**
```powershell
powershell.exe -NonInteractive -Command "Get-Process -Name mintty,bash -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count"
```
If output is `0`, the build process has exited → build is complete.

**Check B — Stale log check:**
If no new lines were found in `compile.log` this run, increment `stale_count`. If `stale_count >= 2`, build is complete.
If new lines were found, reset `stale_count` to 0.

If neither check triggers completion, skip to Step 8.

## Step 7 — Handle Build Completion

**a. Classify outcome:**

Check the full `compile.log` for any `[Failed]` lines:
```bash
grep -c "\[Failed\]" /c/media/media-autobuild_suite/build/compile.log
```

Check if a core dependency failed (ogg, zlib, x264, openssl, ffmpeg):
```bash
grep "\[Failed\]" /c/media/media-autobuild_suite/build/compile.log | grep -iE "ogg|zlib|x264|openssl|ffmpeg"
```

Classify:
- `errors_seen == 0` AND no `[Failed]` lines → **Success**
- `errors_seen > 0` AND no core dep failed → **Partial failure**
- Core dep failed → **Hard stop**

**b. Compute elapsed time:**

```bash
head -5 /c/media/media-autobuild_suite/build/compile.log | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1
tail -5 /c/media/media-autobuild_suite/build/compile.log | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | tail -1
```

**c. Count packages:**
```bash
grep -c "└" /c/media/media-autobuild_suite/build/compile.log
```

**d. Fire completion toast:**

For Success:
```
powershell.exe -NonInteractive -File "C:\media\media-autobuild_suite\build\notify.ps1" success "Build complete — <N> packages, 0 errors, elapsed <HH:MM>"
```

For Partial failure:
```
powershell.exe -NonInteractive -File "C:\media\media-autobuild_suite\build\notify.ps1" error "Build done with <errors_seen> errors — see build/watch_errors.log"
```

For Hard stop:
```
powershell.exe -NonInteractive -File "C:\media\media-autobuild_suite\build\notify.ps1" error "Build HARD STOP — core dependency failed, downstream packages cascade-failed"
```

**e. Set `build_done: true` in state.**

**f. Save `watcher_state.json`.**

**g. Cancel this scheduled routine:**
Use the schedule skill to delete the job with ID stored in `schedule_job_id`. If the job ID is empty, skip cancellation and note it in your response.

**STOP — do not continue past this point.**

## Step 8 — Save State

Write the updated state object back to `C:\media\media-autobuild_suite\build\watcher_state.json` as valid JSON.

End your response with a one-line status summary, e.g.:
`Watcher run complete: 3 new errors found in vorbis, flac. stale_count=0. Build still running.`
````

- [ ] **Step 2: Validate the prompt file is complete**

Read `C:\media\media-autobuild_suite\build\watcher_prompt.md` and confirm:
- All 8 steps are present
- All bash commands include actual paths (not placeholders)
- The JSON default state block is syntactically valid:

```powershell
'{"compile_log_line":0,"pkg_log_lines":{},"reported_error_hashes":[],"stale_count":0,"build_done":false,"errors_seen":0,"schedule_job_id":""}' | ConvertFrom-Json | ConvertTo-Json
```

Expected: PowerShell outputs the object as formatted JSON with no errors.

---

## Task 3: Initialize `watcher_state.json` and do a dry-run

**Files:**
- Create: `build/watcher_state.json` (ephemeral, overwritten each agent run)

- [ ] **Step 1: Write initial `watcher_state.json`**

Run (replace `<JOB_ID>` after registering the schedule in Task 4 — leave empty for now):

```powershell
@'
{
  "compile_log_line": 0,
  "pkg_log_lines": {},
  "reported_error_hashes": [],
  "stale_count": 0,
  "build_done": false,
  "errors_seen": 0,
  "schedule_job_id": ""
}
'@ | Set-Content -Encoding UTF8 "C:\media\media-autobuild_suite\build\watcher_state.json"
```

- [ ] **Step 2: Dry-run — manually simulate one watcher cycle against the current logs**

Open Claude Code in this project directory and run the following prompt manually (paste it):

```
Read C:\media\media-autobuild_suite\build\watcher_prompt.md and follow it exactly. This is a dry-run — do NOT cancel any schedule and do NOT write to watcher_state.json at the end. Instead, report what you would have done: list any errors found, their diagnoses, and the state values you would have written.
```

Expected output: Claude reads the prompt, reads `compile.log`, reads any `ab-suite.*.log` files, reports any errors with diagnoses, and shows the JSON it would write — without actually modifying state.

Review the output:
- Error patterns are being matched correctly
- Diagnoses are coherent (not hallucinated paths or packages)
- State JSON structure is valid

- [ ] **Step 3: Validate `notify.ps1` is callable from the agent context**

```powershell
powershell.exe -NonInteractive -File "C:\media\media-autobuild_suite\build\notify.ps1" success "Dry-run complete — watcher is ready"
```

Expected: toast appears.

---

## Task 4: Register the scheduled routine

**Files:**
- Modify: `build/watcher_state.json` — add the `schedule_job_id` after registration

- [ ] **Step 1: Register via the `/schedule` skill**

In Claude Code, run:

```
/schedule
```

When prompted, provide:
- **Name:** `media-autobuild-watcher`
- **Schedule:** every 5 minutes (`*/5 * * * *`)
- **Prompt:** the full contents of `C:\media\media-autobuild_suite\build\watcher_prompt.md`

Note the job ID returned by the skill (format is typically a UUID or short alphanumeric string).

- [ ] **Step 2: Store the job ID in `watcher_state.json`**

Replace `<JOB_ID>` with the actual ID from Step 1:

```powershell
$state = Get-Content "C:\media\media-autobuild_suite\build\watcher_state.json" | ConvertFrom-Json
$state.schedule_job_id = "<JOB_ID>"
$state | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "C:\media\media-autobuild_suite\build\watcher_state.json"
```

Verify:
```powershell
(Get-Content "C:\media\media-autobuild_suite\build\watcher_state.json" | ConvertFrom-Json).schedule_job_id
```

Expected: prints the job ID (non-empty string).

- [ ] **Step 3: Verify the schedule is registered**

In Claude Code, run:

```
/schedule list
```

Expected: `media-autobuild-watcher` appears in the list with a 5-minute interval.

- [ ] **Step 4: Wait for first real agent run and inspect output**

Wait up to 5 minutes for the first scheduled run. Then check:

```powershell
# Check state was updated
Get-Content "C:\media\media-autobuild_suite\build\watcher_state.json" | ConvertFrom-Json | Select compile_log_line, errors_seen, stale_count

# Check error log (may be empty if no errors)
if (Test-Path "C:\media\media-autobuild_suite\build\watch_errors.log") {
    Get-Content "C:\media\media-autobuild_suite\build\watch_errors.log"
} else {
    Write-Host "No errors detected yet — watch_errors.log not created"
}
```

Expected: `compile_log_line` is greater than 0 (agent read the log). `errors_seen` reflects actual error count. `watch_errors.log` exists only if errors were found.

---

## Task 5: Post-build cleanup reference

> This task is reference only — no action needed now. Run after the build finishes.

- [ ] **Manual cancel (if self-cancel fails):**

```
/schedule delete media-autobuild-watcher
```

- [ ] **Review full error summary:**

```powershell
Get-Content "C:\media\media-autobuild_suite\build\watch_errors.log"
```

- [ ] **Clean up ephemeral files:**

```powershell
Remove-Item "C:\media\media-autobuild_suite\build\watcher_state.json" -ErrorAction SilentlyContinue
# Keep watch_errors.log for reference — delete manually when done
```
