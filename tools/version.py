#!/usr/bin/env python3
"""Hive's version, kept the same in the app, the server and Hive Admin.

    python3 tools/version.py            # show it
    python3 tools/version.py set 0.3.0  # change it everywhere (the app's build number goes up by one)
    python3 tools/version.py check v0.3.0   # CI: a release tag matches the code
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "app" / "pubspec.yaml"
SERVER = ROOT / "server" / "hive" / "__init__.py"
APP_INFO = ROOT / "app" / "lib" / "core" / "app_info.dart"
ADMIN = ROOT / "admin" / "package.json"
ADMIN_LOCK = ROOT / "admin" / "package-lock.json"
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def current() -> dict[str, str]:
    app = re.search(r"^version:\s*(\S+)", PUBSPEC.read_text(), re.M).group(1)
    server = re.search(r'__version__\s*=\s*"([^"]+)"', SERVER.read_text()).group(1)
    admin = json.loads(ADMIN.read_text())["version"]
    info = re.search(r"const appVersion = '([^']+)'", APP_INFO.read_text()).group(1)
    return {"app": app, "app_info": info, "server": server, "admin": admin}


def set_version(new: str) -> None:
    if not SEMVER.match(new):
        sys.exit(f"{new!r} isn't a version like 0.3.0")
    text = PUBSPEC.read_text()
    build = int(re.search(r"^version:\s*\S+\+(\d+)", text, re.M).group(1)) + 1
    PUBSPEC.write_text(re.sub(r"^version:\s*\S+", f"version: {new}+{build}", text, count=1, flags=re.M))
    APP_INFO.write_text(
        re.sub(r"const appVersion = '[^']+'", f"const appVersion = '{new}'", APP_INFO.read_text())
    )
    SERVER.write_text(re.sub(r'__version__\s*=\s*"[^"]+"', f'__version__ = "{new}"', SERVER.read_text()))
    for path in (ADMIN, ADMIN_LOCK):
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        data["version"] = new
        if path == ADMIN_LOCK and "" in data.get("packages", {}):
            data["packages"][""]["version"] = new
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(f"Hive {new} (app build {build})")


def check(tag: str) -> None:
    want = tag.removeprefix("refs/tags/").removeprefix("v")
    have = current()
    wrong = {k: v for k, v in have.items() if v.split("+")[0] != want}
    if wrong:
        sys.exit(
            f"The tag says {want} but " + ", ".join(f"the {k} says {v}" for k, v in wrong.items())
            + f". Run: python3 tools/version.py set {want}"
        )
    print(f"Hive {want}: app, server and Hive Admin agree")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        for k, v in current().items():
            print(f"{k:7} {v}")
    elif args[0] == "set" and len(args) == 2:
        set_version(args[1])
    elif args[0] == "check" and len(args) == 2:
        check(args[1])
    else:
        sys.exit(__doc__)
