# Repository backup scripts

Source doc: [`BACKUP_README.md`](../../BACKUP_README.md).

`scripts/backup.ps1` (Windows/PowerShell) and `scripts/backup.sh`
(Linux/macOS/WSL) each zip the whole repo into
`backups/smartpowerswitch-backup-<timestamp>.zip`, excluding build/VCS
noise (`build`, `.git`, `.gradle`, `.dart_tool`, `android`, `ios`,
`.idea`, `.vscode`).

```powershell
# From repo root, Windows
powershell -ExecutionPolicy Bypass -File .\scripts\backup.ps1
```

```bash
# Linux/macOS/WSL
chmod +x scripts/backup.sh   # once
./scripts/backup.sh
```

This is a **whole-repo code backup**, unrelated to the Firebase RTDB data
backup/export described in [`deployment.md`](deployment.md) (which backs
up live `history/*` data before a migration, via `firebase database:get`
or a Console export) — don't conflate the two when someone asks for "a
backup." Generated ZIPs land in `backups/`; move them to external storage
for real long-term retention, the script doesn't do that itself.
