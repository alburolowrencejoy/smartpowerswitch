"""Daily-kWh forecast comparison on the live RTDB data: ARIMA vs XGBoost vs
GRU vs LSTM.

ARIMA, XGBoost and GRU are ported unchanged from the research notebook
`energy_forecasting_comparison.ipynb` (cells 3-9): the same cleaning, the
same chronological 80/20 split, the same model settings and seed, the same
day-ahead ("rolling") forecast and the same metrics. The only difference is
the data source: instead of the Kaggle ASHRAE `train.csv`, each series is
read from `energy_summaries/hourly` (written by the rollupEnergy Cloud
Function, Philippine time). The LSTM is the one this job already trained,
with its own settings, scored by the same split and metrics so all four can
be ranked together.

One comparison is made for the campus total and one per institute
(`energy_summaries/hourly/{hour}/buildings/{code}`; the UNASSIGNED bucket is
skipped), and all of them are written to `history/predictions/comparison`.

On top of the notebook's day-ahead comparison, each trained model also
forecasts the next 7 and 30 days (HORIZONS) by feeding its own predictions
back in, one day at a time. Each horizon is scored the same way on the last
days of the test period (all of it when the horizon is longer): forecast
from the day before, without seeing any of those days.

Run daily by .github/workflows/train.yml. Locally:
    python tools/forecast_comparison.py --dry-run          # read RTDB, write nothing
    python tools/forecast_comparison.py --hourly-json FILE # an exported energy_summaries/hourly
"""
import argparse
import copy
import json
import os
import random
import re
import warnings
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")

# ---------------- CONFIG (from the notebook) ----------------
OUTPUT_DIR     = Path("outputs")    # CSV tables are saved here
SEED           = 42
TEST_FRACTION  = 0.20
LOOKBACK       = 7              # GRU input window (days)
ARIMA_SEASONAL = False          # spec = plain ARIMA(p,d,q). Set True for SARIMA with weekly season (m=7)
FORECAST_MODE  = "rolling"      # "rolling" = day-ahead with actual past values | "recursive" = multi-step blind forecast
XGB_CALENDAR   = True           # add day-of-week / weekend / month features to XGBoost (known in advance, no leakage)
assert FORECAST_MODE in ("rolling", "recursive")
# ------------------------------------------------------------
# The notebook's KBTU_TO_KWH conversion is left out: it only applies to
# ASHRAE site 0, and the rollup already records kWh.

# The LSTM's own settings (unchanged from the previous training job).
LSTM_WINDOW    = 14
LSTM_EPOCHS    = 50

# Below this many days the 80/20 split leaves too little to train on.
MIN_DAYS       = 60

# Multi-day forecasts (days ahead), published as horizons/d7 and horizons/d30.
HORIZONS       = [7, 30]
UNASSIGNED     = "UNASSIGNED"    # functions/energy_math.js
PH_TZ          = timezone(timedelta(hours=8))
COMPARISON_REF = "history/predictions/comparison"
MODEL_KEYS     = ["arima", "xgboost", "gru", "lstm"]
MODEL_NAMES    = {"arima": "ARIMA", "xgboost": "XGBoost", "gru": "GRU", "lstm": "LSTM"}

_HOUR_KEY = re.compile(r"^(\d{4}-\d{2}-\d{2})-(\d{2})$")


def set_seeds(seed=SEED):
    os.environ["PYTHONHASHSEED"] = str(seed)
    random.seed(seed)
    np.random.seed(seed)


# ── Data source: energy_summaries/hourly ──────────────────────────────────

def series_keys(hourly: dict) -> list:
    """'campus' plus every institute code that appears in the hourly data."""
    codes = set()
    for node in (hourly or {}).values():
        if isinstance(node, dict) and isinstance(node.get("buildings"), dict):
            codes.update(node["buildings"].keys())
    codes.discard(UNASSIGNED)
    return ["campus"] + sorted(codes)


