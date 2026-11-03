# Forecasting (ARIMA / XGBoost / GRU / LSTM)

Source: the research notebook `energy_forecasting_comparison.ipynb` (kept
outside the repo, in the owner's Downloads folder; it was run on the Kaggle
ASHRAE dataset, building 708) and `tools/forecast_comparison.py`.

## What runs where

- **Nothing is trained in the app.** The old in-app Dart ARIMA
  (`lib/services/forecast_models.dart`) and the old job's XGBoost / second
  LSTM / TFLite export were removed on 2026-11-03 so that each algorithm
  exists once.
- `.github/workflows/train.yml` runs `tools/forecast_comparison.py` daily
  at 02:00 UTC (10:00 Philippine time). It reads
  `energy_summaries/hourly` with the admin SDK and writes
  `history/predictions/comparison/{campus | institute code}` (one entry per
  institute in the hourly data, `UNASSIGNED` skipped). Clients can't write
  there (`history` is `.write: false`).
- `lib/services/forecast_comparison.dart` parses it;
  `lib/screens/web/web_forecast_cards.dart` (web Analytics) and the
  Forecast tab of `lib/screens/mobile/history_screen.dart` show it.

## Method (must match the notebook)

ARIMA (`pmdarima.auto_arima`, non-seasonal), XGBoost (lags 1/2/3/7,
7-day mean, day of week / weekend / month) and GRU (64→32, 7-day window)
are copied from notebook cells 3–9 **unchanged** except for one step:
chronological 80/20 split, seed 42, day-ahead ("rolling") forecast,
sklearn metrics, rank by RMSE. Don't tune these without the owner's
say-so — the point is that the system runs the documented method.

**The one deviation (owner-approved 2026-11-03): cleaning.** The notebook
treats a zero hour as "meter offline" and rebuilds any day with < 20
hours from its neighbours — right for ASHRAE meters, wrong here: the
rollup writes no hourly entry for an hour with no usage, and the real
load (one 14 W device on a relay schedule, 18:00–06:00) is off 12 h a
day, so every day was rejected. Now a missing hour counts as 0 kWh and
only a day with **no readings at all** (board offline) is interpolated. The LSTM is the earlier job's model (14-day window, 50
epochs), scored by the same split and metrics.

"Tomorrow" is the same rolling step run once more past the last full day
(today's unfinished day is never used). A series needs 60+ days.

## Gotchas

- Because a missing hour is 0 kWh, a board that drops off Wi-Fi for part
  of a day under-counts that day rather than being flagged. Only whole
  offline days are caught (published as `incomplete_days`).
- Hourly summaries are pruned after a year (`functions/energy_maintenance.js`),
  so the comparison never sees more than ~365 days.
- Tests: `python -m pytest tools/test_forecast_comparison.py` (fast) and
  `-m slow` (trains the real models); `test/forecast_comparison_test.dart`
  for the Dart side.
