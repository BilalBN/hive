import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, Info, Upload as UploadIcon, X } from "lucide-react";
import { type DragEvent, useMemo, useRef, useState, useSyncExternalStore } from "react";

import { Artwork } from "../components/Artwork";
import { QueryError } from "../components/QueryError";
import { formatBytes, type Group, filesFromDrop, type SenderFactory, tusSender, UploadQueue } from "../upload/queue";
import { libraryQuery } from "./Library";

function statusText(g: Group): string {
  switch (g.status) {
    case "uploading":
      return g.audioCount > 1 ? `Uploading ${g.current} of ${g.audioCount}` : "Uploading";
    case "waiting":
      return "Waiting";
    case "done":
      return "Uploaded · scanning";
    case "failed":
      return g.files.find((f) => f.status === "failed")?.error ?? "Upload failed";
    case "cancelled":
      return "Cancelled";
    case "skipped":
      return "Skipped";
  }
}

function GroupRow({ group, onCancel }: { group: Group; onCancel: () => void }) {
  const pct = group.totalBytes ? Math.round((group.sentBytes / group.totalBytes) * 100) : 0;
  const tone =
    group.status === "done" ? "success" : group.status === "failed" || group.status === "skipped" ? "danger" : "accent";
  const size =
    group.status === "uploading" || group.status === "waiting"
      ? `${formatBytes(group.sentBytes)} / ${formatBytes(group.totalBytes)}`
      : formatBytes(group.totalBytes);
  return (
    <li className="row upload-row">
      <Artwork title={group.title} size={40} />
      <div className="row__text">
        <p className="row__title">{group.title}</p>
        <p className="row__meta mono">{group.meta}</p>
      </div>
      <div className="upload-row__progress">
        <div className="upload-row__line">
          <span className={`upload-row__status upload-row__status--${tone}`}>{statusText(group)}</span>
          <span className="mono">{size}</span>
        </div>
        <div
          className={`progress progress--${tone}`}
          role="progressbar"
          aria-label={`${group.title} upload`}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={group.status === "skipped" ? 100 : pct}
        >
          <span style={{ width: `${group.status === "skipped" || group.status === "done" ? 100 : pct}%` }} />
        </div>
      </div>
      {group.status === "uploading" || group.status === "waiting" ? (
        <button className="icon-button" type="button" aria-label={`Cancel ${group.title}`} onClick={onCancel}>
          <X size={18} />
        </button>
      ) : group.status === "done" ? (
        <span className="icon-button icon-button--static" aria-hidden>
          <Check size={18} />
        </span>
      ) : (
        <span className="icon-button icon-button--static" title={statusText(group)} aria-hidden>
          <Info size={18} />
        </span>
      )}
    </li>
  );
}

export function UploadPage({ sender = tusSender }: { sender?: SenderFactory }) {
  const client = useQueryClient();
  const { data, error, refetch } = useQuery(libraryQuery);
  const queue = useMemo(
    () => new UploadQueue(sender, () => void client.invalidateQueries({ queryKey: libraryQuery.queryKey })),
    [sender, client],
  );
  const groups = useSyncExternalStore(queue.subscribe, queue.getSnapshot);
  const [over, setOver] = useState(false);
  const filesInput = useRef<HTMLInputElement>(null);
  const folderInput = useRef<HTMLInputElement>(null);

  async function onDrop(e: DragEvent) {
    e.preventDefault();
    setOver(false);
    const withPaths = e.dataTransfer.items?.length
      ? await filesFromDrop(e.dataTransfer.items)
      : Array.from(e.dataTransfer.files).map((file) => ({ file, path: file.name }));
    queue.add(withPaths);
  }

  const finished = groups.some((g) => !["uploading", "waiting"].includes(g.status));

  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Upload music</h1>
        <p className="page__summary">From this computer to {data ? "the home PC" : "home"}.</p>
      </header>

      {error && <QueryError error={error} retry={() => refetch()} />}

      <div
        className={`dropzone${over ? " dropzone--over" : ""}`}
        onDragOver={(e) => {
          e.preventDefault();
          setOver(true);
        }}
        onDragLeave={() => setOver(false)}
        onDrop={onDrop}
      >
        <UploadIcon size={28} aria-hidden className="dropzone__icon" />
        <p className="dropzone__title">Drop album folders or audio files here</p>
        <p className="dropzone__text">
          FLAC, ALAC, WAV, MP3, AAC, Opus · or{" "}
          <button type="button" className="link-button" onClick={() => filesInput.current?.click()}>
            choose files
          </button>{" "}
          ·{" "}
          <button type="button" className="link-button" onClick={() => folderInput.current?.click()}>
            choose a folder
          </button>
        </p>
        <input
          ref={filesInput}
          type="file"
          multiple
          hidden
          data-testid="choose-files"
          onChange={(e) => {
            queue.add(Array.from(e.target.files ?? []).map((file) => ({ file })));
            e.target.value = "";
          }}
        />
        <input
          ref={folderInput}
          type="file"
          multiple
          hidden
          // @ts-expect-error -- non-standard but supported by every current browser
          webkitdirectory=""
          onChange={(e) => {
            queue.add(Array.from(e.target.files ?? []).map((file) => ({ file, path: file.webkitRelativePath })));
            e.target.value = "";
          }}
        />
      </div>

      <p className="note">
        Saving to <span className="mono">{data?.uploadFolder ?? "…"}</span>. New files are scanned automatically when
        the upload finishes; a dropped connection picks up where it stopped.
      </p>

      {groups.length > 0 && (
        <section className="panel" aria-label="Uploads">
          <ul className="rows">
            {groups.map((g) => (
              <GroupRow key={g.key} group={g} onCancel={() => queue.cancel(g.key)} />
            ))}
          </ul>
          {finished && (
            <button className="button button--secondary panel__action" type="button" onClick={() => queue.clearFinished()}>
              Clear finished
            </button>
          )}
        </section>
      )}
    </section>
  );
}