def hourly_series(hourly: dict, key: str, before_day: str = None) -> pd.Series:
    """Hourly kWh of one series ('campus' or an institute code), indexed by
    Philippine local time. Hours with no reading are simply absent; the
    notebook's cleaning step turns them into gaps. Hours on or after
    [before_day] (YYYY-MM-DD) are dropped, so today's unfinished day is
    never treated as a full one."""
    rows = {}
    for k, node in (hourly or {}).items():
        m = _HOUR_KEY.match(str(k))
        if not m or not isinstance(node, dict):
            continue
        if before_day and m.group(1) >= before_day:
            continue
        leaf = node.get("campus") if key == "campus" else (node.get("buildings") or {}).get(key)
        kwh = leaf.get("kwh") if isinstance(leaf, dict) else None
        if isinstance(kwh, (int, float)):
            rows[pd.Timestamp(f"{m.group(1)} {m.group(2)}:00")] = float(kwh)
    return pd.Series(rows, dtype="float64").sort_index()


# ── Notebook cell 3: clean, resample to daily kWh, chronological 80/20 split ──

def clean_to_daily(readings: pd.Series):
    """- Hourly -> daily total kWh; a missing hour counts as 0 kWh.
    - Days with no readings at all (board offline all day) are filled by interpolation of the
      daily series.
    The one deviation from the notebook: it treats a zero hour as "meter offline" and a day with
    fewer than 20 hours as unreliable, which fits the ASHRAE meters it was written for. Here the
    rollup writes no hourly entry for an hour with no usage, and a relay-scheduled load (e.g.
    18:00-06:00) is off for half of every day, so that rule rejected every one of its days.
    Returns (daily series, number of missing days interpolated)."""
    hourly = readings.astype("float64").dropna()
    days = pd.date_range(hourly.index.min().normalize(), hourly.index.max().normalize(), freq="D")
    hours_per_day = hourly.resample("D").count().reindex(days, fill_value=0)
    daily = hourly.resample("D").sum().reindex(days)
    daily[hours_per_day == 0] = np.nan                         # board offline the whole day
    n_bad = int(daily.isna().sum())
    daily = daily.interpolate(method="time").bfill().ffill()
    daily.name = "kwh"
    return daily, n_bad


def split_train_test(daily: pd.Series):
    split = int(len(daily) * (1 - TEST_FRACTION))
    return daily.iloc[:split], daily.iloc[split:]


# ── Notebook cell 4: evaluation helper (used by every model) ───────────────

def evaluate(y_true, y_pred, name):
    from sklearn.metrics import (mean_absolute_error, mean_squared_error,
                                 mean_absolute_percentage_error, r2_score)
    y_true, y_pred = np.asarray(y_true, float), np.asarray(y_pred, float)
    mse = mean_squared_error(y_true, y_pred)
    return {
        "Model": name,
        "MAE":  mean_absolute_error(y_true, y_pred),
        "MSE":  mse,
        "RMSE": np.sqrt(mse),
        "MAPE (%)": mean_absolute_percentage_error(y_true, y_pred) * 100,
        "R2":   r2_score(y_true, y_pred),
    }


# ── Notebook cell 5: Model 1 — ARIMA (pmdarima.auto_arima) ────────────────

