"""Command line: ``hive serve``, ``hive migrate``, ``hive info``, ``hive backup``.

Run from the server folder with ``python -m hive serve`` (or ``hive serve`` once
installed).
"""

from __future__ import annotations

import argparse
import ipaddress
import logging
import shutil
import socket
import subprocess
import sys
from pathlib import Path

from hive import __version__
from hive.config import Settings, get_settings
from hive.logs import setup_logging

log = logging.getLogger("hive.server")

TAILSCALE_NET = ipaddress.ip_network("100.64.0.0/10")
TAILSCALE_CLIS = [
    "tailscale",
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    r"C:\Program Files\Tailscale\tailscale.exe",
]


def tailscale_ipv4() -> str | None:
    """This machine's Tailscale address, asked from the Tailscale command line."""
    for cli in TAILSCALE_CLIS:
        exe = shutil.which(cli) or (cli if Path(cli).is_file() else None)
        if not exe:
            continue
        try:
            out = subprocess.run(
                [exe, "ip", "-4"], capture_output=True, text=True, timeout=5, check=True
            ).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        for line in out.split():
            try:
                if ipaddress.ip_address(line) in TAILSCALE_NET:
                    return line
            except ValueError:
                continue
    return None


def resolve_hosts(host: str) -> list[str]:
    """Turn the ``host`` setting into concrete addresses to listen on."""
    if host != "tailscale":
        return [host]
    ip = tailscale_ipv4()
    if ip is None:
        sys.exit(
            "host is set to 'tailscale' but no Tailscale address was found. "
            "Is Tailscale running and signed in on this computer?"
        )
    return ["127.0.0.1", ip]


def bind_sockets(hosts: list[str], port: int) -> list[socket.socket]:
    socks = []
    for h in hosts:
        family = socket.AF_INET6 if ":" in h else socket.AF_INET
        s = socket.socket(family, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((h, port))
        s.listen(128)
        socks.append(s)
    return socks


def serve(settings: Settings) -> None:
    import uvicorn

    from hive.app import create_app

    hosts = resolve_hosts(settings.host)
    scheme = "https" if settings.tls_cert else "http"
    for h in hosts:
        log.info("listening on %s://%s:%d", scheme, h, settings.port)
    config = uvicorn.Config(
        create_app(settings),
        port=settings.port,
        ssl_certfile=str(settings.tls_cert) if settings.tls_cert else None,
        ssl_keyfile=str(settings.tls_key) if settings.tls_key else None,
        log_config=None,
        proxy_headers=False,
        server_header=False,
    )
    uvicorn.Server(config).run(sockets=bind_sockets(hosts, settings.port))


def backup(settings: Settings, kind: str) -> int:
    """A backup with the server stopped (the installer does this before an
    update). Nothing to back up on a new install is fine."""
    from hive.backups import BackupProblem, Backups
    from hive.db import Database
    from hive.people.settings import HomeSettings

    if not settings.database_path.exists():
        print("nothing to back up yet")
        return 0
    db = Database(settings.database_url, settings.database_path)
    try:
        item = Backups(settings, HomeSettings(db, settings.home_name)).run(kind)
    except BackupProblem as e:
        print(f"backup failed: {e}", file=sys.stderr)
        return 1
    print(f"backup made: {item['id']}")
    return 0


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="hive", description="Hive family music server")
    parser.add_argument("--version", action="version", version=f"hive {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)
    p_serve = sub.add_parser("serve", help="run the server")
    p_serve.add_argument("--host", help='address to listen on, or "tailscale"')
    p_serve.add_argument("--port", type=int)
    sub.add_parser("migrate", help="bring the database up to date")
    sub.add_parser("info", help="show the settings in use")
    p_backup = sub.add_parser("backup", help="make a backup now (as Hive Admin → Backups)")
    p_backup.add_argument("--kind", default="manual", choices=["manual", "before-update"])
    args = parser.parse_args(argv)

    settings = get_settings()
    overrides = {
        k: v
        for k, v in {"host": args.__dict__.get("host"), "port": args.__dict__.get("port")}.items()
        if v
    }
    if overrides:
        settings = settings.model_copy(update=overrides)
    setup_logging(settings.log_level, settings.log_dir)

    if args.command == "serve":
        serve(settings)
    elif args.command == "migrate":
        from hive.db import migrate

        settings.data_dir.mkdir(parents=True, exist_ok=True)
        migrate(settings.database_url)
    elif args.command == "backup":
        sys.exit(backup(settings, args.kind))
    elif args.command == "info":
        from hive.auth import development_key
        from hive.db import Database, migrate
        from hive.library.audio import find_ffmpeg

        for key, value in settings.model_dump().items():
            print(f"{key:20} {value}")
        print(f"{'database':20} {settings.database_path}")
        print(f"{'upload folder':20} {settings.uploads_path}")
        print(f"{'ffmpeg':20} {find_ffmpeg(settings.ffmpeg) or 'not found (brew install ffmpeg)'}")
        settings.data_dir.mkdir(parents=True, exist_ok=True)
        migrate(settings.database_url)
        print(f"{'development key':20} {development_key(Database(settings.database_url))}")


if __name__ == "__main__":
    main()
