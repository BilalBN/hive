# PyInstaller recipe for hive.exe: the server with Python inside, so the home
# PC needs nothing installed. Built by build.ps1.
# ruff: noqa
import os

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

root = os.path.abspath(os.path.join(SPECPATH, "..", ".."))
server = os.path.join(root, "server")

hidden = (
    # The migrations are run by Alembic from their files (added below), not imported.
    collect_submodules("hive", filter=lambda name: not name.startswith("hive.migrations"))
    + collect_submodules("uvicorn")
    + collect_submodules("alembic")
    + collect_submodules("watchdog")
    + collect_submodules("sqlalchemy.dialects.sqlite")
)
datas = [
    (os.path.join(server, "hive", "migrations"), os.path.join("hive", "migrations")),
    (os.path.join(root, "api", "openapi.yaml"), "hive"),
] + collect_data_files("alembic")

a = Analysis(
    [os.path.join(SPECPATH, "hive_entry.py")],
    pathex=[server],
    hiddenimports=hidden,
    datas=datas,
    excludes=["tkinter", "pytest", "IPython"],
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="hive",
    console=True,
    icon=os.path.join(root, "app", "windows", "runner", "resources", "app_icon.ico"),
)
coll = COLLECT(exe, a.binaries, a.datas, name="hive")