def run_arima(train, test):
    """Stepwise search over (p, d, q) by AIC on the training set only; the
    selected order is then kept fixed. Returns (test predictions, next-day
    prediction, info, forecaster).

    Every runner returns the same four things. The forecaster takes the
    real daily history up to some day (always starting with [train]) and a
    number of days, and predicts those days one at a time, feeding each
    prediction back in."""
    import pmdarima as pm
    set_seeds()

    arima = pm.auto_arima(
        train,
        start_p=0, start_q=0, max_p=7, max_q=7, max_d=2,
        seasonal=ARIMA_SEASONAL, m=7 if ARIMA_SEASONAL else 1,
        stepwise=True, information_criterion="aic",
        suppress_warnings=True, error_action="ignore", trace=False,
        random_state=SEED,
    )
    print("  ARIMA selected order:", arima.order)

    if FORECAST_MODE == "rolling":
        arima_rolling = copy.deepcopy(arima)                               # same fitted model, kept separate
        preds = []
        for actual in test.values:
            preds.append(float(np.asarray(arima_rolling.predict(n_periods=1))[0]))
            arima_rolling.update([actual])                                  # reveal today's actual value
        arima_pred = pd.Series(preds, index=test.index)
        next_day = float(np.asarray(arima_rolling.predict(n_periods=1))[0])
    else:
        ahead = np.asarray(arima.predict(n_periods=len(test) + 1))
        arima_pred = pd.Series(ahead[:-1], index=test.index)
        next_day = float(ahead[-1])

    def forecast(history, steps):
        model = copy.deepcopy(arima)
        seen = history.iloc[len(train):]                                    # real days after training
        if len(seen):
            model.update(seen.values)
        return [float(v) for v in np.asarray(model.predict(n_periods=steps))]

    return arima_pred, next_day, {"order": [int(v) for v in arima.order]}, forecast


# ── Notebook cell 6: Model 2 — XGBoost (lag features + iterative forecast) ──

LAGS = [1, 2, 3, 7]
CAL_FEATURES = ["day_of_week", "is_weekend", "month"] if XGB_CALENDAR else []
FEATURES = [f"lag_{l}" for l in LAGS] + ["roll_mean_7"] + CAL_FEATURES


def calendar_row(ts):
    return {"day_of_week": ts.day_of_week, "is_weekend": int(ts.day_of_week >= 5), "month": ts.month}


def make_features(s: pd.Series) -> pd.DataFrame:
    df = pd.DataFrame({"y": s})
    for l in LAGS:
        df[f"lag_{l}"] = s.shift(l)
    df["roll_mean_7"] = s.shift(1).rolling(7).mean()
    if XGB_CALENDAR:
        df["day_of_week"] = s.index.day_of_week
        df["is_weekend"] = (s.index.day_of_week >= 5).astype(int)
        df["month"] = s.index.month
    return df


def run_xgboost(train, test):
    """Features for day t: lag_1, lag_2, lag_3, lag_7 and roll_mean_7 (mean of
    days t-7 … t-1), plus day_of_week / is_weekend / month. Forecasting is
    iterative, one day at a time."""
    from xgboost import XGBRegressor
    set_seeds()

    train_feat = make_features(train).dropna()
    X_train, y_train = train_feat[FEATURES], train_feat["y"]

    xgb = XGBRegressor(
        n_estimators=500, learning_rate=0.03, max_depth=4,
        subsample=0.9, colsample_bytree=0.9,
        objective="reg:squarederror", random_state=SEED, n_jobs=1,  # n_jobs=1 => bit-for-bit reproducible
    )
    xgb.fit(X_train, y_train)

    def predict_day(history, ts):
        row = {f"lag_{l}": history.iloc[-l] for l in LAGS}
        row["roll_mean_7"] = history.iloc[-7:].mean()
        if XGB_CALENDAR:
            row.update(calendar_row(ts))
        return float(xgb.predict(pd.DataFrame([row])[FEATURES])[0])

    # Iterative forecast, one test day at a time
    history = train.copy()
    xgb_preds = []
    for ts in test.index:
        yhat = predict_day(history, ts)
        xgb_preds.append(yhat)
        # rolling: reveal today's actual value | recursive: feed the prediction back in
        history.loc[ts] = test.loc[ts] if FORECAST_MODE == "rolling" else yhat

    xgb_pred = pd.Series(xgb_preds, index=test.index)
    next_day = predict_day(history, test.index[-1] + pd.Timedelta(days=1))
    importance = pd.Series(xgb.feature_importances_, index=FEATURES).sort_values(ascending=False)

    def forecast(history, steps):
        h, out = history.copy(), []
        for _ in range(steps):
            ts = h.index[-1] + pd.Timedelta(days=1)
            out.append(predict_day(h, ts))
            h.loc[ts] = out[-1]
        return out

    return (xgb_pred, next_day,
            {"feature_importance": {k: float(v) for k, v in importance.items()}}, forecast)


