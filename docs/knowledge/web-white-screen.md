# Web build: blank white screen on first load

Source doc: [`WEB_WHITE_SCREEN_ISSUE.md`](../../WEB_WHITE_SCREEN_ISSUE.md).
**Status: diagnosed, not fixed** — parked per user request. Read this
before assuming a "blank web app" report is a new bug; it's most likely
this known, understood issue.

## Root cause

Not a render bug (the earlier suspicion, a `RenderFlex` overflow in
`building_floor_screen_web.dart`'s room cards, was ruled out — that's a
debug-only assertion, compiled out of release, and can't blank the whole
page). The actual cause: first paint is gated behind several **external
CDN fetches** that `flutter build web` doesn't bundle locally by default:

- **CanvasKit** — fetched from `www.gstatic.com/flutter-canvaskit/...`
  instead of the `canvaskit/` folder Flutter already copies into
  `build/web/`.
- **Firebase JS SDK** — four separate CDN requests
  (`firebase-{app,auth,database,functions}.js`) from
  `www.gstatic.com/firebasejs/...`.
- **Google Fonts** (Roboto, Noto Sans Symbols) from `fonts.gstatic.com`.
- A non-blocking GitHub API call for the in-app update checker
  (`UpdateNotificationService.checkAndNotifyIfNewRelease`).

On a fast connection this is a brief flash; on the app's actual deployment
target (a campus network) any one of those domains being slow or
firewalled can stretch the white screen or hang it indefinitely.

## Candidate fixes (none applied yet)

1. **Self-host CanvasKit** (recommended first step, low risk, one file):
   in `web/index.html`, before the `flutter_bootstrap.js` script tag:
   ```html
   <script>
     window.flutterConfiguration = { canvasKitBaseUrl: "/canvaskit/" };
   </script>
   ```
2. **Add a loading indicator** in `web/index.html` (plain HTML/CSS, shows
   before Flutter/JS starts) — doesn't reduce load time, fixes the "looks
   broken" perception.
3. Not investigated: whether FlutterFire's web SDK can be bundled locally
   instead of per-module CDN fetches.
4. Not confirmed: whether the actual campus deployment network can reach
   `www.gstatic.com`, `fonts.gstatic.com`, `api.github.com` at all — if
   one is blocked outright, this isn't just slow, it hangs.

## How it was reproduced (repeat this, not a saved script)

`flutter build web`, serve `build/web` statically (e.g.
`python -m http.server` from that directory, or the `webapp-testing`
skill's `scripts/with_server.py`), load it in a browser, and watch the
Network tab for `gstatic.com`/`github.com` requests relative to when
`flt-glass-pane`/`flutter-view` appears. See
[`.claude/skills/webapp-testing/NOTES.md`](../../.claude/skills/webapp-testing/NOTES.md)
for a ready-made way to drive this headlessly.

## If picked back up

Start with fix #1, rebuild, re-verify with the same reproduction steps.
This is `rhose`'s domain (`web/index.html`, Flutter Web build config).
