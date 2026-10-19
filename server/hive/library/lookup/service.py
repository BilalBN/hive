"""The lookup worker: one album at a time, in the background, once per album.

For each album waiting: find it on MusicBrainz (by name, or by the files'
MusicBrainz ids, or by sound fingerprint when an AcoustID key is set), find the
film on Wikidata when it's a soundtrack, fetch the cover from Cover Art
Archive, then either apply what was found (sure), keep it for the admin to
review (unsure), or note that nothing was found.

What leaves home: album and artist names, song titles and lengths, and, with
an AcoustID key, fingerprints of songs. Never the audio, and nothing about who
listens to what.
"""

from __future__ import annotations

import json
import logging
import threading
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from hive.config import Settings
from hive.db import Database
from hive.library import catalog as C
from hive.library import languages as L
from hive.library import text as T
from hive.library.artwork import ArtworkStore
from hive.library.lookup import match as M
from hive.library.lookup import sources as S
from hive.library.lookup.http import Http, Offline
from hive.models import Album, Credit, ServerMeta, Track

log = logging.getLogger("hive.lookup")

INDIAN = {"ml", "hi", "ta", "te", "kn", "bn", "pa", "gu", "mr", "ur"}
SENDS = (
    "Album and artist names, song titles and lengths go to MusicBrainz, Cover Art "
    "Archive and Wikidata{fp}. Never the music itself, and nothing about who listens."
)


def _now() -> datetime:
    return datetime.now(UTC)


