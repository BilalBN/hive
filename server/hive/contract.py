"""The API contract (api/openapi.yaml) and the routes it implies.

Every operation in the contract is reachable on the server. Operations whose
milestone hasn't been built yet answer ``501 Not Implemented`` with a Problem
body naming the milestone, so the apps can be written against the full API from
day one and the contract test can prove nothing drifts.
"""

from __future__ import annotations

import importlib.resources
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute

METHODS = ("get", "post", "put", "patch", "delete")
API_PREFIX = "/api/v1/"


def contract_path() -> Path:
    """The packaged copy when installed, otherwise the repository's api/openapi.yaml."""
    packaged = importlib.resources.files("hive").joinpath("openapi.yaml")
    if packaged.is_file():
        return Path(str(packaged))
    return Path(__file__).resolve().parents[2] / "api" / "openapi.yaml"


@lru_cache
def load_contract() -> dict[str, Any]:
    with contract_path().open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def contract_operations(spec: dict[str, Any]) -> dict[tuple[str, str], dict[str, Any]]:
    """{(path, METHOD): operation} for every operation in the contract."""
    ops: dict[tuple[str, str], dict[str, Any]] = {}
    for path, item in spec["paths"].items():
        for method in METHODS:
            if method in item:
                ops[(path, method.upper())] = item[method]
    return ops


def problem(status: int, title: str, detail: str | None = None, **extra: Any) -> JSONResponse:
    body: dict[str, Any] = {"type": "about:blank", "title": title, "status": status}
    if detail:
        body["detail"] = detail
    body.update(extra)
    return JSONResponse(body, status_code=status, media_type="application/problem+json")


def implemented_routes(app: FastAPI) -> set[tuple[str, str]]:
    found: set[tuple[str, str]] = set()
    for route in app.routes:
        if isinstance(route, APIRoute) and route.path.startswith(API_PREFIX):
            for m in route.methods or ():
                if m in ("HEAD", "OPTIONS"):
                    continue
                found.add((route.path, m))
    return found


def register_unbuilt_operations(app: FastAPI, spec: dict[str, Any]) -> list[str]:
    """Add a 501 handler for every contract operation the server doesn't implement yet."""
    built = implemented_routes(app)
    added: list[str] = []
    for (path, method), op in contract_operations(spec).items():
        if (path, method) in built:
            continue
        milestone = op.get("x-milestone", "a later milestone")
        operation_id = op["operationId"]

        async def not_built(
            request: Request, _id: str = operation_id, _ms: str = milestone
        ) -> JSONResponse:
            return problem(
                501,
                "Not built yet",
                f"{_id} arrives in {_ms}.",
                milestone=_ms,
                operationId=_id,
            )

        app.add_api_route(
            path,
            not_built,
            methods=[method],
            include_in_schema=False,
            name=f"unbuilt:{operation_id}",
        )
        added.append(operation_id)
    return added
