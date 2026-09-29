# Provenance and project-specific notes

This skill (`SKILL.md`, `scripts/with_server.py`, `examples/*.py`,
`LICENSE.txt`) was downloaded verbatim from
[anthropics/skills](https://github.com/anthropics/skills), folder
`skills/webapp-testing`, at commit `3337550` (2026-09-29). Nothing in those
files was edited — this `NOTES.md` is the only addition, kept separate so
the upstream skill stays a clean, diffable copy for future updates.

## Using it against this repo's web build

The skill is generic Playwright/Python tooling for any local web app; it
has no built-in awareness that this repo is a Flutter web build. Two
adjustments to make when applying it here:

- **Build first.** There's no `npm run dev`. Produce static output with
  `flutter build web --release` (from PowerShell, per the root
  `CLAUDE.md` — Flutter commands should not run through Git Bash on this
  machine), then serve `build/web` with any static file server (e.g.
  `python -m http.server` from that directory) and point
  `scripts/with_server.py --server "python -m http.server 8834" --port 8834`
  at it, or launch/point Playwright directly at an already-running server.
- **Expect a slow first paint.** Per
  [`docs/knowledge/web-white-screen.md`](../../../docs/knowledge/web-white-screen.md)
  (source: root `WEB_WHITE_SCREEN_ISSUE.md`), this app's release web build
  can take ~20+ seconds to first paint while CanvasKit/Firebase JS
  SDK/fonts load from `gstatic.com`. Don't treat a blank page a few
  seconds after `page.goto()` as a failure — use
  `page.wait_for_load_state('networkidle')` and, if still blank, wait
  longer or check the Network tab for stalled `gstatic.com`/`github.com`
  requests before concluding the app is broken.
