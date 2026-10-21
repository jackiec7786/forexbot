"""Signal server.

Receives trend-flip alerts from TradingView and hands the latest one to MT4,
but only while it is fresh and not during high-impact news.

Run with:  uvicorn app:create_app --factory --host 127.0.0.1 --port 8000
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import threading
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Literal, Optional, Protocol

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

log = logging.getLogger("signal-server")

FOREX_FACTORY_URL = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
WAIT = "WAIT|0"


@dataclass(frozen=True)
class Settings:
    secret: str
    state_file: str = "signal_state.json"
    max_age_minutes: int = 15
    news_filter: bool = True
    news_window_minutes: int = 30
    news_currencies: tuple[str, ...] = ("USD",)

    @classmethod
    def from_env(cls) -> "Settings":
        secret = os.environ.get("SIGNAL_SECRET", "")
        if len(secret) < 24:
            raise RuntimeError("Set SIGNAL_SECRET to a random string of at least 24 characters.")
        return cls(
            secret=secret,
            state_file=os.environ.get("STATE_FILE", "signal_state.json"),
            max_age_minutes=int(os.environ.get("MAX_SIGNAL_AGE_MINUTES", "15")),
            news_filter=os.environ.get("NEWS_FILTER", "on").lower() not in ("off", "0", "false"),
            news_window_minutes=int(os.environ.get("NEWS_WINDOW_MINUTES", "30")),
            news_currencies=tuple(
                c.strip().upper() for c in os.environ.get("NEWS_CURRENCIES", "USD").split(",") if c.strip()
            ),
        )


class SignalStore:
    """Latest signal, saved to disk so a restart does not lose it."""

    def __init__(self, path: str):
        self._path = Path(path)
        self._lock = threading.Lock()
        self._data = self._load()

    def _load(self) -> Optional[dict]:
        try:
            return json.loads(self._path.read_text())
        except (FileNotFoundError, ValueError):
            return None

    def set(self, signal: str, signal_id: int, received_at: float) -> None:
        data = {"signal": signal, "signal_id": signal_id, "received_at": received_at}
        with self._lock:
            tmp = self._path.with_suffix(".tmp")
            tmp.write_text(json.dumps(data))
            os.replace(tmp, self._path)
            self._data = data

    def get(self) -> Optional[dict]:
        with self._lock:
            return dict(self._data) if self._data else None


class NewsSource(Protocol):
    def blocking_event(self, now: datetime, window: timedelta) -> Optional[str]: ...


class NewsCalendar:
    """High-impact events from the Forex Factory weekly calendar.

    Fails closed: if the calendar has never loaded, trading is blocked.
    """

    def __init__(
        self,
        currencies: tuple[str, ...],
        url: str = FOREX_FACTORY_URL,
        refresh_seconds: int = 3600,
        retry_seconds: int = 300,
        fetch: Optional[Callable[[], list]] = None,
    ):
        self._currencies = set(currencies)
        self._url = url
        self._refresh_seconds = refresh_seconds
        self._retry_seconds = retry_seconds
        self._fetch = fetch or self._http_fetch
        self._events: Optional[list[tuple[datetime, str]]] = None
        self._fetched_at = float("-inf")
        self._last_attempt = float("-inf")
        self._lock = threading.Lock()

    def _http_fetch(self) -> list:
        req = urllib.request.Request(self._url, headers={"User-Agent": "forexbot-signal-server"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.load(resp)

    def _refresh(self, now_ts: float) -> None:
        due = self._events is None or now_ts - self._fetched_at >= self._refresh_seconds
        if not due or now_ts - self._last_attempt < self._retry_seconds:
            return
        self._last_attempt = now_ts
        try:
            events = []
            for e in self._fetch():
                if e.get("impact") == "High" and e.get("country") in self._currencies:
                    events.append((datetime.fromisoformat(e["date"]), e.get("title", "")))
            self._events = events
            self._fetched_at = now_ts
        except Exception as exc:  # keep the last good copy
            log.warning("News calendar refresh failed: %s", exc)

    def blocking_event(self, now: datetime, window: timedelta) -> Optional[str]:
        with self._lock:
            self._refresh(now.timestamp())
            if self._events is None:
                return "news calendar unavailable"
            for when, title in self._events:
                if abs(when - now) <= window:
                    return title
            return None


class TradingViewAlert(BaseModel):
    secret: str
    signal: Literal["BUY", "SELL"]
    bar_time: int  # TradingView `time`: bar open time in milliseconds


def create_app(
    settings: Optional[Settings] = None,
    news: Optional[NewsSource] = None,
    clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
) -> FastAPI:
    settings = settings or Settings.from_env()
    store = SignalStore(settings.state_file)
    if news is None and settings.news_filter:
        news = NewsCalendar(settings.news_currencies)

    app = FastAPI(title="forexbot signal server", docs_url=None, redoc_url=None, openapi_url=None)

    def require_secret(given: str) -> None:
        if not hmac.compare_digest(given.encode(), settings.secret.encode()):
            raise HTTPException(status_code=403, detail="forbidden")

    def decide(now: datetime) -> tuple[str, str]:
        latest = store.get()
        if not latest:
            return WAIT, "no signal yet"
        age = now.timestamp() - latest["received_at"]
        if age > settings.max_age_minutes * 60:
            return WAIT, f"latest signal is stale ({int(age // 60)} min old)"
        if news is not None:
            event = news.blocking_event(now, timedelta(minutes=settings.news_window_minutes))
            if event:
                return WAIT, f"news blackout: {event}"
        return f"{latest['signal']}|{latest['signal_id']}", "ok"

    # Sync handlers run in a thread pool, so a slow calendar fetch never blocks other requests.
    @app.get("/health")
    def health() -> dict:
        return {"ok": True}

    @app.post("/webhook/tradingview")
    def tradingview(alert: TradingViewAlert) -> dict:
        require_secret(alert.secret)
        store.set(alert.signal, alert.bar_time // 1000, clock().timestamp())
        log.info("TradingView signal: %s (bar %s)", alert.signal, alert.bar_time)
        return {"ok": True}

    @app.get("/api/signal", response_class=PlainTextResponse)
    def signal(x_signal_secret: str = Header(default="")) -> str:
        require_secret(x_signal_secret)
        answer, _ = decide(clock())
        return answer

    @app.get("/api/status")
    def status(x_signal_secret: str = Header(default="")) -> dict:
        require_secret(x_signal_secret)
        answer, reason = decide(clock())
        return {"answer": answer, "reason": reason, "latest": store.get()}

    return app
