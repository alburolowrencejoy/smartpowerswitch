# Web build: blank white screen on first load

**Status:** Diagnosed, not yet fixed — parked per user request on 2026-09-12.

## The question that started this

> "also, can you find the reason when i build the web app, it's just white
> screen? or is it because of the render flex error"

The render-flex-overflow bug (in `building_floor_screen_web.dart`'s room
cards, fixed separately) is **not** the cause. It's a debug-mode layout
assertion on a single widget — it can't blank the whole page, and it's
compiled out of release builds entirely.

## Root cause

Reproduced locally: ran `flutter build web`, served `build/web` with a
static file server, and drove it in a headless browser.

- Checked the page ~8s after load: genuinely blank, nothing rendered.
- Checked again after ~25s: renders correctly (full login screen), no
  console errors.

So the app isn't actually broken — it's just slow to reach first paint, and
`web/index.html` shows nothing (no spinner, no placeholder) during that gap,
so it reads as "just a white screen."

First paint is gated behind a chain of **external CDN fetches** that
`flutter build web` does not bundle locally by default:

- **CanvasKit** (the rendering engine) — fetched fresh from
  `www.gstatic.com/flutter-canvaskit/<engine-revision>/...` instead of the
  `canvaskit/` folder Flutter already copies into `build/web/` alongside
  the rest of the build.
- **Firebase JS SDK**, loaded as four separate CDN requests instead of one
  bundle: `firebase-app.js`, `firebase-auth.js`, `firebase-database.js`,
  `firebase-functions.js`, all from `www.gstatic.com/firebasejs/...`.
- **Google Fonts** (Roboto, Noto Sans Symbols) from `fonts.gstatic.com`.
- A GitHub API call for the in-app update checker
  (`UpdateNotificationService.checkAndNotifyIfNewRelease`), which doesn't
  block rendering but adds to the background network chatter during boot.

On a fast, unrestricted connection this is a brief flash. On a slower or
more restricted connection — e.g. a campus network, which is exactly this
app's deployment target (DNSC Campus Energy Control) — any one of those
`gstatic.com`/`github.com` calls being slow or firewalled can make the
white screen last much longer, or hang indefinitely if the domain is
blocked outright.

## Where this was reproduced

Scratch repro script (headless Edge via `puppeteer-core`, since no
`chromium-cli`/Playwright browser was installed in that session):
served `build/web` on `localhost:8834` and captured the console/network
log plus a screenshot at two wait times (8s vs 25s after load). Full
network trace showed the CanvasKit + Firebase SDK + fonts fetches
finishing only shortly before first paint. That trace/script wasn't kept
in the repo (it lived in the session's temp scratchpad) — rerun the same
way if you need to reproduce again: `flutter build web`, serve
`build/web` statically, load it, and watch the Network tab for
`gstatic.com` and `github.com` requests relative to when the UI appears.

## Candidate fixes (not yet applied)

1. **Self-host CanvasKit** (recommended first step). Point
   `web/index.html` at the `canvaskit/` folder already produced in
   `build/web/` instead of `www.gstatic.com`, e.g. via:
   ```html
   <script>
     window.flutterConfiguration = {
       canvasKitBaseUrl: "/canvaskit/"
     };
   </script>
   ```
   placed before the `flutter_bootstrap.js` script tag. Removes one whole
   external CDN dependency from first paint and keeps working even if
   `gstatic.com` is slow/blocked on the campus network.

2. **Add a loading indicator** in `web/index.html` (plain HTML/CSS,
   rendered before Flutter/JS even starts) — a small spinner or the app
   logo — so the page isn't pure white while CanvasKit/Firebase/fonts load
   in the background. Doesn't reduce load time, just fixes the
   "looks broken" perception.

3. (Not investigated yet, lower priority) Whether the Firebase JS SDK can
   be bundled locally instead of fetched from `gstatic.com` per-module —
   would need checking FlutterFire's web-SDK-loading options.

4. Worth confirming separately: whether the actual campus network this is
   deployed to can reach `www.gstatic.com`, `fonts.gstatic.com`, and
   `api.github.com` at all — if any is blocked outright, the white screen
   won't just be slow, it'll hang.

## Next step when resuming

Start with fix #1 (self-host CanvasKit) since it's the biggest single
external dependency and is a same-file, low-risk change to
`web/index.html`. Rebuild (`flutter build web`) and re-verify with the
same reproduction approach (serve `build/web`, load it, check how quickly
`flt-glass-pane`/`flutter-view` shows up and whether any `gstatic.com`
CanvasKit request still fires).
