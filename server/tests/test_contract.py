"""The server and api/openapi.yaml must never drift apart."""

from __future__ import annotations

import re

import jsonschema
import pytest
from openapi_spec_validator import validate

from hive.app import create_app
from hive.contract import contract_operations, implemented_routes, load_contract


def test_contract_is_valid_openapi() -> None:
    validate(load_contract())


def test_every_operation_has_unique_id_and_milestone() -> None:
    ops = contract_operations(load_contract())
    ids = [op["operationId"] for op in ops.values()]
    assert len(ids) == len(set(ids))
    for (path, method), op in ops.items():
        assert re.fullmatch(r"M[0-6](\.5)?", op.get("x-milestone", "")), f"{method} {path}"


def test_server_routes_match_contract_exactly(settings) -> None:
    app = create_app(settings)
    contract = set(contract_operations(load_contract()))
    served = implemented_routes(app)
    assert served == contract, {
        "in contract, not served": sorted(contract - served),
        "served, not in contract": sorted(served - contract),
    }


def test_health_matches_contract_schema(client) -> None:
    spec = load_contract()
    schema = spec["components"]["schemas"]["Health"]
    body = client.get("/api/v1/health").json()
    jsonschema.validate(body, schema, format_checker=jsonschema.FormatChecker())


@pytest.mark.parametrize(
    ("method", "path", "milestone"),
    [
        ("get", "/api/v1/admin/backups", "M4"),
        ("post", "/api/v1/admin/session/passkey/options", "M6"),
        ("post", "/api/v1/listen/match", "M3"),
        ("get", "/api/v1/sync/session", "M4"),
    ],
)
def test_unbuilt_operations_say_when(client, method, path, milestone) -> None:
    r = client.request(method, path)
    assert r.status_code == 501
    assert r.headers["content-type"].startswith("application/problem+json")
    body = r.json()
    assert body["milestone"] == milestone
    assert body["status"] == 501


def test_unknown_api_path_is_problem_404(client) -> None:
    r = client.get("/api/v1/nope")
    assert r.status_code == 404
    assert r.headers["content-type"].startswith("application/problem+json")


def test_contract_file_is_served(client) -> None:
    r = client.get("/api/openapi.yaml")
    assert r.status_code == 200
    assert "Hive API" in r.text
