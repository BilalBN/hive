"""System endpoints: health and server identity."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Literal

from fastapi import APIRouter, Request
from pydantic import BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel

from hive import __version__
from hive.contract import load_contract

router = APIRouter(prefix="/api/v1", tags=["system"])


class ApiModel(BaseModel):
    """Base for API bodies: snake_case in Python, camelCase on the wire."""

    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)


class Health(ApiModel):
    status: Literal["ok"] = "ok"
    home_name: str
    server_version: str
    api_version: str
    min_app_version: str | None = None
    access: Literal["developmentKey", "invites"] = "developmentKey"
    server_time: datetime = Field(default_factory=lambda: datetime.now(UTC))


@router.get("/health", response_model=Health, response_model_by_alias=True)
async def get_health(request: Request) -> Health:
    settings = request.app.state.settings
    people = request.app.state.people
    return Health(
        home_name=people.home.home_name,
        server_version=__version__,
        api_version=load_contract()["info"]["version"],
        min_app_version=people.home.get("min_app_version") or settings.min_app_version,
        access="invites" if people.admin_exists() else "developmentKey",
    )
