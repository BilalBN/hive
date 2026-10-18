"""Logging: readable lines on the console, the same lines in a rotating file.

Lines look like ``21:39:12.401 INFO  auth  device_request node=pixel-8``, which is
what Hive Admin's Logs page shows. Song titles are never logged at INFO.
"""

from __future__ import annotations

import logging
import logging.handlers
from pathlib import Path

FORMAT = "%(asctime)s.%(msecs)03d %(levelname)-5s %(area)-7s %(message)s"
DATEFMT = "%H:%M:%S"


class _AreaFilter(logging.Filter):
    """Adds ``area``: the part of the server a line comes from (auth, scan, stream...)."""

    def filter(self, record: logging.LogRecord) -> bool:
        if not hasattr(record, "area"):
            name = record.name
            record.area = name.split(".", 2)[1] if name.startswith("hive.") else name.split(".")[0]
        return True


def setup_logging(level: str, log_dir: Path | None) -> None:
    root = logging.getLogger()
    root.setLevel(level)
    for h in list(root.handlers):
        root.removeHandler(h)

    fmt = logging.Formatter(FORMAT, DATEFMT)
    area = _AreaFilter()

    console = logging.StreamHandler()
    console.setFormatter(fmt)
    console.addFilter(area)
    root.addHandler(console)

    if log_dir is not None:
        log_dir.mkdir(parents=True, exist_ok=True)
        file = logging.handlers.RotatingFileHandler(
            log_dir / "hive.log", maxBytes=5_000_000, backupCount=7, encoding="utf-8"
        )
        file.setFormatter(fmt)
        file.addFilter(area)
        root.addHandler(file)

    # Uvicorn's access log repeats every request; keep it for warnings only.
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    # Alembic is chatty at INFO; hive.db reports the outcome instead.
    logging.getLogger("alembic").setLevel(logging.WARNING)
