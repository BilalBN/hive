import { Upload } from "tus-js-client";

/** What the server accepts (see server/hive/library/uploads.py). */
export const AUDIO_EXTENSIONS = ["flac", "mp3", "m4a", "mp4", "aac", "ogg", "oga", "opus", "wav", "aif", "aiff"];
const EXTRA_EXTENSIONS = ["jpg", "jpeg", "png", "webp", "lrc"];

export type FileStatus = "waiting" | "uploading" | "done" | "failed" | "skipped" | "cancelled";

export interface QueuedFile {
  id: number;
  file: File;
  /** Path inside the dropped folder, e.g. "Thalapathi (1991)/01 Sundari.flac". */
  relativePath: string;
  status: FileStatus;
  sent: number;
  error?: string;
}

export interface Group {
  key: string;
  title: string;
  files: QueuedFile[];
  totalBytes: number;
  sentBytes: number;
  /** Summary shown under the title, e.g. "11 files · FLAC". */
  meta: string;
  status: "waiting" | "uploading" | "done" | "failed" | "skipped" | "cancelled";
  /** 1-based index of the file being sent, for "Uploading 7 of 11". */
  current: number;
  audioCount: number;
}

export function extensionOf(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot < 0 ? "" : name.slice(dot + 1).toLowerCase();
}

export function isAccepted(name: string): boolean {
  const ext = extensionOf(name);
  return AUDIO_EXTENSIONS.includes(ext) || EXTRA_EXTENSIONS.includes(ext);
}

function isAudio(name: string): boolean {
  return AUDIO_EXTENSIONS.includes(extensionOf(name));
}

function folderOf(path: string): string {
  const i = path.lastIndexOf("/");
  return i < 0 ? "" : path.slice(0, i);
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = n / 1024;
  let u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u += 1;
  }
  return `${v >= 100 || u === 0 ? Math.round(v) : v.toFixed(1)} ${units[u]}`;
}