class LookupService:
    def __init__(
        self,
        settings: Settings,
        db: Database,
        artwork: ArtworkStore,
        library_lock: threading.Lock,
        http: Http | None = None,
    ) -> None:
        self.settings = settings
        self.db = db
        self.artwork = artwork
        self.lock = library_lock  # the scanner's write lock: one writer at a time
        self.http = http or Http()
        self._fpcalc = S.find_fpcalc()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.working = False
        self.last_error: str | None = None
        self.pause_seconds = 300.0

    # ------------------------------------------------------------ settings
    def _meta(self, key: str) -> str | None:
        with Session(self.db.engine) as s:
            m = s.get(ServerMeta, key)
            return m.value if m else None

    def _set_meta(self, key: str, value: str | None) -> None:
        with self.lock, Session(self.db.engine) as s:
            m = s.get(ServerMeta, key)
            if value is None:
                if m is not None:
                    s.delete(m)
            elif m is None:
                s.add(ServerMeta(key=key, value=value))
            else:
                m.value = value
            s.commit()

    @property
    def enabled(self) -> bool:
        v = self._meta("lookup_enabled")
        return self.settings.lookup_online if v is None else v == "1"

    @property
    def acoustid_key(self) -> str | None:
        return self._meta("acoustid_key") or self.settings.acoustid_key or None

    @property
    def fpcalc(self) -> str | None:
        """Chromaprint's fpcalc, looked for again until found, so installing it
        while Hive runs works without a restart."""
        if self._fpcalc is None:
            self._fpcalc = S.find_fpcalc()
        return self._fpcalc

    @fpcalc.setter
    def fpcalc(self, path: str | None) -> None:
        self._fpcalc = path

    def configure(self, enabled: bool | None = None, acoustid_key: str | None = None) -> None:
        if enabled is not None:
            self._set_meta("lookup_enabled", "1" if enabled else "0")
        if acoustid_key is not None:
            self._set_meta("acoustid_key", acoustid_key.strip() or None)
        self.last_error = None
        self.wake()

    # ------------------------------------------------------------ lifecycle
    def start(self) -> None:
        with self.lock, Session(self.db.engine) as s:
            # Albums interrupted mid-lookup go back in line.
            s.query(Album).filter(Album.lookup_state == "working").update(
                {"lookup_state": "waiting"}
            )
            s.commit()
        self._thread = threading.Thread(target=self._run, name="hive-lookup", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread:
            self._thread.join(timeout=5)
        self.http.close()

    def wake(self) -> None:
        self._wake.set()

    def _sleep(self, seconds: float) -> None:
        self._wake.wait(timeout=seconds)
        self._wake.clear()

    def _next(self) -> str | None:
        with Session(self.db.engine) as s:
            return s.scalar(
                select(Album.id)
                .where(Album.lookup_state == "waiting")
                .order_by(Album.added_at)
                .limit(1)
            )

    def _progress(self, done: int, finished: bool) -> None:
        """One console line now and then instead of one per web request."""
        st = self.status()
        counts = (
            f"{st['found']} found, {st['review']} to check, "
            f"{st['notFound']} not found, {st['failed']} failed"
        )
        if finished:
            log.info("lookup finished: %d albums looked up (%s)", done, counts)
        else:
            log.info("lookup: %d albums done, %d waiting (%s)", done, st["waiting"], counts)

    def _run(self) -> None:
        done = 0
        announced = False
        while not self._stop.is_set():
            if not self.enabled:
                self._sleep(30)
                continue
            album_id = self._next()
            if album_id is None:
                if done:
                    self._progress(done, finished=True)
                done, announced = 0, False
                self._sleep(10)
                continue
            if not announced:
                log.info("lookup started: finding covers and film details online")
                announced = True
            try:
                self.working = True
                self.look_up(album_id)
                self.last_error = None
                done += 1
                if done % 25 == 0:
                    self._progress(done, finished=False)
            except Offline as e:
                self.last_error = str(e)
                self._set_state(album_id, "waiting", None)
                log.info("lookup paused: %s", e)
                self._sleep(self.pause_seconds)
            except Exception:  # noqa: BLE001 - one odd album must not stop the rest
                log.exception("lookup failed for album %s", album_id)
                note = "Something unexpected went wrong looking it up."
                self._set_state(album_id, "failed", note)
            finally:
                self.working = False

    def run_until_idle(self, limit: int = 100) -> int:
        """For tests and the CLI: look up every waiting album now."""
        n = 0
        while n < limit and (album_id := self._next()):
            try:
                self.look_up(album_id)
            except Offline as e:
                self.last_error = str(e)
                self._set_state(album_id, "failed", str(e))
            n += 1
        return n

    def _set_state(self, album_id: str, state: str, note: str | None) -> None:
        with self.lock, Session(self.db.engine) as s:
            a = s.get(Album, album_id)
            if a is not None:
                a.lookup_state = state
                a.lookup_note = note
                a.lookup_at = _now()
                s.commit()

    # ------------------------------------------------------------ one album
    def _home_album(self, s: Session, album: Album) -> M.HomeAlbum:
        tracks = s.scalars(
            select(Track)
            .where(Track.album_id == album.id)
            .order_by(func.coalesce(Track.disc_no, 1), func.coalesce(Track.track_no, 999))
        ).all()
        return M.HomeAlbum(
            id=album.id,
            title=album.title,
            artist=album.artist_name,
            year=album.year,
            language=album.language,
            title_from_tags=album.title != "Unknown album",
            tracks=[
                M.HomeTrack(t.title, t.duration_ms, t.track_no, t.disc_no, t.artist_name)
                for t in tracks
            ],
        )

    def look_up(self, album_id: str) -> None:
        with Session(self.db.engine) as s:
            album = s.get(Album, album_id)
            if album is None:
                return
            home = self._home_album(s, album)
            mbid = album.mbid_release
            paths = [p for p in s.scalars(select(Track.path).where(Track.album_id == album.id))][:3]
        self._set_state(album_id, "working", None)

        release, rscore, via = self._find_release(home, mbid, paths)
        film, fscore = self._find_film(home, release)

        sure_release = release is not None and rscore >= M.FOUND
        sure_film = film is not None and fscore >= M.FOUND
        if release is not None and not sure_release and rscore < M.REVIEW:
            release = None
        if film is not None and not sure_film and fscore < M.REVIEW:
            film = None

        cover_id = None
        if release is not None:
            data = S.cover_art(self.http, release.id, release.release_group_id)
            cover_id = self.artwork.save(data) if data else None

        if release is None and film is None:
            self._set_state(album_id, "notFound", "Not found on MusicBrainz or Wikidata.")
            return
        unsure = (release is not None and not sure_release) or (film is not None and not sure_film)
        found = self._found(home, release, rscore, film, fscore, cover_id)
        if unsure:
            candidate = {
                "found": found,
                "release": asdict(release) if release else None,
                "film": asdict(film) if film else None,
                "artworkId": cover_id,
                "via": via,
            }
            with self.lock, Session(self.db.engine) as s:
                a = s.get(Album, album_id)
                if a is None:
                    return
                a.lookup_state = "review"
                a.lookup_candidate = json.dumps(candidate)
                a.lookup_note = "Found something that might be it: check it in Hive Admin."
                a.lookup_at = _now()
                s.commit()
            return
        with self.lock, Session(self.db.engine) as s:
            a = s.get(Album, album_id)
            if a is None:
                return
            note = apply(s, a, release, film, cover_id, title_too=via == "fingerprint")
            a.lookup_state = "found"
            a.lookup_note = note
            a.lookup_candidate = None
            a.lookup_at = _now()
            s.commit()

    def _find_release(
        self, home: M.HomeAlbum, mbid: str | None, paths: list[str]
    ) -> tuple[S.MbRelease | None, float, str]:
        if mbid:
            rel = S.mb_release(self.http, mbid)
            if rel is not None:
                return rel, max(0.9, M.release_score(home, rel)), "tags"
        title = M.clean_title(home.title)
        if title in ("", "Unknown album"):
            heads: list[S.MbRelease] = []
        else:
            various = T.name_key(home.artist) in ("various artists", "various")
            heads = S.mb_search(self.http, title, None if various else home.artist)
            if not heads and not various:
                heads = S.mb_search(self.http, title, None)
        best: tuple[S.MbRelease | None, float] = (None, 0.0)
        ranked = sorted(heads, key=lambda r: -(M.release_score(home, r) + r.score / 1000))
        for head in ranked[:2]:
            if M.release_score(home, head) < 0.35:
                continue
            full = S.mb_release(self.http, head.id)
            if full is None:
                continue
            sc = M.release_score(home, full)
            if sc > best[1]:
                best = (full, sc)
        if best[1] >= M.FOUND or not self.acoustid_key or not self.fpcalc:
            return best[0], best[1], "name"
        # Recognise the songs by their sound.
        votes: dict[str, float] = {}
        for p in paths:
            fp = S.fingerprint(self.fpcalc, Path(p))
            if fp is None:
                continue
            for rid, score in S.acoustid_releases(self.http, self.acoustid_key, *fp):
                votes[rid] = votes.get(rid, 0.0) + score
        for rid, _ in sorted(votes.items(), key=lambda kv: -kv[1])[:2]:
            full = S.mb_release(self.http, rid)
            if full is None:
                continue
            paired = len(M.pair_tracks(home, full)) / max(1, len(home.tracks))
            sc = max(M.release_score(home, full), 0.6 + 0.4 * paired)
            if sc > best[1]:
                best = (full, sc)
        return best[0], best[1], "fingerprint" if best[0] and best[0].id in votes else "name"

    def _find_film(
        self, home: M.HomeAlbum, release: S.MbRelease | None
    ) -> tuple[S.Film | None, float]:
        language = home.language
        if release is not None and release.language:
            language = L.from_iso3(release.language) or language
        looks_like_film = (release is not None and release.kind == "soundtrack") or (
            language in INDIAN
        )
        if not looks_like_film:
            return None, 0.0
        lang_qid = L.LANGUAGES[language].wikidata if language in L.LANGUAGES else None
        ids: list[str] = []
        linked: str | None = None
        if release is not None and release.release_group_id:
            linked = S.mb_release_group_wikidata(self.http, release.release_group_id)
            if linked:
                ids.append(linked)
        title = M.clean_title(home.title)
        if title and title != "Unknown album":
            for hit in S.wikidata_search(self.http, title):
                desc = (hit.get("description") or "").lower()
                if "film" in desc or "movie" in desc:
                    ids.append(hit["id"])
        ids = list(dict.fromkeys(ids))[:8]
        if not ids:
            return None, 0.0
        films = S.wikidata_films(self.http, ids)
        scored = [(f, M.film_score(home, f, lang_qid)) for f in films]
        # A film MusicBrainz itself links to the soundtrack is as good as found.
        scored = [(f, max(sc, 0.9) if f.qid == linked else sc) for f, sc in scored]
        if not scored:
            return None, 0.0
        return max(scored, key=lambda fs: fs[1])

    def _found(
        self,
        home: M.HomeAlbum,
        release: S.MbRelease | None,
        rscore: float,
        film: S.Film | None,
        fscore: float,
        cover_id: str | None,
    ) -> dict[str, Any]:
        """The FoundAlbum body for review in Hive Admin."""
        body: dict[str, Any] = {
            "title": release.title if release else home.title,
            "artistName": release.artist if release else home.artist,
            "score": round(min(rscore if release else 1.0, fscore if film else 1.0), 3),
            "source": " · ".join(
                x for x in ("MusicBrainz" if release else "", "Wikidata" if film else "") if x
            ),
        }
        year = (release.year if release else None) or (film.year if film else None)
        if year:
            body["year"] = year
        lang = L.from_iso3(release.language) if release and release.language else None
        if not lang and film:
            lang = next((L.BY_WIKIDATA[q] for q in film.language_qids if q in L.BY_WIKIDATA), None)
        if lang:
            body["language"] = lang
        if release:
            body["kind"] = release.kind
            body["trackCount"] = release.track_count
            body["link"] = f"https://musicbrainz.org/release/{release.id}"
        if film:
            body["film"] = {"title": film.title, "wikidataId": film.qid}
            if film.year:
                body["film"]["year"] = film.year
            body.setdefault("kind", "soundtrack")
            body.setdefault("link", f"https://www.wikidata.org/wiki/{film.qid}")
            credits = [{"role": "director", "name": n} for n in film.directors]
            credits += [{"role": "musicDirector", "name": n} for n in film.composers]
            credits += [{"role": "actor", "name": n} for n in film.cast]
            if credits:
                body["credits"] = credits
        if cover_id:
            body["artworkId"] = cover_id
        return body

    # ------------------------------------------------------------ review
    def decide(self, album_id: str, accept: bool) -> bool:
        """Apply or drop the match waiting for review. False if none is waiting."""
        with self.lock, Session(self.db.engine) as s:
            a = s.get(Album, album_id)
            if a is None or a.lookup_state != "review" or not a.lookup_candidate:
                return False
            if not accept:
                a.lookup_state = "notFound"
                a.lookup_note = "You said the match found wasn't this album."
            else:
                c = json.loads(a.lookup_candidate)
                release = _release_from(c.get("release"))
                film = S.Film(**c["film"]) if c.get("film") else None
                a.lookup_note = apply(
                    s, a, release, film, c.get("artworkId"), title_too=c.get("via") == "fingerprint"
                )
                a.lookup_state = "found"
            a.lookup_candidate = None
            a.lookup_at = _now()
            s.commit()
            return True

    def retry(self, album_ids: list[str] | None, everything: bool) -> int:
        with self.lock, Session(self.db.engine) as s:
            q = s.query(Album)
            if album_ids:
                q = q.filter(Album.id.in_(album_ids))
            elif everything:
                q = q.filter(Album.lookup_state.in_(("notFound", "failed")))
            else:
                return 0
            n = q.update(
                {"lookup_state": "waiting", "lookup_note": None}, synchronize_session=False
            )
            s.commit()
        self.wake()
        return n

    def status(self) -> dict[str, Any]:
        with Session(self.db.engine) as s:
            counts: dict[str, int] = {
                state: n
                for state, n in s.execute(
                    select(Album.lookup_state, func.count()).group_by(Album.lookup_state)
                )
            }
            edited = s.scalar(
                select(func.count()).select_from(Album).where(Album.overrides != "{}")
            )
        key = bool(self.acoustid_key)
        body: dict[str, Any] = {
            "enabled": self.enabled,
            "acoustidKey": key,
            "fingerprinting": self.fpcalc is not None,
            "working": self.working,
            "waiting": counts.get("waiting", 0) + counts.get("working", 0),
            "found": counts.get("found", 0),
            "notFound": counts.get("notFound", 0),
            "review": counts.get("review", 0),
            "failed": counts.get("failed", 0),
            "edited": edited or 0,
            "sends": SENDS.format(
                fp=", and fingerprints of songs with no useful tags go to AcoustID"
                if key and self.fpcalc
                else ""
            ),
        }
        if self.last_error:
            body["lastError"] = self.last_error
        return body


def _release_from(data: dict[str, Any] | None) -> S.MbRelease | None:
    if not data:
        return None
    tracks = [S.MbTrack(**t) for t in data.pop("tracks", [])]
    return S.MbRelease(**data, tracks=tracks)


def apply(
    s: Session,
    album: Album,
    release: S.MbRelease | None,
    film: S.Film | None,
    cover_id: str | None,
    title_too: bool = False,
) -> str:
    """Fill the album in from what was found; returns a note of what changed.

    Never overrides what you set in Hive Admin, nor the files' own album-artist
    and language tags."""
    done: list[str] = []
    tracks = s.scalars(
        select(Track)
        .where(Track.album_id == album.id)
        .order_by(func.coalesce(Track.disc_no, 1), func.coalesce(Track.track_no, 999))
    ).all()
    if release is not None:
        album.mbid_release = release.id
        album.mbid_release_group = release.release_group_id
        album.kind = release.kind
        if (title_too or album.title == "Unknown album") and C.may_set(album, "title", "lookup"):
            album.title = release.title
            C.set_source(album, "title", "lookup")
        if album.year is None and release.year:
            album.year = release.year
            C.set_source(album, "year", "lookup")
        various = T.name_key(album.artist_name) in ("various artists", "unknown artist")
        if (
            (various or release.kind == "soundtrack")
            and C.may_set(album, "artistName", "lookup")
            and release.artist
            and T.name_key(release.artist) != T.name_key(album.artist_name)
        ):
            album.artist_name = release.artist
            album.artist_id = C.artist_row(s, T.primary_artist(release.artist)).id
            C.set_source(album, "artistName", "lookup")
        lang = L.from_iso3(release.language) if release.language else None
        if lang and C.may_set(album, "language", "lookup"):
            album.language = lang
            C.set_source(album, "language", "lookup")
        if release.kind == "soundtrack" and release.artist:
            C.set_album_credits(s, album, "musicDirector", C.people(release.artist))
        home = M.HomeAlbum(
            album.id, album.title, album.artist_name, album.year, album.language, True,
            [M.HomeTrack(t.title, t.duration_ms, t.track_no, t.disc_no, t.artist_name)
             for t in tracks],
        )  # fmt: skip
        for i, j in M.pair_tracks(home, release).items():
            t, rt = tracks[i], release.tracks[j]
            t.mbid_recording = t.mbid_recording or rt.recording_id
            if t.track_no is None:
                t.track_no, t.disc_no = rt.position, rt.disc
            if not t.composer and rt.composers:
                t.composer = ", ".join(rt.composers)
            if not t.lyricist and rt.lyricists:
                t.lyricist = ", ".join(rt.lyricists)
            s.execute(delete(Credit).where(Credit.track_id == t.id, Credit.source == "lookup"))
            for role, names in (("composer", rt.composers), ("lyricist", rt.lyricists)):
                for k, name in enumerate(names):
                    s.add(
                        Credit(
                            track_id=t.id,
                            artist_id=C.artist_row(s, name).id,
                            role=role,
                            position=k,
                            source="lookup",
                        )
                    )
        done.append("album details from MusicBrainz")
    if film is not None:
        album.film_title = film.title
        album.film_year = film.year
        album.film_wikidata = film.qid
        album.kind = album.kind or "soundtrack"
        if album.year is None and film.year:
            album.year = film.year
            C.set_source(album, "year", "lookup")
        lang = next((L.BY_WIKIDATA[q] for q in film.language_qids if q in L.BY_WIKIDATA), None)
        if lang and not album.language and C.may_set(album, "language", "lookup"):
            album.language = lang
            C.set_source(album, "language", "lookup")
        C.set_album_credits(s, album, "director", film.directors)
        C.set_album_credits(s, album, "actor", film.cast)
        if film.composers:
            C.set_album_credits(s, album, "musicDirector", film.composers)
        done.append("film, cast and director from Wikidata")
    # A cover only where there's none, or to replace an earlier looked-up one.
    if cover_id and (not album.artwork_id or C.sources(album).get("artwork") == "lookup"):
        album.artwork_id = cover_id
        C.set_source(album, "artwork", "lookup")
        for t in tracks:
            t.artwork_id = t.artwork_id or cover_id
        done.append("cover from Cover Art Archive")
    s.flush()
    # The same release found for two albums at home: they're one album.
    if release is not None:
        twins = s.scalars(
            select(Album).where(Album.mbid_release == release.id, Album.id != album.id)
        ).all()
        for twin in twins:
            C.merge_albums(s, album, twin)
            done.append("joined with another copy of the album")
    C.refresh_language(s, album)
    C.apply_overrides(album)
    C.refresh_search(s, album)
    return "Added " + ", ".join(done) + "." if done else "Nothing new to add."
