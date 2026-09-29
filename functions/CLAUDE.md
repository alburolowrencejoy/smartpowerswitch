# functions/CLAUDE.md

Node.js Cloud Functions + local admin scripts for the Firebase project
`smartpowerswitch-e90d0` — this is where the actual "Node Firebase
scripts" live (not `scripts/`, which is PowerShell/shell test-runner and
backup utilities — see [`scripts/CLAUDE.md`](../scripts/CLAUDE.md)). This
is `aaron`'s domain.

## Deployed Cloud Functions (per `index.js`'s `exports`)

- `onDeviceKwhChange` — DB-triggered on `devices/{deviceId}/kwh` writes;
  calls `writeHistoryForDevice` (from `history_writer.js`) to fan out into
  `history/{daily,weekly,monthly,yearly}`, only when the device has a
  `building` and `relay === true`.
- `runAutomationScheduler` — scheduled every minute, runs automation
  schedules.
- `watchDavaoLight` / `checkDavaoLightNow` / `verifyAdvisoryText` — from
  `davao_light_watch.js`; see
  [`docs/knowledge/davao-light-rate-function.md`](../docs/knowledge/davao-light-rate-function.md).
- `deleteUser` / `changeUserPassword` — callable functions, gated by a
  shared `assertCanManageUser` authorization check
  (admin-tier unrestricted, `institute_admin` scoped to their own
  institute). See `docs/knowledge/role-model.md` and
  `docs/knowledge/work-history.md` (2026-09-13 entry) for why these exist
  and what they replaced (a database-only "delete" that left the Firebase
  Auth account alive, and a plaintext password field).

## Known live-code discrepancy: `history_writer_fixed.js` is not wired up

`history_writer_fixed.js` contains a `data.source === 'real_iot'` filter
meant to stop mock/test devices from polluting history totals (see
`docs/knowledge/deployment.md` for the incident this fixed). **`index.js`
does not `require` it** — it imports `writeHistoryForDevice` from the
plain `history_writer.js`, which has no such filter. Read
`docs/knowledge/deployment.md`'s "Live-code check" section before assuming
the mock-device-pollution class of bug can't recur; it currently can,
since the live path has no source-based gate at all. Confirm which file is
actually deployed (`firebase functions:log` around an `onDeviceKwhChange`
invocation, or just re-read `index.js`'s `require`) before treating this
as fixed.

## Other scripts here (not Cloud Functions — run manually via `node` or `npm`)

- `cleanup_history.js`, `remove_mock_devices.js` — one-off admin-SDK
  scripts against live data; need `serviceAccountKey.json` (gitignored,
  never commit it) and `npm install firebase-admin` first. Read the
  script's full read/write sequence before running it — these touch real
  device history.
- `davao_light_parse.js` / `davao_light_parse.test.js` — the actual Node
  test file for the rate-parsing logic; run with the project's normal
  Node test runner from `functions/`.

## Local testing

`npm run serve` (= `firebase emulators:start --only functions`) from this
directory. Note the emulator is **not** configured for the Database
product in the root `firebase.json` (no `emulators` block) — see
`.claude/skills/firebase-rules-check/SKILL.md` §5 if a task needs
`database.rules.json` + a Cloud Function tested together.

## Deploying

`firebase deploy --only functions` (or a specific function:
`firebase deploy --only functions:onDeviceKwhChange`). Per `aaron`'s
standing rule, don't deploy without the user's explicit go-ahead — this
is live production infrastructure.