# ── Notebook cell 7: Model 3 — GRU (Keras) ────────────────────────────────

def make_windows(arr, lookback):
    X = np.array([arr[i:i + lookback] for i in range(len(arr) - lookback)])
    y = arr[lookback:]
    return X[..., np.newaxis], y


def run_gru(train, test):
    """MinMaxScaler fitted on train only; previous 7 days -> next day; the
    last 15 % of training windows validate, EarlyStopping restores the best
    weights."""
    import tensorflow as tf
    from tensorflow import keras
    from tensorflow.keras import layers
    from sklearn.preprocessing import MinMaxScaler

    set_seeds()
    tf.keras.utils.set_random_seed(SEED)
    try:
        tf.config.experimental.enable_op_determinism()
    except Exception:
        pass

    scaler = MinMaxScaler()
    train_scaled = scaler.fit_transform(train.values.reshape(-1, 1)).ravel()

    X_all, y_all = make_windows(train_scaled, LOOKBACK)
    n_val = max(1, int(len(X_all) * 0.15))
    X_tr, y_tr = X_all[:-n_val], y_all[:-n_val]
    X_val, y_val = X_all[-n_val:], y_all[-n_val:]

    gru = keras.Sequential([
        layers.Input(shape=(LOOKBACK, 1)),
        layers.GRU(64, return_sequences=True),
        layers.Dropout(0.2, seed=SEED),
        layers.GRU(32),
        layers.Dense(16, activation="relu"),
        layers.Dense(1),
    ])
    gru.compile(optimizer=keras.optimizers.Adam(learning_rate=1e-3), loss="mse")

    early = keras.callbacks.EarlyStopping(monitor="val_loss", patience=20, restore_best_weights=True)
    hist = gru.fit(X_tr, y_tr, validation_data=(X_val, y_val),
                   epochs=300, batch_size=16, shuffle=True, callbacks=[early], verbose=0)
    print(f"  GRU stopped after {len(hist.history['loss'])} epochs; "
          f"best val_loss = {min(hist.history['val_loss']):.5f}")

    # Iterative forecast, one test day at a time
    test_scaled = scaler.transform(test.values.reshape(-1, 1)).ravel()   # scaler stays fitted on train only
    window = list(train_scaled[-LOOKBACK:])
    gru_scaled = []
    for i in range(len(test)):
        x = np.array(window[-LOOKBACK:]).reshape(1, LOOKBACK, 1)
        yhat = float(gru.predict(x, verbose=0)[0, 0])
        gru_scaled.append(yhat)
        # rolling: reveal today's actual value | recursive: feed the prediction back in
        window.append(test_scaled[i] if FORECAST_MODE == "rolling" else yhat)
    next_scaled = float(gru.predict(np.array(window[-LOOKBACK:]).reshape(1, LOOKBACK, 1), verbose=0)[0, 0])

    inverse = lambda v: scaler.inverse_transform(np.array(v).reshape(-1, 1)).ravel()
    gru_pred = pd.Series(inverse(gru_scaled), index=test.index)

    def forecast(history, steps):
        w = list(scaler.transform(history.values.reshape(-1, 1)).ravel()[-LOOKBACK:])
        out = []
        for _ in range(steps):
            out.append(float(gru.predict(np.array(w[-LOOKBACK:]).reshape(1, LOOKBACK, 1), verbose=0)[0, 0]))
            w.append(out[-1])
        return [float(v) for v in inverse(out)]

    return (gru_pred, float(inverse([next_scaled])[0]),
            {"epochs": len(hist.history["loss"])}, forecast)


