# Backup scripts

This repository includes simple scripts to create a timestamped ZIP backup of the project.

Files added
- `scripts/backup.ps1` — PowerShell script for Windows.
- `scripts/backup.sh` — POSIX shell script for Linux/macOS/WSL.

What the scripts do
- Create a `backups/` directory (if missing).
- Produce a ZIP file named `smartpowerswitch-backup-<timestamp>.zip` inside `backups/`.
- Exclude common build and metadata folders (e.g. `build`, `.git`, `.gradle`, `.dart_tool`, `android`, `ios`, `.idea`, `.vscode`).

Usage

Windows (PowerShell):

```powershell
# From repository root
powershell -ExecutionPolicy Bypass -File .\scripts\backup.ps1
# Or run in PowerShell prompt:
.\scripts\backup.ps1
```

Linux / macOS / WSL:

```bash
# Make script executable (only needed once)
chmod +x scripts/backup.sh
# Run
./scripts/backup.sh
```

Notes
- The scripts avoid archiving platform build outputs and VCS metadata by default. Adjust exclusions in the script if you want a different behaviour.
- Generated backups are stored under `backups/` in the repository root; move them to external storage for long-term retention.
