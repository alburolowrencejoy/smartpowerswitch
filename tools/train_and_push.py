import os
import json
import math
from datetime import datetime, timedelta

import numpy as np
import pandas as pd

import firebase_admin
from firebase_admin import credentials, db, storage

import tensorflow as tf
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import LSTM, Dense
from tensorflow.keras.callbacks import EarlyStopping


def init_firebase():
    cred_json = os.environ.get('FIREBASE_SERVICE_ACCOUNT')
    db_url = os.environ.get('FIREBASE_DB_URL')
    storage_bucket = os.environ.get('FIREBASE_STORAGE_BUCKET')
    if not db_url:
        raise RuntimeError('FIREBASE_DB_URL required')

    options = {'databaseURL': db_url}
    if storage_bucket:
        options['storageBucket'] = storage_bucket

    if cred_json:
        # Use explicit service account JSON (legacy method)
        cred_dict = json.loads(cred_json)
        cred = credentials.Certificate(cred_dict)
        firebase_admin.initialize_app(cred, options)
    else:
        # Use Application Default Credentials (Workload Identity / ADC)
        cred = credentials.ApplicationDefault()
        firebase_admin.initialize_app(cred, options)


def fetch_daily_history():
    ref = db.reference('history/daily')
    data = ref.get()
    if not isinstance(data, dict):
        return pd.DataFrame()
    rows = []
    for label, v in data.items():
        kwh = v.get('kwh') or v.get('total_kwh') or 0.0
        rows.append({'label': label, 'kwh': float(kwh)})
    df = pd.DataFrame(rows)
    df = df.sort_values('label')
    return df


def make_sequences(series, window=14):
    X, y = [], []
    for i in range(len(series) - window):
        X.append(series[i:i+window])
        y.append(series[i+window])
    return np.array(X), np.array(y)


def build_model(window):
    model = Sequential([
        LSTM(64, input_shape=(window, 1), activation='tanh'),
        Dense(32, activation='relu'),
        Dense(1)
    ])
    model.compile(optimizer='adam', loss='mse')
    return model


def train_and_forecast(df, window=14, epochs=50, horizon=30):
    if df.empty or len(df) < window + 1:
        return None
    series = df['kwh'].values.astype('float32')
    # normalize
    mean = series.mean()
    std = series.std() if series.std() > 0 else 1.0
    norm = (series - mean) / std

    X, y = make_sequences(norm, window)
    X = X.reshape((X.shape[0], X.shape[1], 1))

    model = build_model(window)
    es = EarlyStopping(monitor='loss', patience=6, restore_best_weights=True)
    model.fit(X, y, epochs=epochs, batch_size=8, callbacks=[es], verbose=0)

    # forecast iteratively
    last_window = norm[-window:].tolist()
    preds = []
    for _ in range(horizon):
        inp = np.array(last_window[-window:]).reshape((1, window, 1))
        p = model.predict(inp, verbose=0)[0,0]
        last_window.append(p)
        preds.append(p)

    preds = np.array(preds) * std + mean
    preds = np.where(preds < 0, 0.0, preds)

    # convert model to tflite
    tflite_path = os.path.join('models', 'forecast.tflite')
    os.makedirs('models', exist_ok=True)
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    tflite_model = converter.convert()
    with open(tflite_path, 'wb') as f:
        f.write(tflite_model)

    # Upload tflite to Firebase Storage (if available) and publish model URL
    try:
        bucket = storage.bucket()
        blob = bucket.blob('models/forecast.tflite')
        blob.upload_from_filename(tflite_path)
        try:
            blob.make_public()
            model_url = blob.public_url
        except Exception:
            # make_public may fail depending on bucket IAM; fallback to gs:// path
            model_url = f'gs://{bucket.name}/models/forecast.tflite'
    except Exception:
        model_url = None

    # labels: dates after last label (assume daily)
    last_label = df['label'].iloc[-1]
    try:
        last_date = datetime.strptime(last_label, '%Y-%m-%d')
    except Exception:
        last_date = datetime.utcnow()

    labels = [(last_date + timedelta(days=i+1)).strftime('%Y-%m-%d') for i in range(horizon)]

    return {
        'labels': labels,
        'values': preds.tolist(),
        'tflite_path': tflite_path,
        'model_url': model_url,
        'predicted_kwh_total': float(np.sum(preds)),
    }


BACKTEST_DAYS = 14


def forecast_errors(actual, predicted):
    """MAE (kWh/day) and MAPE (%) -- same rules as the app's Dart backtest:
    MAPE skips near-zero days, where a percentage error is meaningless."""
    actual = np.asarray(actual, dtype='float64')
    predicted = np.asarray(predicted, dtype='float64')
    err = np.abs(actual - predicted)
    mask = actual > 0.05
    mape = float(np.mean(err[mask] / actual[mask]) * 100) if mask.any() else 0.0
    return {'mae': float(np.mean(err)), 'mape': mape, 'days': int(len(actual))}