# ── LSTM (the previous training job's model, unchanged) ───────────────────

def make_sequences(series, window=LSTM_WINDOW):
    X, y = [], []
    for i in range(len(series) - window):
        X.append(series[i:i+window])
        y.append(series[i+window])
    return np.array(X), np.array(y)


def build_lstm(window):
    from tensorflow.keras.models import Sequential
    from tensorflow.keras.layers import LSTM, Dense
    model = Sequential([
        LSTM(64, input_shape=(window, 1), activation='tanh'),
        Dense(32, activation='relu'),
        Dense(1)
    ])
    model.compile(optimizer='adam', loss='mse')
    return model


def run_lstm(train, test):
    """Normalised by the training mean/std, 14-day window, up to 50 epochs
    with EarlyStopping on the training loss; negative forecasts become 0.
    Scored like the notebook models: one test day at a time."""
    import tensorflow as tf
    from tensorflow.keras.callbacks import EarlyStopping
    set_seeds()
    tf.keras.utils.set_random_seed(SEED)

    series = train.values.astype('float32')
    mean = series.mean()
    std = series.std() if series.std() > 0 else 1.0
    norm = (series - mean) / std
    X, y = make_sequences(norm, LSTM_WINDOW)
    X = X.reshape((X.shape[0], X.shape[1], 1))
    model = build_lstm(LSTM_WINDOW)
    es = EarlyStopping(monitor='loss', patience=6, restore_best_weights=True)
    model.fit(X, y, epochs=LSTM_EPOCHS, batch_size=8, callbacks=[es], verbose=0)

    test_norm = (test.values.astype('float32') - mean) / std
    window = norm[-LSTM_WINDOW:].tolist()
    preds = []
    for i in range(len(test)):
        p = float(model.predict(np.array(window[-LSTM_WINDOW:]).reshape((1, LSTM_WINDOW, 1)), verbose=0)[0, 0])
        preds.append(p)
        window.append(test_norm[i] if FORECAST_MODE == "rolling" else p)
    nxt = float(model.predict(np.array(window[-LSTM_WINDOW:]).reshape((1, LSTM_WINDOW, 1)), verbose=0)[0, 0])

    to_kwh = lambda v: np.maximum(np.asarray(v) * std + mean, 0.0)

    def forecast(history, steps):
        w = ((history.values.astype('float32') - mean) / std)[-LSTM_WINDOW:].tolist()
        out = []
        for _ in range(steps):
            out.append(float(model.predict(np.array(w[-LSTM_WINDOW:]).reshape((1, LSTM_WINDOW, 1)), verbose=0)[0, 0]))
            w.append(out[-1])
        return [float(v) for v in to_kwh(out)]

    return pd.Series(to_kwh(preds), index=test.index), float(to_kwh([nxt])[0]), {}, forecast


RUNNERS = {"arima": run_arima, "xgboost": run_xgboost, "gru": run_gru, "lstm": run_lstm}


# ── Notebook cell 8: comparison table (sorted by lowest RMSE) ─────────────

def _num(v):
    """RTDB can't store NaN or infinity."""
    v = float(v)
    return v if np.isfinite(v) else None


