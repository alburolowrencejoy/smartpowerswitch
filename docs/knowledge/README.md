# docs/knowledge — index

Concise, agent-oriented distillations of the root-level project docs, kept
short enough to load into an agent's context without crowding it out. Each
file links back to its source doc(s) in the repo root, which remain the
canonical, fuller-detail version — **when the two disagree, the source doc
and (more importantly) the actual code win**; these files are a reading
aid, not a replacement.

These files describe the current state of a system where possible, and are
cross-checked against the real code (`database.rules.json`,
`functions/index.js`, `lib/screens/**`, `firebase.json`) as of 2026-09-29,
not just the original planning docs. Several call out places where a
planning doc has drifted from what actually shipped — read those callouts,
they're usually the most important part.

| File | Distilled from | Use when |
|---|---|---|
| [`role-model.md`](role-model.md) | `INSTITUTE_ROLE_MODEL.md`, `ROLE_HIERARCHY_PLAN.md` | Touching `database.rules.json`, `users/{uid}/role|institute`, or any role/permission check. Has the current list of unfixed security gaps. |
| [`platform-ui.md`](platform-ui.md) | `PLATFORM_UI.md` | Working out whether something is `don`'s (mobile), `rhose`'s (web/desktop), or shared — has the real `lib/screens/{mobile,web,shared}` layout and the `dashboard_page.dart` breakpoint. |
| [`pzem-calibration.md`](pzem-calibration.md) | `PZEM_CALIBRATION_POINTS.md` | Anything touching sensor readings, validation ranges, rounding, or cost calculation. |
| [`davao-light-rate-function.md`](davao-light-rate-function.md) | `CLOUD_FUNCTION_DAVAO_LIGHT_RATES.md` | Touching the electricity-rate auto-fetch Cloud Function — note the source doc's filenames are stale, this file has the current ones. |
| [`deployment.md`](deployment.md) | `DEPLOYMENT_GUIDE.md` | Touching `functions/history_writer.js`/history aggregation — this is the "mock device data polluted totals" incident writeup and the fix pattern to reuse if it recurs. |
| [`backup.md`](backup.md) | `BACKUP_README.md` | Someone asks for "a backup" — clarifies whole-repo ZIP backup (`scripts/backup.ps1`/`.sh`) vs. RTDB data backup (covered in `deployment.md`), which are easy to conflate. |
| [`web-white-screen.md`](web-white-screen.md) | `WEB_WHITE_SCREEN_ISSUE.md` | A "web app is blank/broken" report — likely this known, diagnosed-but-unfixed slow-first-paint issue, not a new bug. |
| [`work-history.md`](work-history.md) | `WORK_SUMMARY.md`, `WORK_SUMMARY_2026-09-03.md`, `WORK_SUMMARY_2026-09-09.md`, `WORK_SUMMARY_2026-09-13.md` | Wanting the "how did we get here" chronology, or checking whether a specific gap/bug was already found and left unfixed on purpose. |

## Skills that pair with this knowledge base

- `.claude/skills/run-tests/` — how to actually run `flutter test` on this
  Windows machine without hitting the Git-Bash/stray-process crashes
  documented in the root `CLAUDE.md`.
- `.claude/skills/firebase-rules-check/` — a review checklist for
  `database.rules.json` changes, grounded in `role-model.md`'s gap list
  above.
- `.claude/skills/webapp-testing/` — Playwright-based web app testing,
  downloaded from `anthropics/skills`; see its `NOTES.md` for how to point
  it at this repo's `flutter build web` output.

## Maintaining this index

When a root doc listed above is substantively updated, or a gap noted here
gets fixed, update the matching file here too — these are meant to stay
close to current, not frozen at 2026-09-29. If a new root-level doc shows
up that's genuinely reference material (not a one-off session log), add a
distilled entry here and a row above.
