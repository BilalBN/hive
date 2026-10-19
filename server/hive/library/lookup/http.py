"""One polite HTTP client for every online source.

MusicBrainz asks for at most one request a second and a User-Agent that says
who is asking; the others get the same courtesy. Requests are made from one
background thread, one album at a time.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Any
from urllib.parse import urlsplit

import httpx

from hive import __version__

log = logging.getLogger("hive.lookup")

USER_AGENT = f"Hive/{__version__} ( https://github.com/BilalBN/hive )"

# Seconds between requests to the same host.
SPACING = {
    "musicbrainz.org": 1.1,
    "coverartarchive.org": 0.5,
    "www.wikidata.org": 0.3,
    "api.acoustid.org": 0.4,
}


class Offline(Exception):
    """The internet (or that service) can't be reached right now."""


class Http:
    def __init__(self, transport: httpx.BaseTransport | None = None) -> None:
        self.client = httpx.Client(
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            timeout=httpx.Timeout(20.0, connect=10.0),
            follow_redirects=True,
            transport=transport,
        )
        self._last: dict[str, float] = {}
        self._lock = threading.Lock()
        self._answered_at = 0.0
        # Tests turn the waiting off.
        self.spacing = dict(SPACING)

    def _wait_turn(self, url: str) -> None:
        host = urlsplit(url).hostname or ""
        gap = self.spacing.get(host, 0.0)
        with self._lock:
            now = time.monotonic()
            wait = self._last.get(host, 0.0) + gap - now
            if wait > 0:
                time.sleep(wait)
            self._last[host] = time.monotonic()

    def request(
        self, method: str, url: str, *, keep_errors: bool = False, **kw: Any
    ) -> httpx.Response | None:
        """The response, None for 404 (and other refusals unless [keep_errors]),
        or Offline when the source can't answer."""
        for attempt in range(3):
            self._wait_turn(url)
            try:
                r = self.client.request(method, url, **kw)
            except httpx.TransportError as e:
                if attempt == 2:
                    host = urlsplit(url).hostname
                    raise Offline(f"{host} can't be reached ({type(e).__name__})") from e
                time.sleep(2 * (attempt + 1))
                continue
            if r.status_code in (429, 500, 502, 503, 504):
                if attempt == 2:
                    raise Offline(f"{urlsplit(url).hostname} is busy (HTTP {r.status_code})")
                time.sleep(float(r.headers.get("Retry-After", "") or 2 * (attempt + 1)))
                continue
            self._answered_at = time.monotonic()
            if r.status_code == 404:
                return None
            if r.status_code >= 400 and not keep_errors:
                # Not the URL: it carries album names.
                log.info("%s answered HTTP %s", urlsplit(url).hostname, r.status_code)
                return None
            return r
        return None

    def answered_since(self, t: float) -> bool:
        """Some source answered after monotonic time [t]: the internet works."""
        return self._answered_at > t

    def json(self, url: str, **params: Any) -> Any:
        r = self.request("GET", url, params=params)
        if r is None:
            return None
        try:
            return r.json()
        except ValueError:
            return None

    def close(self) -> None:
        self.client.close()
