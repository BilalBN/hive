"""Builds the FastAPI application."""

from __future__ import annotations

import logging
import secrets
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session
from starlette.exceptions import HTTPException as StarletteHTTPException

from hive import __version__
from hive.admin_site import mount_admin
from hive.auth import development_key, ticket_secret
from hive.backups import Backups, finish_pending_restore
from hive.backups_api import router as backups_router
from hive.config import Settings, get_settings
from hive.contract import contract_path, load_contract, problem, register_unbuilt_operations
from hive.db import Database, migrate
from hive.library.admin_api import router as admin_library_router
from hive.library.api import router as library_router
from hive.library.editor_api import router as editor_router
from hive.library.listen_api import admin_router as listen_admin_router
from hive.library.listen_api import router as listen_router
from hive.library.lookup.http import Http
from hive.library.lookup.service import LookupService
from hive.library.media_api import router as media_router
from hive.library.recognition import Recognition
from hive.library.scanner import Library
from hive.library.sync_api import router as sync_router
from hive.library.uploads import router as uploads_router
from hive.models import AuditEntry
from hive.people.admin_api import router as people_admin_router
from hive.people.api import router as people_router
from hive.people.service import People, Problem
from hive.people.settings import HomeSettings
from hive.system import router as system_router
from hive.watch import Watch, keep_recent_lines
from hive.watch_api import router as watch_router

log = logging.getLogger("hive.server")


def create_app(settings: Settings | None = None, lookup_http: Http | None = None) -> FastAPI:
    """[lookup_http] lets tests answer the online lookup themselves."""
    settings = settings or get_settings()
    keep_recent_lines()  # for Hive Admin → Logs

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        settings.data_dir.mkdir(parents=True, exist_ok=True)
        restored = finish_pending_restore(settings)
        migrate(settings.database_url)
        app.state.db = Database(settings.database_url, settings.database_path)
        app.state.dev_key = development_key(app.state.db)
        app.state.ticket_secret = ticket_secret(app.state.db)
        home = HomeSettings(app.state.db, settings.home_name)
        app.state.people = People(app.state.db, home)
        app.state.backups = Backups(settings, home)
        if restored:
            at = datetime.now(UTC).isoformat().replace("+00:00", "Z")
            home.set("backup_restored", f"{restored}|{at}")
            with Session(app.state.db.engine) as s:
                s.add(
                    AuditEntry(
                        actor="Hive",
                        action="backup.restored",
                        text=f"Hive restored the backup {restored}.",
                    )
                )
                s.commit()
        if settings.backup_worker:
            app.state.backups.start()
        app.state.started_at = datetime.now(UTC)
        app.state.watch = Watch(app)
        if settings.watch_worker:
            app.state.watch.start()
        app.state.library = Library(settings, app.state.db)
        app.state.library.start()
        app.state.lookup = LookupService(
            settings,
            app.state.db,
            app.state.library.artwork,
            app.state.library._write_lock,
            http=lookup_http,
            requeue=lambda path: app.state.library.enqueue(path, force=True),
        )
        if settings.lookup_worker:
            app.state.lookup.start()
        app.state.recognition = Recognition(
            app.state.db, settings.data_dir, app.state.library.ffmpeg
        )
        if settings.fingerprint_worker:
            app.state.recognition.start()
        log.info("Hive %s started for %s", __version__, settings.home_name)
        if app.state.people.admin_exists():
            log.info("apps join with invites and email codes (Hive Admin → Requests)")
        else:
            log.info(
                "development key for the apps (until an admin is set up): %s", app.state.dev_key
            )
            raw = secrets.token_hex(4).upper()
            app.state.setup_code = f"{raw[:4]}-{raw[4:]}"
            log.info(
                "set up the first admin in Hive Admin on this computer, or from another one "
                "with the setup code %s",
                app.state.setup_code,
            )
        yield
        app.state.lookup.stop()
        app.state.recognition.stop()
        app.state.backups.stop()
        app.state.watch.stop()
        app.state.library.stop()
        app.state.db.engine.dispose()
        log.info("Hive stopped")

    app = FastAPI(
        title="Hive",
        version=__version__,
        lifespan=lifespan,
        # The contract file is the API description; FastAPI's own is not published.
        openapi_url=None,
        docs_url=None,
        redoc_url=None,
    )
    app.state.settings = settings

    app.include_router(system_router)
    app.include_router(people_router)
    app.include_router(people_admin_router)
    app.include_router(library_router)
    app.include_router(media_router)
    app.include_router(admin_library_router)
    app.include_router(uploads_router)
    app.include_router(backups_router)
    app.include_router(watch_router)
    app.include_router(sync_router)
    app.include_router(editor_router)
    app.include_router(listen_router)
    app.include_router(listen_admin_router)
    register_unbuilt_operations(app, load_contract())

    @app.get("/api/openapi.yaml", include_in_schema=False)
    async def contract() -> FileResponse:
        return FileResponse(contract_path(), media_type="application/yaml")

    @app.exception_handler(StarletteHTTPException)
    async def http_error(request: Request, exc: StarletteHTTPException):
        if request.url.path.startswith("/api/"):
            titles = {
                400: "Bad request", 401: "Sign-in needed", 403: "Not allowed", 404: "Not found",
                409: "Conflict", 412: "Precondition failed", 413: "Too large",
                415: "Not supported", 416: "Range not satisfiable", 422: "Invalid request",
                503: "Not available right now",
            }  # fmt: skip
            title = titles.get(exc.status_code, str(exc.detail))
            detail = str(exc.detail) if exc.detail and str(exc.detail) != title else None
            headers = getattr(exc, "headers", None)
            response = problem(exc.status_code, title, detail)
            if headers:
                response.headers.update(headers)
            return response
        from fastapi.exception_handlers import http_exception_handler

        return await http_exception_handler(request, exc)

    @app.exception_handler(Problem)
    async def people_problem(request: Request, exc: Problem):
        return problem(exc.status, exc.title, exc.detail, **exc.extra)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, exc: RequestValidationError):
        return problem(422, "Invalid request", errors=exc.errors())

    mount_admin(app, settings.admin_dist)
    return app
