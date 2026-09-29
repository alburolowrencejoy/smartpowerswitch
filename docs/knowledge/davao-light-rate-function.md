# Davao Light electricity rate — automated fetch

Source doc: [`CLOUD_FUNCTION_DAVAO_LIGHT_RATES.md`](../../CLOUD_FUNCTION_DAVAO_LIGHT_RATES.md).

**Important — the source doc describes an earlier implementation that has
since been renamed/restructured.** The doc names the function
`fetchDavaoLightRates` in `functions/fetch_davao_light_rates.js`. As of the
current `functions/index.js`, the live exports are:

```js
const davaoLight = require('./davao_light_watch');
exports.watchDavaoLight = davaoLight.watchDavaoLight;
exports.checkDavaoLightNow = davaoLight.checkDavaoLightNow;
exports.verifyAdvisoryText = davaoLight.verifyAdvisoryText;
```

i.e. the real files are `functions/davao_light_watch.js` (the Cloud
Function logic) and `functions/davao_light_parse.js` (+
`davao_light_parse.test.js`, an actual Node test file for the parsing
logic) — there is no `fetch_davao_light_rates.js` in the current tree.
Treat the mechanism described below as directionally correct (still
scrapes Davao Light's FAQ page on a schedule, still writes the same RTDB
paths) but verify current behavior against `davao_light_watch.js` and
`davao_light_parse.js` before changing it — don't edit based on the old
filename.

## What it does (per the source doc's design — re-verify against
`davao_light_watch.js`)

- Scheduled fetch from `https://www.davaolight.com/customer-services/faq`,
  originally every 6 hours (`0 */6 * * *`).
- Parses a rate via, in priority order: `PHP X.XXXX`, `$X.XXXX`,
  `rate X.XXXX`, `kWh X.XXXX` patterns.
- Compares against current `settings/electricityRate`; a change is only
  registered if the difference is `> 0.0001` (avoids rounding-noise false
  positives).
- On a real change: writes `notifications/{id}` (type `rate_change`),
  `rate_changes/{timestamp}` (audit entry), updates
  `settings/electricityRate`, and always updates
  `settings/rateLastFetched` regardless of whether a change was detected.
- 15s HTTP timeout; network/parse errors are logged and swallowed rather
  than crashing the function.

## Consumers

- `functions/history_writer.js` reads `settings/electricityRate` for cost
  calculation (see [`pzem-calibration.md`](pzem-calibration.md)).
- The Flutter app's `DavaoLightRateMonitor` service can also poll
  independently for real-time monitoring in-app; the Cloud Function is the
  periodic/background path, not a replacement for it.

## Operational notes (from the source doc, still generally applicable)

- Deploy: `cd functions && firebase deploy --only functions`.
- Logs: `firebase functions:log --follow`, filter for the function's log
  prefix.
- Local test: `firebase emulators:start --only functions` (via
  `npm run serve` in `functions/`), or the Node test file
  `davao_light_parse.test.js` for the parsing logic specifically.
- If Davao Light's site is redesigned, the HTML parsing patterns are the
  first thing to check.