def compare_series(key: str, readings: pd.Series, generated_at: int, runners=None) -> dict:
    """Runs every model on one series; returns what is written to
    history/predictions/comparison/{key}."""
    runners = runners or RUNNERS
    base = {"series": key, "generated_at": generated_at, "mode": FORECAST_MODE}
    if readings.dropna().empty:
        return {**base, "unavailable": "No hourly readings yet."}
    daily, n_bad = clean_to_daily(readings)
    if daily.isna().any() or len(daily) < MIN_DAYS:
        return {**base, "days": int(daily.notna().sum()),
                "unavailable": f"Needs at least {MIN_DAYS} days of history "
                               f"(has {int(daily.notna().sum())})."}
    train, test = split_train_test(daily)
    print(f"{key}: {len(daily)} days ({daily.index.min().date()} -> {daily.index.max().date()}), "
          f"{n_bad} incomplete days interpolated; train {len(train)}, test {len(test)}")

    fmt = lambda ts: ts.strftime("%Y-%m-%d")
    models, results, forecasters = {}, {}, {}
    for mk, run in runners.items():
        try:
            out = run(train, test)
            pred, next_day, info = out[:3]
            if len(out) > 3:
                forecasters[mk] = out[3]
        except Exception as exc:  # one failing model must not block the others
            print(f"  {mk}: failed: {exc}")
            models[mk] = {"unavailable": f"Training failed: {exc}"[:300]}
            continue
        results[mk] = evaluate(test, pred, MODEL_NAMES[mk])
        r = results[mk]
        models[mk] = {
            "mae": _num(r["MAE"]), "mse": _num(r["MSE"]), "rmse": _num(r["RMSE"]),
            "mape": _num(r["MAPE (%)"]), "r2": _num(r["R2"]),
            "values": [_num(v) for v in pred.values],
            "next_day": _num(next_day),
            **info,
        }
        print(f"  {MODEL_NAMES[mk]:8s} RMSE {r['RMSE']:10.4f}  MAPE {r['MAPE (%)']:7.2f}%  R2 {r['R2']:.4f}")

    ranked = sorted((mk for mk in results if models[mk]["rmse"] is not None),
                    key=lambda mk: models[mk]["rmse"])
    for i, mk in enumerate(ranked, 1):
        models[mk]["rank"] = i

    if results:
        comparison = (pd.DataFrame(results.values()).set_index("Model").sort_values("RMSE").round(4))
        comparison.insert(0, "Rank", range(1, len(comparison) + 1))
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
        comparison.to_csv(OUTPUT_DIR / f"model_comparison_{key}_{FORECAST_MODE}.csv")

    horizons = {}
    for h in HORIZONS:
        hz = horizon_forecasts(daily, h, {mk: f for mk, f in forecasters.items() if mk in results})
        if hz is None:
            continue
        info, per_model = hz
        horizons[f"d{h}"] = info
        for mk, entry in per_model.items():
            models[mk].setdefault("horizons", {})[f"d{h}"] = entry

    return {
        **base,
        "days": len(daily),
        "incomplete_days": n_bad,
        "train": {"start": fmt(train.index[0]), "end": fmt(train.index[-1]), "days": len(train)},
        "test": {"start": fmt(test.index[0]), "end": fmt(test.index[-1]), "days": len(test)},
        "actual": {"labels": [fmt(ts) for ts in test.index], "values": [_num(v) for v in test.values]},
        "next_day_label": fmt(test.index[-1] + pd.Timedelta(days=1)),
        "best": ranked[0] if ranked else None,
        "models": models,
        **({"horizons": horizons} if horizons else {}),
    }


