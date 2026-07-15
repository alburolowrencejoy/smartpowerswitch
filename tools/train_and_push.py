import os
import json
import math
from datetime import datetime, timedelta

import numpy as np
import pandas as pd

import firebase_admin
from firebase_admin import credentials, db, storage, exceptions

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
    try:
        data = ref.get()
    except exceptions.UnauthenticatedError as e:
        print(f'Unable to read history/daily from RTDB: {e}')
        return pd.DataFrame()
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


def push_forecast(payload):
    ref = db.reference('history/predictions/daily')
    data = {
        'generated_at': int(datetime.utcnow().timestamp() * 1000),
        'labels': payload['labels'],
        'values': payload['values'],
        'predicted_kwh_total': payload['predicted_kwh_total'],
    }
    try:
        ref.set(data)
    except exceptions.UnauthenticatedError as e:
        print(f'Unable to write history/predictions/daily to RTDB: {e}')
        return False
    # also set model URL if provided
    try:
        model_url = payload.get('model_url')
        if model_url:
            db.reference('history/predictions/model_url').set(model_url)
    except Exception:
        pass
    return True


def main():
    init_firebase()
    df = fetch_daily_history()
    print('Fetched', len(df), 'daily points')
    result = train_and_forecast(df)
    if not result:
        print('Not enough data to train')
        return
    print('Forecast generated, total predicted kWh:', result['predicted_kwh_total'])
    if push_forecast(result):
        print('Forecast pushed to RTDB at history/predictions/daily')


if __name__ == '__main__':
    main()
