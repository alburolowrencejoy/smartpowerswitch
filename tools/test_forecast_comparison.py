"""Tests for tools/forecast_comparison.py.

    python -m pytest tools/test_forecast_comparison.py          # fast tests
    python -m pytest tools/test_forecast_comparison.py -m slow  # also trains the real models
"""
import math
import os
import sys
from datetime import datetime, timezone

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, os.path.dirname(__file__))
import forecast_comparison as fc  # noqa: E402


def make_hourly(days, start="2026-01-01", buildings=("IC", "ITED"), zero_hours=(), skip_hours=()):
    """energy_summaries/hourly-shaped dict with a weekly pattern: weekdays
    use more than weekends. Building totals add up to the campus total."""
    out = {}
    t0 = pd.Timestamp(start)
    for h in range(days * 24):
        ts = t0 + pd.Timedelta(hours=h)
        if ts in skip_hours:
            continue
        base = 2.0 if ts.day_of_week < 5 else 0.8
        per = {b: (0.0 if ts in zero_hours else base * (i + 1) * (1.2 if 8 <= ts.hour < 17 else 0.6))
               for i, b in enumerate(buildings)}
        per[fc.UNASSIGNED] = 0.0 if ts in zero_hours else 0.1
        out[ts.strftime("%Y-%m-%d-%H")] = {
            "campus": {"kwh": sum(per.values())},
            "buildings": {b: {"kwh": v} for b, v in per.items()},
        }
    return out


def test_series_keys_are_campus_then_institutes_without_unassigned():
    assert fc.series_keys(make_hourly(2)) == ["campus", "IC", "ITED"]
    assert fc.series_keys({}) == ["campus"]


def test_hourly_series_reads_campus_and_institutes_and_drops_today():
    hourly = make_hourly(3)
    hourly["junk"] = {"campus": {"kwh": 5}}
    campus = fc.hourly_series(hourly, "campus", before_day="2026-01-03")
    ic = fc.hourly_series(hourly, "IC", before_day="2026-01-03")
    assert len(campus) == 48 and len(ic) == 48
    assert campus.index[0] == pd.Timestamp("2026-01-01 00:00")
    assert campus.index[-1] == pd.Timestamp("2026-01-02 23:00")
    assert campus.iloc[10] == pytest.approx(ic.iloc[10] + hourly["2026-01-01-10"]["buildings"]["ITED"]["kwh"] + 0.1)
    assert fc.hourly_series(hourly, "NOPE").empty


def test_clean_to_daily_counts_missing_hours_as_zero_and_fills_offline_days():
    # Day 2 is missing 3 hours: they used nothing, so the day is just the
    # sum of the hours it has. Day 3 has no readings at all (board offline),
    # so it is interpolated from its neighbours.
    t0 = pd.Timestamp("2026-01-01")
    short_gap = {t0 + pd.Timedelta(days=1, hours=h) for h in (3, 4, 5)}
    offline = {t0 + pd.Timedelta(days=2, hours=h) for h in range(24)}
    hourly = make_hourly(5, skip_hours=short_gap | offline)
    daily, n_bad = fc.clean_to_daily(fc.hourly_series(hourly, "campus"))
    assert len(daily) == 5
    assert n_bad == 1                           # only day 3 is missing
    assert daily.notna().all()
    assert daily.iloc[2] == pytest.approx((daily.iloc[1] + daily.iloc[3]) / 2)
    day2 = sum(v["campus"]["kwh"] for k, v in hourly.items() if k.startswith("2026-01-02"))
    assert daily.iloc[1] == pytest.approx(day2)


def test_clean_to_daily_keeps_a_scheduled_night_load():
    # A 14 W load on 18:00-06:00: 12 hours a day, no entry for the other 12.
    idx = [t for t in pd.date_range("2026-01-01", periods=70 * 24, freq="h") if t.hour >= 18 or t.hour < 6]
    daily, n_bad = fc.clean_to_daily(pd.Series(0.014, index=idx))
    assert len(daily) == 70 and n_bad == 0
    assert daily.iloc[1:].round(6).eq(0.168).all()


