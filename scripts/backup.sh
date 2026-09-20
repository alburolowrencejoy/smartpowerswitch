#!/usr/bin/env bash
set -euo pipefail
OUTDIR="backups"
mkdir -p "$OUTDIR"
TS=$(date +%Y%m%d%H%M%S)
ZIP="$OUTDIR/smartpowerswitch-backup-$TS.zip"

# Exclude common folders that typically shouldn't be archived
zip -r "$ZIP" . -x "build/*" "android/*" "ios/*" ".git/*" ".gradle/*" ".dart_tool/*" ".idea/*" ".vscode/*" "build/**" "*/gradle/*"

echo "Backup created: $ZIP"