def lstm_values(series, horizon, window=14, epochs=50):
    """Trains a fresh LSTM on `series` and forecasts `horizon` days."""
    series = np.asarray(series, dtype='float32')
    mean = series.mean()
    std = series.std() if series.std() > 0 else 1.0
    norm = (series - mean) / std
    X, y = make_sequences(norm, window)
    X = X.reshape((X.shape[0], X.shape[1], 1))
    model = build_model(window)
    es = EarlyStopping(monitor='loss', patience=6, restore_best_weights=True)
    model.fit(X, y, epochs=epochs, batch_size=8, callbacks=[es], verbose=0)
    last = norm[-window:].tolist()
    preds = []
    for _ in range(horizon):
        p = model.predict(np.array(last[-window:]).reshape((1, window, 1)), verbose=0)[0, 0]
        last.append(p)
        preds.append(p)
    return np.maximum(np.array(preds) * std + mean, 0.0)


def _xgb_features(values, t, dow0):
    dow = (dow0 + t) % 7
    return [1.0 if dow >= 5 else 0.0, float(dow), values[t - 1], values[t - 7],
            float(np.mean(values[t - 7:t]))]


def xgb_values(series, horizon, dow0):
    """XGBoost on weekend flag, weekday, yesterday, same day last week and
    the 7-day average; forecasts one day at a time, feeding each back in."""
    import xgboost as xgb
    values = [float(v) for v in series]
    X = [_xgb_features(values, t, dow0) for t in range(7, len(values))]
    y = values[7:]
    model = xgb.XGBRegressor(n_estimators=200, max_depth=3, learning_rate=0.08,
                             subsample=0.9, objective='reg:squarederror')
    model.fit(np.array(X), np.array(y))
    out = list(values)
    for _ in range(horizon):
        x = np.array([_xgb_features(out, len(out), dow0)])
        out.append(max(0.0, float(model.predict(x)[0])))
    return np.array(out[len(values):])


def run_model(name, fn, series, horizon=30):
    """Full forecast plus a backtest on the last BACKTEST_DAYS days."""
    if len(series) < BACKTEST_DAYS + 21:
        print(f'{name}: not enough history ({len(series)} days)')
        return None
    held = fn(series[:-BACKTEST_DAYS], BACKTEST_DAYS)
    return {
        'values': [float(v) for v in fn(series, horizon)],
        'backtest': forecast_errors(series[-BACKTEST_DAYS:], held),
    }


def push_models(df, horizon=30):
    """Writes history/predictions/models/{lstm,xgboost}. Kept apart from
    history/predictions/daily, which the app rewrites with its own linear
    fallback every few hours."""
    series = df['kwh'].values.astype('float64')[-120:]
    labels_hist = df['label'].values[-len(series):]
    try:
        first = datetime.strptime(labels_hist[0], '%Y-%m-%d')
        last_date = datetime.strptime(labels_hist[-1], '%Y-%m-%d')
    except Exception:
        print('Daily labels are not YYYY-MM-DD; skipping model comparison')
        return
    dow0 = first.weekday()  # Monday = 0, matching the weekend flag above
    labels = [(last_date + timedelta(days=i + 1)).strftime('%Y-%m-%d')
              for i in range(horizon)]
    generated = int(datetime.utcnow().timestamp() * 1000)

    models = {
        'lstm': lambda s, h: lstm_values(s, h),
        'xgboost': lambda s, h: xgb_values(s, h, dow0),
    }
    for key, fn in models.items():
        try:
            result = run_model(key, fn, series, horizon)
        except Exception as exc:  # one failing model must not block the other
            print(f'{key}: failed: {exc}')
            continue
        if not result:
            continue
        db.reference(f'history/predictions/models/{key}').set({
            'generated_at': generated,
            'labels': labels,
            'values': result['values'],
            'predicted_kwh_total': float(sum(result['values'])),
            'backtest': result['backtest'],
        })
        print(f"{key}: MAPE {result['backtest']['mape']:.1f}% pushed")


def push_forecast(payload):
    ref = db.reference('history/predictions/daily')
    data = {
        'generated_at': int(datetime.utcnow().timestamp() * 1000),
        'labels': payload['labels'],
        'values': payload['values'],
        'predicted_kwh_total': payload['predicted_kwh_total'],
    }
    ref.set(data)
    # also set model URL if provided
    try:
        model_url = payload.get('model_url')
        if model_url:
            db.reference('history/predictions/model_url').set(model_url)
    except Exception:
        pass


def main():
    init_firebase()
    df = fetch_daily_history()
    print('Fetched', len(df), 'daily points')
    result = train_and_forecast(df)
    if not result:
        print('Not enough data to train')
        return
    print('Forecast generated, total predicted kWh:', result['predicted_kwh_total'])
    push_forecast(result)
    print('Forecast pushed to RTDB at history/predictions/daily')
    push_models(df)


if __name__ == '__main__':
    main()
