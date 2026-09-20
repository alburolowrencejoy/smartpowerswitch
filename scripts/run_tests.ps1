# Runs the Flutter test suite reliably on this Windows machine.
#
# Why this exists: running `flutter test` through Git Bash reliably crashes the Dart VM
# (os_thread.cc: "Could not start thread DartWorker: 22"). Even from PowerShell, leftover
# dart/dartaotruntime/flutter_tester processes from a prior crashed or interrupted run cause
# a second, different crash (a Dart VM compiler fault) via resource contention. See
# CLAUDE.md's "Windows test-runner gotcha" section for the full writeup.
#
# Usage: powershell -File scripts/run_tests.ps1 [any extra `flutter test` args]

$strayNames = 'dart', 'dartaotruntime', 'flutter_tester'

Get-CimInstance Win32_Process |
    Where-Object {
        ($strayNames -contains $_.Name.Replace('.exe', '')) -and
        ($_.CommandLine -notmatch 'language-server|tooling-daemon|devtools|flutter_tools.*daemon')
    } |
    ForEach-Object {
        Write-Host "Stopping stray process $($_.Name) (PID $($_.ProcessId))"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

Start-Sleep -Seconds 1

flutter test --concurrency=1 @args
