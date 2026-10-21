from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app import NewsCalendar, Settings, create_app

SECRET = "s" * 32
BAR_MS = 1_792_584_000_000
HEADERS = {"X-Signal-Secret": SECRET}


class Clock:
    def __init__(self):
        self.now = datetime(2026, 10, 21, 12, 0, tzinfo=timezone.utc)

    def __call__(self):
        return self.now


class FakeNews:
    def __init__(self, event=None):
        self.event = event

    def blocking_event(self, now, window):
        return self.event


@pytest.fixture
def clock():
    return Clock()


def make_client(tmp_path, clock, news=None):
    settings = Settings(secret=SECRET, state_file=str(tmp_path / "state.json"), news_filter=False)
    return TestClient(create_app(settings, news=news, clock=clock))


def post_signal(client, signal="BUY", secret=SECRET):
    return client.post("/webhook/tradingview", json={"secret": secret, "signal": signal, "bar_time": BAR_MS})


def test_wait_when_no_signal(tmp_path, clock):
    client = make_client(tmp_path, clock)
    assert client.get("/api/signal", headers=HEADERS).text == "WAIT|0"


def test_fresh_signal_is_returned_with_id(tmp_path, clock):
    client = make_client(tmp_path, clock)
    assert post_signal(client, "SELL").status_code == 200
    assert client.get("/api/signal", headers=HEADERS).text == f"SELL|{BAR_MS // 1000}"


def test_stale_signal_returns_wait(tmp_path, clock):
    client = make_client(tmp_path, clock)
    post_signal(client)
    clock.now += timedelta(minutes=16)
    assert client.get("/api/signal", headers=HEADERS).text == "WAIT|0"


def test_news_blackout_returns_wait(tmp_path, clock):
    client = make_client(tmp_path, clock, news=FakeNews("Non-Farm Employment Change"))
    post_signal(client)
    resp = client.get("/api/status", headers=HEADERS).json()
    assert resp["answer"] == "WAIT|0"
    assert "Non-Farm" in resp["reason"]


def test_bad_secrets_rejected(tmp_path, clock):
    client = make_client(tmp_path, clock)
    assert post_signal(client, secret="wrong").status_code == 403
    assert client.get("/api/signal", headers={"X-Signal-Secret": "wrong"}).status_code == 403
    assert client.get("/api/signal").status_code == 403


def test_invalid_signal_rejected(tmp_path, clock):
    client = make_client(tmp_path, clock)
    assert post_signal(client, "WAIT").status_code == 422


def test_signal_survives_restart(tmp_path, clock):
    post_signal(make_client(tmp_path, clock))
    restarted = make_client(tmp_path, clock)
    assert restarted.get("/api/signal", headers=HEADERS).text.startswith("BUY|")


def test_settings_require_long_secret(monkeypatch):
    monkeypatch.setenv("SIGNAL_SECRET", "short")
    with pytest.raises(RuntimeError):
        Settings.from_env()


# --- News calendar ---

NOW = datetime(2026, 10, 21, 12, 30, tzinfo=timezone.utc)
WINDOW = timedelta(minutes=30)
EVENTS = [
    {"title": "CPI m/m", "country": "USD", "date": "2026-10-21T08:30:00-04:00", "impact": "High"},
    {"title": "Bank Holiday", "country": "USD", "date": "2026-10-21T12:30:00+00:00", "impact": "Low"},
    {"title": "ECB Speech", "country": "EUR", "date": "2026-10-21T12:30:00+00:00", "impact": "High"},
]


def test_calendar_blocks_high_impact_usd_event():
    cal = NewsCalendar(("USD",), fetch=lambda: EVENTS)
    assert cal.blocking_event(NOW, WINDOW) == "CPI m/m"


def test_calendar_ignores_events_outside_window():
    cal = NewsCalendar(("USD",), fetch=lambda: EVENTS)
    assert cal.blocking_event(NOW + timedelta(hours=2), WINDOW) is None


def test_calendar_fails_closed_when_never_loaded():
    def broken():
        raise OSError("network down")

    cal = NewsCalendar(("USD",), fetch=broken)
    assert cal.blocking_event(NOW, WINDOW) == "news calendar unavailable"


def test_calendar_keeps_last_good_copy_when_refresh_fails():
    calls = {"n": 0}

    def flaky():
        calls["n"] += 1
        if calls["n"] > 1:
            raise OSError("network down")
        return EVENTS

    cal = NewsCalendar(("USD",), fetch=flaky, refresh_seconds=0, retry_seconds=0)
    assert cal.blocking_event(NOW, WINDOW) == "CPI m/m"
    assert cal.blocking_event(NOW, WINDOW) == "CPI m/m"
    assert calls["n"] == 2