def horizon_forecasts(daily: pd.Series, h: int, forecasters: dict):
    """The [h]-day forecast of every model: scored on the last min(h, test
    days) days of the history, forecast from the day before them without
    seeing any of them, then run from the last full day for the real next
    [h] days. kWh can't go below 0, so forecasts are floored there.
    Returns (series-level info, {model: entry}) or None with no models."""
    if not forecasters:
        return None
    fmt = lambda ts: ts.strftime("%Y-%m-%d")
    test_days = len(daily) - int(len(daily) * (1 - TEST_FRACTION))
    window = min(h, test_days)
    tested, history = daily.iloc[-window:], daily.iloc[:-window]
    future = pd.date_range(daily.index[-1] + pd.Timedelta(days=1), periods=h, freq="D")

    per_model = {}
    for mk, forecast in forecasters.items():
        try:
            back = np.maximum(np.asarray(forecast(history, window), float), 0.0)
            ahead = np.maximum(np.asarray(forecast(daily, h), float), 0.0)
        except Exception as exc:  # a horizon failing keeps the day-ahead result
            print(f"  {mk}: {h}-day forecast failed: {exc}")
            continue
        r = evaluate(tested, back, MODEL_NAMES[mk])
        per_model[mk] = {
            "backtest": [_num(v) for v in back],
            "values": [_num(v) for v in ahead],
            "total": _num(ahead.sum()),
            "mae": _num(r["MAE"]), "rmse": _num(r["RMSE"]), "mape": _num(r["MAPE (%)"]),
        }
        print(f"  {MODEL_NAMES[mk]:8s} {h:2d}-day: RMSE {r['RMSE']:10.4f}  MAPE {r['MAPE (%)']:7.2f}%  "
              f"next {h} days {ahead.sum():.3f} kWh")

    ranked = sorted((mk for mk, e in per_model.items() if e["rmse"] is not None),
                    key=lambda mk: per_model[mk]["rmse"])
    for i, mk in enumerate(ranked, 1):
        per_model[mk]["rank"] = i
    info = {
        "days": h,
        "start": fmt(future[0]), "end": fmt(future[-1]),
        "test": {"start": fmt(tested.index[0]), "end": fmt(tested.index[-1]), "days": window},
        "best": ranked[0] if ranked else None,
    }
    return info, per_model


def compare_all(hourly: dict, now_utc: datetime, runners=None) -> dict:
    today_ph = now_utc.astimezone(PH_TZ).strftime("%Y-%m-%d")
    generated_at = int(now_utc.timestamp() * 1000)
    return {key: compare_series(key, hourly_series(hourly, key, before_day=today_ph),
                                generated_at, runners)
            for key in series_keys(hourly)}


# ── Firebase ──────────────────────────────────────────────────────────────

def init_firebase():
    import firebase_admin
    from firebase_admin import credentials
    cred_json = os.environ.get('FIREBASE_SERVICE_ACCOUNT')
    db_url = os.environ.get('FIREBASE_DB_URL')
    if not db_url:
        raise RuntimeError('FIREBASE_DB_URL required')
    if cred_json:
        cred_dict = json.loads(cred_json)
        print('Signing in as', cred_dict.get('client_email'),
              '(project', cred_dict.get('project_id'), ')')
        print('Database:', db_url)
        cred = credentials.Certificate(cred_dict)
    else:
        # Use Application Default Credentials (Workload Identity / ADC)
        cred = credentials.ApplicationDefault()
    firebase_admin.initialize_app(cred, {'databaseURL': db_url})


def fetch_hourly() -> dict:
    from firebase_admin import db
    try:
        data = db.reference('energy_summaries/hourly').get()
    except Exception as exc:
        raise RuntimeError(
            'Could not read energy_summaries/hourly. The service account must '
            'belong to (or be granted "Firebase Realtime Database Admin" on) '
            f'the project that owns the database. Original error: {exc}') from exc
    return data if isinstance(data, dict) else {}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--dry-run', action='store_true', help='read RTDB but write nothing to it')
    ap.add_argument('--hourly-json', help='read energy_summaries/hourly from this JSON file instead of RTDB')
    args = ap.parse_args(argv)

    if args.hourly_json:
        with open(args.hourly_json, encoding='utf-8') as f:
            hourly = json.load(f)
    else:
        init_firebase()
        hourly = fetch_hourly()
    print('Fetched', len(hourly), 'hourly summaries')

    result = compare_all(hourly, datetime.now(timezone.utc))
    if args.dry_run or args.hourly_json:
        print(json.dumps({k: {f: v.get(f) for f in ('days', 'best', 'unavailable')}
                          for k, v in result.items()}, indent=2))
        print('Dry run: nothing written.')
        return result
    from firebase_admin import db
    db.reference(COMPARISON_REF).set(result)
    print('Comparison written to', COMPARISON_REF, 'for', ', '.join(result))
    return result


if __name__ == '__main__':
    main()
