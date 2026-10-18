import { describe, expect, it } from "vitest";

import { formatBytes, groupFiles, isAccepted, type QueuedFile, type SenderFactory, UploadQueue } from "./queue";

function file(name: string, size = 1000): File {
  return new File([new Uint8Array(size)], name);
}

function manualSender() {
  const started: Array<{ name: string; finish: () => void; fail: (m: string) => void; progress: (n: number) => void }> = [];
  const factory: SenderFactory = (f, events) => ({
    start: () =>
      started.push({ name: f.relativePath, finish: events.done, fail: events.failed, progress: events.progress }),
    abort: () => {},
  });
  return { factory, started };
}

describe("upload queue", () => {
  it("accepts audio, covers and lyrics, and skips the rest", () => {
    expect(isAccepted("01 Song.FLAC")).toBe(true);
    expect(isAccepted("cover.jpg")).toBe(true);
    expect(isAccepted("song.lrc")).toBe(true);
    expect(isAccepted("setup.exe")).toBe(false);
  });

  it("groups files by album folder", () => {
    const files: QueuedFile[] = [
      { id: 1, file: file("01.flac"), relativePath: "Thalapathi (1991)/01.flac", status: "waiting", sent: 0 },
      { id: 2, file: file("02.flac"), relativePath: "Thalapathi (1991)/02.flac", status: "waiting", sent: 0 },
      { id: 3, file: file("cover.jpg"), relativePath: "Thalapathi (1991)/cover.jpg", status: "waiting", sent: 0 },
      { id: 4, file: file("single.mp3"), relativePath: "single.mp3", status: "waiting", sent: 0 },
    ];
    const groups = groupFiles(files);
    expect(groups.map((g) => g.title)).toEqual(["Thalapathi (1991)", "single.mp3"]);
    expect(groups[0].meta).toBe("2 files · FLAC");
    expect(groups[0].totalBytes).toBe(3000);
    expect(groups[1].meta).toBe("MP3");
  });

  it("sends one file at a time and reports progress per album", () => {
    const { factory, started } = manualSender();
    let finished = 0;
    const q = new UploadQueue(factory, () => (finished += 1));
    q.add([
      { file: file("01.flac"), path: "Album/01.flac" },
      { file: file("02.flac"), path: "Album/02.flac" },
      { file: file("notes.exe"), path: "notes.exe" },
    ]);
    expect(started.map((s) => s.name)).toEqual(["Album/01.flac"]);
    let [album, skipped] = q.getSnapshot();
    expect(album.status).toBe("uploading");
    expect(album.current).toBe(1);
    expect(skipped.status).toBe("skipped");
    expect(skipped.meta).toBe("Unsupported file type");

    started[0].progress(500);
    expect(q.getSnapshot()[0].sentBytes).toBe(500);
    started[0].finish();
    expect(started.map((s) => s.name)).toEqual(["Album/01.flac", "Album/02.flac"]);
    expect(q.getSnapshot()[0].current).toBe(2);
    started[1].finish();
    [album] = q.getSnapshot();
    expect(album.status).toBe("done");
    expect(album.sentBytes).toBe(2000);
    expect(finished).toBe(2);
  });

  it("cancels an album and moves on", () => {
    const { factory, started } = manualSender();
    const q = new UploadQueue(factory);
    q.add([
      { file: file("01.flac"), path: "A/01.flac" },
      { file: file("02.flac"), path: "A/02.flac" },
      { file: file("x.mp3"), path: "B/x.mp3" },
    ]);
    q.cancel(q.getSnapshot()[0].key);
    expect(q.getSnapshot()[0].status).toBe("cancelled");
    expect(started.map((s) => s.name)).toEqual(["A/01.flac", "B/x.mp3"]);
  });

  it("keeps going after a failure and says why", () => {
    const { factory, started } = manualSender();
    const q = new UploadQueue(factory);
    q.add([
      { file: file("a.flac"), path: "a.flac" },
      { file: file("b.flac"), path: "b.flac" },
    ]);
    started[0].fail("The file is larger than the upload limit");
    const [a, b] = q.getSnapshot();
    expect(a.status).toBe("failed");
    expect(b.status).toBe("uploading");
    q.clearFinished();
    expect(q.getSnapshot().map((g) => g.title)).toEqual(["b.flac"]);
  });

  it("formats sizes", () => {
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(84 * 1024)).toBe("84 KB");
    expect(formatBytes(1.9 * 1024 ** 3)).toBe("1.9 GB");
    expect(formatBytes(290 * 1024 ** 2)).toBe("290 MB");
  });
});
