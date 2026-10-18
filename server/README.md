# Hive server

The home server: a Python (FastAPI) app that holds the library, decides who gets
in, and streams music to the family's devices over the private network.

## Run it for development

Needs Python 3.12 or newer.

```sh
cd server
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"      # Windows: .venv\Scripts\pip
.venv/bin/python -m hive serve          # http://127.0.0.1:8443
.venv/bin/python -m pytest              # tests
```

Settings live in `data/hive.toml` at the repository root (copy
`hive.example.toml`). Set `host = "tailscale"` to let your phone reach it over
Tailscale; the server then listens on this computer and its Tailscale address
only.

## Layout

| Path | What it holds |
| --- | --- |
| `hive/app.py` | Builds the app, mounts Hive Admin at `/admin` |
| `hive/contract.py` | Loads `api/openapi.yaml`; anything not built yet answers 501 with its milestone |
| `hive/system.py` | `GET /api/v1/health` |
| `hive/config.py` | Settings (TOML file, `HIVE_*` environment variables) |
| `hive/db.py`, `hive/models.py`, `hive/migrations/` | SQLite in WAL mode, Alembic migrations run on start |
| `tests/` | pytest; `test_contract.py` keeps the server and the contract identical |