def test_split_is_chronological_80_20():
    daily = pd.Series(range(100), index=pd.date_range("2026-01-01", periods=100, freq="D"), dtype=float)
    train, test = fc.split_train_test(daily)
    assert len(train) == 80 and len(test) == 20
    assert train.index[-1] < test.index[0]


def _fake(offset, fail=False):
    def run(train, test):
        if fail:
            raise ValueError("boom")
        return pd.Series(test.values + offset, index=test.index), float(test.iloc[-1] + offset), {}
    return run


def test_compare_series_payload_ranks_by_rmse_and_isolates_failures(tmp_path, monkeypatch):
    monkeypatch.setattr(fc, "OUTPUT_DIR", tmp_path)
    readings = fc.hourly_series(make_hourly(100), "campus")
    runners = {"arima": _fake(3.0), "xgboost": _fake(1.0), "gru": _fake(0.5), "lstm": _fake(0, fail=True)}
    out = fc.compare_series("campus", readings, 123, runners)

    assert out["generated_at"] == 123 and out["mode"] == "rolling"
    assert out["days"] == 100 and out["train"]["days"] == 80 and out["test"]["days"] == 20
    assert len(out["actual"]["labels"]) == 20 and out["actual"]["labels"][0] == out["test"]["start"]
    assert out["next_day_label"] == "2026-04-11"
    assert out["best"] == "gru"
    m = out["models"]
    assert [m[k]["rank"] for k in ("gru", "xgboost", "arima")] == [1, 2, 3]
    assert m["gru"]["rmse"] == pytest.approx(0.5) and m["gru"]["mae"] == pytest.approx(0.5)
    assert len(m["gru"]["values"]) == 20
    assert "rank" not in m["lstm"] and "boom" in m["lstm"]["unavailable"]
    assert (tmp_path / "model_comparison_campus_rolling.csv").exists()


def test_compare_series_reports_too_little_history():
    readings = fc.hourly_series(make_hourly(30), "IC")
    out = fc.compare_series("IC", readings, 1, {"arima": _fake(0)})
    assert "models" not in out and "60 days" in out["unavailable"]
    assert "No hourly readings" in fc.compare_series("X", pd.Series(dtype=float), 1)["unavailable"]


def test_compare_all_covers_campus_and_each_institute(tmp_path, monkeypatch):
    monkeypatch.setattr(fc, "OUTPUT_DIR", tmp_path)
    hourly = make_hourly(70)
    now = datetime(2026, 3, 11, 2, 0, tzinfo=timezone.utc)     # 10:00 on Mar 11 in the Philippines
    runners = {"arima": _fake(1.0)}
    out = fc.compare_all(hourly, now, runners)
    assert list(out) == ["campus", "IC", "ITED"]
    # Mar 11 is still running, so it is left out: Jan 1 .. Mar 10 = 69 days.
    assert all(v["days"] == 69 for v in out.values())
    assert out["IC"]["models"]["arima"]["rank"] == 1


def test_non_finite_numbers_are_dropped_for_rtdb():
    assert fc._num(float("nan")) is None and fc._num(math.inf) is None and fc._num(2) == 2.0


@pytest.mark.slow
def test_real_models_run_end_to_end(tmp_path, monkeypatch):
    """Trains ARIMA, XGBoost, GRU and LSTM on 100 synthetic days."""
    monkeypatch.setattr(fc, "OUTPUT_DIR", tmp_path)
    readings = fc.hourly_series(make_hourly(100, buildings=("IC",)), "campus")
    out = fc.compare_series("campus", readings, 1)
    for k in fc.MODEL_KEYS:
        m = out["models"][k]
        assert "unavailable" not in m, (k, m)
        assert len(m["values"]) == 20 and all(np.isfinite(m["values"]))
        assert np.isfinite(m["next_day"]) and m["rank"] in (1, 2, 3, 4)
    assert len(out["models"]["arima"]["order"]) == 3
    # A clean weekly pattern is easy: every model should land within 25 %.
    assert all(out["models"][k]["mape"] < 25 for k in fc.MODEL_KEYS)
