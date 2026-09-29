# scripts/CLAUDE.md

This folder only contains three PowerShell/POSIX-shell utility scripts —
**not** the Node.js Firebase automation scripts (history writer, cleanup,
Davao Light rate fetch, etc.). Those live under [`../functions/`](../functions/)
— see [`functions/CLAUDE.md`](../functions/CLAUDE.md). If you came here
looking for `history_writer.js` or similar, you want that folder instead.

## What's actually here

- `run_tests.ps1` — kills stray `dart`/`dartaotruntime`/`flutter_tester`
  processes (without touching VS Code's Dart-extension services), then
  runs `flutter test --concurrency=1`. Use the `run-tests` skill
  (`.claude/skills/run-tests/SKILL.md`) rather than reasoning about this
  from scratch — it has the full troubleshooting flow. Must be run from
  PowerShell, never Git Bash, per the root [`CLAUDE.md`](../CLAUDE.md).
- `backup.ps1` / `backup.sh` — zip the whole repo (minus build/VCS noise)
  into `backups/`. See
  [`docs/knowledge/backup.md`](../docs/knowledge/backup.md). This is a
  whole-repo code backup, unrelated to backing up live Firebase RTDB data
  (which is a `firebase database:get` export, documented in
  `docs/knowledge/deployment.md`).

## If asked to add a script here

Confirm first whether it actually belongs in `scripts/` (a local
dev/ops utility, Windows- or shell-oriented) or in `functions/` (anything
that's a Node.js script meant to run against Firebase — Admin SDK,
`firebase-functions`, deployed or run via `node` against live/emulated
data). Don't add a Node.js Firebase script here just because the name
"scripts" suggests it — `functions/` is where those live and where
`aaron` looks for them.
