param(
  [string]$OutDir = ".\backups"
)

$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$zipName = "smartpowerswitch-backup-$timestamp.zip"
$newPath = Join-Path -Path $OutDir -ChildPath $zipName

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# Exclude common build and metadata folders
$exclusionPattern = '\\(build|\.git|\.gradle|\.dart_tool|android|ios|\.idea|\.vscode)\\'
$files = Get-ChildItem -Recurse -File | Where-Object { $_.FullName -notmatch $exclusionPattern }

if ($files.Count -eq 0) {
  Write-Host "No files found to archive."
  exit 1
}

Compress-Archive -LiteralPath ($files | ForEach-Object FullName) -DestinationPath $newPath -Force
Write-Host "Backup created: $newPath"
