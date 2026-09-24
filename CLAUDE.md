# CLAUDE.md

## Windows test-runner gotcha (read before running `flutter test`)

Running `flutter`/`dart` test commands through **Git Bash** on this machine reliably crashes
the Dart VM: `os_thread.cc: Could not start thread DartWorker: 22 (The device does not
recognize the command.)`. This is a Git Bash pty/MSYS layer problem, not a bug in this
project's code. **Always run `flutter test` (and `flutter run`) from PowerShell, never Bash,
on this machine.**

Separately: leftover `dart` / `dartaotruntime` / `flutter_tester` processes from a prior
crashed or interrupted test run cause resource contention that produces a *second*, different
crash on the next attempt (a Dart VM compiler fault, e.g. a CFG dump during regex JIT
compilation, exiting with code 9) — even from PowerShell. Kill those stray processes before
each run.

Prefer running the suite in the **foreground** with a generous timeout (the full suite takes
roughly 70 seconds once the environment is clean) rather than backgrounding it — a backgrounded
`flutter test` run has been observed to die silently with no recoverable output if the host
session restarts mid-run.

The simplest fix: run `scripts/run_tests.ps1` — it kills stray test-runner processes (without
touching the legitimate VS Code Dart-extension services: language server, tooling daemon,
devtools, flutter_tools daemon) and then runs `flutter test --concurrency=1` in the foreground.

If crashes persist even with a clean process list, it's worth checking whether Windows
Defender (or another AV/EDR) has real-time scanning exclusions set up for `C:\flutter`, the
pub cache (`%LOCALAPPDATA%\Pub\Cache`), and this project directory — antivirus hooks
intercepting process/thread creation syscalls are a known cause of exactly this class of
intermittent native crash, though this has not been confirmed as a root cause here (checking
requires admin rights).

## UI conventions (enforced by `test/ui_conventions_test.dart`)

- **Text inputs:** never use a raw `TextField` / `TextFormField` in `lib/`. Use `AppTextField`
  / `AppTextFormField` from `lib/widgets/app_text_field.dart`, so every field shakes when it
  shows an error. Put field errors in the field's `decoration.errorText` (or a validator), and
  bump `shakeTrigger` on each failed submit so a repeated error shakes again. For custom-drawn
  fields, wrap the box in `ShakeOnError`.
- **Fonts:** one typeface app-wide: Roboto, bundled in `assets/fonts/`. Always write
  `fontFamily: AppFonts.family` (`lib/theme/app_fonts.dart`), never a string literal, and
  don't add `google_fonts`.
