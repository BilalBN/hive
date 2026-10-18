"""Builds the FastAPI application."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from hive import __version__
from hive.admin_site import mount_admin
from hive.config import Settings, get_settings
from hive.contract import contract_path, load_contract, problem, register_unbuilt_operations
from hive.db import Database, migrate
from hive.system import router as system_router

log = logging.getLogger("hive.server")


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        settings.data_dir.mkdir(parents=True, exist_ok=True)
        migrate(settings.database_url)
        app.state.db = Database(settings.database_url, settings.database_path)
        log.info("Hive %s started for %s", __version__, settings.home_name)
        yield
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
    register_unbuilt_operations(app, load_contract())

    @app.get("/api/openapi.yaml", include_in_schema=False)
    async def contract() -> FileResponse:
        return FileResponse(contract_path(), media_type="application/yaml")

    @app.exception_handler(StarletteHTTPException)
    async def http_error(request: Request, exc: StarletteHTTPException):
        if request.url.path.startswith("/api/"):
            title = "Not found" if exc.status_code == 404 else str(exc.detail)
            return problem(exc.status_code, title)
        from fastapi.exception_handlers import http_exception_handler

        return await http_exception_handler(request, exc)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, exc: RequestValidationError):
        return problem(422, "Invalid request", errors=exc.errors())

    mount_admin(app, settings.admin_dist)
    return app