/** Files grouped by the folder they came in (an album), single files on their own. */
export function groupFiles(files: QueuedFile[]): Group[] {
  const order: string[] = [];
  const byKey = new Map<string, QueuedFile[]>();
  for (const f of files) {
    const folder = folderOf(f.relativePath);
    const key = folder || `file:${f.relativePath}:${f.id}`;
    if (!byKey.has(key)) {
      byKey.set(key, []);
      order.push(key);
    }
    byKey.get(key)!.push(f);
  }
  return order.map((key) => {
    const list = byKey.get(key)!;
    const folder = folderOf(list[0].relativePath);
    const title = folder ? folder.split("/").pop()! : list[0].file.name;
    const totalBytes = list.reduce((n, f) => n + f.file.size, 0);
    const sentBytes = list.reduce((n, f) => n + (f.status === "done" ? f.file.size : f.sent), 0);
    const audio = list.filter((f) => isAudio(f.file.name));
    const exts = new Map<string, number>();
    for (const f of audio) exts.set(extensionOf(f.file.name), (exts.get(extensionOf(f.file.name)) ?? 0) + 1);
    const commonExt = [...exts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
    const skipped = list.every((f) => f.status === "skipped");
    let meta: string;
    if (skipped) meta = list[0].error ?? "Unsupported file type";
    else if (folder) meta = `${audio.length} ${audio.length === 1 ? "file" : "files"}${commonExt ? ` · ${commonExt.toUpperCase()}` : ""}`;
    else meta = commonExt ? commonExt.toUpperCase() : extensionOf(list[0].file.name).toUpperCase();

    const live = list.filter((f) => f.status !== "skipped");
    const status: Group["status"] = skipped
      ? "skipped"
      : live.some((f) => f.status === "uploading")
        ? "uploading"
        : live.some((f) => f.status === "failed")
          ? "failed"
          : live.every((f) => f.status === "done")
            ? "done"
            : live.every((f) => f.status === "cancelled" || f.status === "done")
              ? "cancelled"
              : "waiting";
    const uploadingIndex = live.findIndex((f) => f.status === "uploading");
    return {
      key,
      title,
      files: list,
      totalBytes,
      sentBytes,
      meta,
      status,
      current: uploadingIndex < 0 ? live.filter((f) => f.status === "done").length : uploadingIndex + 1,
      audioCount: live.length,
    };
  });
}

/** Read every file inside dropped folders (browsers hand them over in batches). */
export async function filesFromDrop(items: DataTransferItemList): Promise<Array<{ file: File; path: string }>> {
  const entries: FileSystemEntry[] = [];
  for (const item of Array.from(items)) {
    const entry = item.webkitGetAsEntry?.();
    if (entry) entries.push(entry);
  }
  const out: Array<{ file: File; path: string }> = [];
  async function walk(entry: FileSystemEntry): Promise<void> {
    if (entry.isFile) {
      const file = await new Promise<File>((resolve, reject) => (entry as FileSystemFileEntry).file(resolve, reject));
      out.push({ file, path: entry.fullPath.replace(/^\//, "") });
      return;
    }
    if (entry.isDirectory) {
      const reader = (entry as FileSystemDirectoryEntry).createReader();
      for (;;) {
        const batch = await new Promise<FileSystemEntry[]>((resolve, reject) => reader.readEntries(resolve, reject));
        if (batch.length === 0) break;
        for (const child of batch) await walk(child);
      }
    }
  }
  for (const e of entries) await walk(e);
  return out;
}

/** Something that sends one file; tus in the app, a fake in tests. */
export interface Sender {
  start(): void;
  abort(): void;
}

export type SenderFactory = (
  f: QueuedFile,
  events: { progress: (sent: number) => void; done: () => void; failed: (message: string) => void },
) => Sender;

export const tusSender: SenderFactory = (f, events) => {
  const upload = new Upload(f.file, {
    endpoint: "/api/v1/admin/uploads",
    chunkSize: 16 * 1024 * 1024,
    retryDelays: [0, 1000, 3000, 5000, 10000, 20000],
    metadata: { filename: f.file.name, relativePath: f.relativePath },
    removeFingerprintOnSuccess: true,
    onProgress: (sent) => events.progress(sent),
    onSuccess: () => events.done(),
    onError: (error) => {
      const body = (error as { originalResponse?: { getBody(): string } }).originalResponse?.getBody?.();
      let message = "Upload failed";
      try {
        const problem = body ? JSON.parse(body) : null;
        message = problem?.detail ?? problem?.title ?? message;
      } catch {
        /* not JSON */
      }
      events.failed(message);
    },
  });
  return {
    start: () => {
      // Resume a previous attempt of the same file when the browser remembers one.
      void upload.findPreviousUploads().then((previous) => {
        if (previous.length) upload.resumeFromPreviousUpload(previous[0]);
        upload.start();
      });
    },
    abort: () => void upload.abort(true),
  };
};

/** Sends files one at a time, in the order they were added. */
export class UploadQueue {
  private files: QueuedFile[] = [];
  private nextId = 1;
  private active: { id: number; sender: Sender } | null = null;
  private listeners = new Set<() => void>();
  private snapshot: Group[] = [];

  constructor(
    private readonly send: SenderFactory = tusSender,
    private readonly onFileDone: () => void = () => {},
  ) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): Group[] => this.snapshot;

  private changed(): void {
    this.snapshot = groupFiles(this.files);
    for (const l of this.listeners) l();
  }

  add(items: Array<{ file: File; path?: string }>): void {
    for (const { file, path } of items) {
      if (file.name.startsWith(".")) continue; // .DS_Store and friends
      const accepted = isAccepted(file.name);
      this.files.push({
        id: this.nextId++,
        file,
        relativePath: path || file.webkitRelativePath || file.name,
        status: accepted ? "waiting" : "skipped",
        sent: 0,
        error: accepted ? undefined : "Unsupported file type",
      });
    }
    this.changed();
    this.pump();
  }

  /** Stop a group: its waiting files are dropped and the one being sent is cancelled. */
  cancel(groupKey: string): void {
    const group = groupFiles(this.files).find((g) => g.key === groupKey);
    if (!group) return;
    for (const f of group.files) {
      if (f.status === "waiting") f.status = "cancelled";
      if (f.status === "uploading" && this.active?.id === f.id) {
        this.active.sender.abort();
        this.active = null;
        f.status = "cancelled";
      }
    }
    this.changed();
    this.pump();
  }

  /** Remove finished, skipped and cancelled groups from the list. */
  clearFinished(): void {
    this.files = this.files.filter((f) => f.status === "waiting" || f.status === "uploading");
    this.changed();
  }

  private pump(): void {
    if (this.active) return;
    const next = this.files.find((f) => f.status === "waiting");
    if (!next) return;
    next.status = "uploading";
    const sender = this.send(next, {
      progress: (sent) => {
        next.sent = sent;
        this.changed();
      },
      done: () => {
        next.status = "done";
        next.sent = next.file.size;
        this.active = null;
        this.changed();
        this.onFileDone();
        this.pump();
      },
      failed: (message) => {
        next.status = "failed";
        next.error = message;
        this.active = null;
        this.changed();
        this.pump();
      },
    });
    this.active = { id: next.id, sender };
    this.changed();
    sender.start();
  }
}
