---
name: run-tests
description: Runs the smartpowerswitch Flutter test suite reliably on this Windows machine, via scripts/run_tests.ps1 from PowerShell. Use whenever you need to run `flutter test` (or otherwise verify the test suite passes) in this repo — never invoke `flutter test`/`flutter run` directly through Git Bash here, it reliably crashes the Dart VM.
---

# Running the smartpowerswitch test suite

This machine has a specific, reproducible failure mode for Flutter/Dart
test commands — read this before running `flutter test` any other way.
Full background: the root [`CLAUDE.md`](../../../CLAUDE.md), "Windows
test-runner gotcha" section.

## The rule

**Always run `flutter test` (and `flutter run`) from PowerShell, never
from Git Bash, on this machine.** Running them through Git Bash reliably
crashes the Dart VM with `os_thread.cc: Could not start thread
DartWorker: 22 (The device does not recognize the command.)`. This is a
Git Bash pty/MSYS layer problem, not a bug in this project's code — it
will not go away by changing project code or test code.

Separately, leftover `dart` / `dartaotruntime` / `flutter_tester`
processes from a prior crashed or interrupted run cause resource
contention that produces a **second, different** crash on the next
attempt — a Dart VM compiler fault (e.g. a CFG dump during regex JIT
compilation, exiting with code 9) — even from a clean PowerShell session.
Kill those stray processes before every run.

## How to run it

Use the provided script — it already does the stray-process cleanup and
runs the suite correctly:

```powershell
# From the repo root, in a real PowerShell session (not Git Bash / the
# Bash tool)
powershell -File scripts/run_tests.ps1

# Extra flutter test args pass through, e.g. to run one file:
powershell -File scripts/run_tests.ps1 test/some_widget_test.dart
```

What [`scripts/run_tests.ps1`](../../../scripts/run_tests.ps1) actually
does (read it before assuming — it's short):
1. Enumerates processes named `dart`, `dartaotruntime`, or
   `flutter_tester` via `Get-CimInstance Win32_Process`, and force-stops
   any whose command line does **not** match
   `language-server|tooling-daemon|devtools|flutter_tools.*daemon` — i.e.
   it kills stray/crashed test runners but leaves the legitimate VS Code
   Dart-extension services (language server, tooling daemon, devtools,
   flutter_tools daemon) alone. Don't "helpfully" broaden this to kill all
   `dart.exe` processes; that would take down the IDE's Dart tooling too.
2. `Start-Sleep -Seconds 1` to let process teardown finish.
3. Runs `flutter test --concurrency=1 @args` in the **foreground**.

## Timeout and execution mode

- Run this **in the foreground**, not backgrounded. A backgrounded
  `flutter test` run has been observed to die silently with no
  recoverable output if the host session restarts mid-run — you want to
  see it through to completion.
- Use a **generous timeout**. The full suite takes roughly 70 seconds once
  the environment is clean; give it several minutes of headroom (e.g. a
  300+ second timeout) rather than the tool default, since a clean-but-slow
  run should not be mistaken for a hang.
- Do not retry a failing run in a tight loop. If it crashes, diagnose
  which of the two known crash modes it is (see Troubleshooting) before
  re-running.

## Troubleshooting

**Crash mentions `os_thread.cc` / `Could not start thread DartWorker`**
→ You (or whoever invoked this) ran it through Git Bash. Re-run from a
real PowerShell session instead. This is not fixable by retrying in Bash.

**Crash is a Dart VM compiler fault / CFG dump during regex JIT
compilation, exit code 9 — even from PowerShell**
→ Stray processes from a previous crashed run are still holding
resources. Re-run `scripts/run_tests.ps1` — its cleanup step should catch
these; if it still crashes, manually check for lingering `dart.exe`,
`dartaotruntime.exe`, `flutter_tester.exe` processes (Task Manager or
`Get-CimInstance Win32_Process` in PowerShell) and stop any that aren't
VS Code's Dart tooling services, then retry.

**Crashes persist even with a demonstrably clean process list**
→ Worth checking whether Windows Defender (or another AV/EDR) has
real-time-scanning exclusions configured for `C:\flutter`, the pub cache
(`%LOCALAPPDATA%\Pub\Cache`), and this project directory — antivirus hooks
intercepting process/thread creation syscalls are a known cause of this
class of intermittent native crash. This has **not** been confirmed as a
root cause in this repo, and checking requires admin rights — surface it
as a possibility to the user rather than something to fix yourself.

**A specific test looks flaky, not crashing**
→ That's a test-quality issue, not this environment issue — hand it to
`sherwin` rather than treating it as another instance of the Windows
gotcha.
