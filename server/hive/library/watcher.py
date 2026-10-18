"""Folder watcher: files copied into a music folder are picked up on their own."""

from __future__ import annotations

import threading
from pathlib import Path
from typing import TYPE_CHECKING

from watchdog.events import FileSystemEvent, FileSystemEventHandler

from hive.library.tags import IMAGE_EXTENSIONS, is_audio

if TYPE_CHECKING:
    from hive.library.scanner import Library


class FolderEvents(FileSystemEventHandler):
    def __init__(self, library: Library) -> None:
        self.library = library
        self._rescan: threading.Timer | None = None
        self._lock = threading.Lock()

    def _queue(self, path: str) -> None:
        p = Path(path)
        if p.suffix.lower() in IMAGE_EXTENSIONS:
            self.library.picture_added(p.parent)
            return
        if is_audio(p):
            # Enqueue even while the copy is still running; the worker waits for
            # the file to settle before reading it.
            self.library.enqueue(p, force=True)

    def _rescan_soon(self) -> None:
        # A folder moved or deleted: one rescan covers everything inside it.
        with self._lock:
            if self._rescan is not None:
                self._rescan.cancel()
            self._rescan = threading.Timer(3.0, self.library.scan)
            self._rescan.daemon = True
            self._rescan.start()

    def on_created(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            self._rescan_soon()
        else:
            self._queue(str(event.src_path))

    def on_modified(self, event: FileSystemEvent) -> None:
        if not event.is_directory:
            self._queue(str(event.src_path))

    def on_moved(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            self._rescan_soon()
            return
        if is_audio(Path(str(event.src_path))):
            self.library.forget(Path(str(event.src_path)))
        self._queue(str(event.dest_path))

    def on_deleted(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            self._rescan_soon()
        elif is_audio(Path(str(event.src_path))):
            self.library.forget(Path(str(event.src_path)))
