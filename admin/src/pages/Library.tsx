import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Copy, CircleAlert, FolderOpen, Loader, RefreshCw, TriangleAlert } from "lucide-react";

import {
  deleteAllCopies,
  deleteCopy,
  fetchLibrary,
  ignoreImport,
  type ImportItem,
  type LibraryStatus,
  startScan,
} from "../api/client";
import { Artwork } from "../components/Artwork";
import { LookupPanel } from "../components/LookupPanel";
import { QueryError } from "../components/QueryError";
import { formatBytes } from "../upload/queue";

export const libraryQuery = {
  queryKey: ["library"],
  queryFn: fetchLibrary,
  // Poll quickly while files are being read, slowly otherwise.
  refetchInterval: (q: { state: { data?: LibraryStatus } }) => (q.state.data?.scanning ? 2000 : 15000),
} as const;

const number = new Intl.NumberFormat();

function playingTime(data: LibraryStatus): string {
  if (!data.tracks) return "No music yet";
  const hours = data.hoursOfMusic ?? 0;
  if (hours < 1) return "Under an hour of music";
  return `${hours} hours of music`;
}

function QueueRow({ item }: { item: ImportItem }) {
  const name = item.path.split(/[\\/]/).pop() ?? item.path;
  const folder = item.path.slice(0, item.path.length - name.length).replace(/[\\/]$/, "");
  return (
    <li className="row">
      <span className="row__icon" aria-hidden>
        {item.status === "working" ? <Loader size={16} className="spin" /> : <span className="dot dot--waiting" />}
      </span>
      <div className="row__text">
        <p className="row__title">{name}</p>
        <p className="row__meta mono">{folder || "—"}</p>
      </div>
      <span className="row__status">{item.status === "working" ? "Reading" : "Waiting"}</span>
    </li>
  );
}

function useLibraryAction<T>(fn: (arg: T) => Promise<LibraryStatus>) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: (status) => client.setQueryData(libraryQuery.queryKey, status),
  });
}

function ProblemRow({ item }: { item: ImportItem }) {
  const ignore = useLibraryAction(ignoreImport);
  return (
    <li className="row">
      <span className="row__icon row__icon--warning" aria-hidden>
        <TriangleAlert size={16} />
      </span>
      <div className="row__text">
        <p className="row__title mono">{item.path}</p>
        <p className="row__meta">{item.problem}</p>
        {ignore.error && <p className="row__meta row__meta--error">{ignore.error.message}</p>}
      </div>
      <button
        className="link-button"
        type="button"
        disabled={ignore.isPending}
        onClick={() => ignore.mutate(item.id)}
        aria-label={`Ignore ${item.path}`}
      >
        Ignore
      </button>
    </li>
  );
}

function CopyRow({ item }: { item: ImportItem }) {
  const remove = useLibraryAction(deleteCopy);
  const keep = useLibraryAction(ignoreImport);
  const error = remove.error ?? keep.error;
  return (
    <li className="row">
      <span className="row__icon" aria-hidden>
        <Copy size={16} />
      </span>
      <div className="row__text">
        <p className="row__title mono">{item.path}</p>
        <p className="row__meta">{item.problem}</p>
        {error && <p className="row__meta row__meta--error">{error.message}</p>}
      </div>
      <div className="actions">
        <button
          className="link-button"
          type="button"
          disabled={remove.isPending || keep.isPending}
          onClick={() => keep.mutate(item.id)}
          aria-label={`Keep ${item.path}`}
        >
          Keep
        </button>
        <button
          className="button button--secondary"
          type="button"
          disabled={remove.isPending || keep.isPending}
          onClick={() => remove.mutate(item.id)}
          aria-label={`Delete ${item.path}`}
        >
          Delete copy
        </button>
      </div>
    </li>
  );
}

function Duplicates({ items }: { items: ImportItem[] }) {
  const removeAll = useLibraryAction(deleteAllCopies);
  const n = items.length;
  return (
    <section className="panel" aria-labelledby="copies-h">
      <div className="panel__head">
        <h2 id="copies-h" className="panel__title">
          Duplicate copies · {number.format(n)}
        </h2>
        <button
          className="button button--secondary"
          type="button"
          disabled={removeAll.isPending}
          onClick={() => {
            const what = n === 1 ? "this copy" : `these ${number.format(n)} copies`;
            if (window.confirm(`Delete ${what} from the home computer? The songs stay in Hive.`)) {
              removeAll.mutate(undefined);
            }
          }}
        >
          {removeAll.isPending ? "Deleting…" : n === 1 ? "Delete copy" : "Delete all copies"}
        </button>
      </div>
      <p className="note">
        These files are exact copies of songs already in Hive, so they were skipped and nothing is missing. Deleting a copy
        removes only that file (Hive compares the two again first). Keep hides it from this list.
      </p>
      {removeAll.error && <p className="note note--error">{removeAll.error.message}</p>}
      <ul className="rows">
        {items.map((item) => (
          <CopyRow key={item.id} item={item} />
        ))}
      </ul>
    </section>
  );
}

export function LibraryPage() {
  const client = useQueryClient();
  const { data, error, isPending, refetch, isFetching } = useQuery(libraryQuery);
  const scan = useMutation({
    mutationFn: startScan,
    onSuccess: (status) => client.setQueryData(libraryQuery.queryKey, status),
  });

  return (
    <section className="page">
      <header className="page__header page__header--actions">
        <div>
          <h1 className="page__title">Library</h1>
          <p className="page__summary">
            {isPending
              ? "Loading…"
              : data?.scanning
                ? `Reading new music · ${number.format(data.queued)} ${data.queued === 1 ? "file" : "files"} to go`
                : "Music folders are watched; new files appear on their own."}
          </p>
        </div>
        <button
          className="button button--primary"
          type="button"
          onClick={() => scan.mutate()}
          disabled={!data || scan.isPending || data.scanning}
        >
          <RefreshCw size={16} aria-hidden className={data?.scanning ? "spin" : undefined} />
          {data?.scanning ? "Scanning…" : "Scan now"}
        </button>
      </header>

      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {scan.error && <QueryError error={scan.error} retry={() => scan.mutate()} />}

      {data && !data.ffmpeg && (
        <div className="banner banner--warning" role="status">
          <CircleAlert size={18} aria-hidden />
          <span>
            FFmpeg isn't installed on the home PC, so High and Data saver quality and volume levelling are off.
            Lossless still plays. On a Mac, run <code>brew install ffmpeg</code> and restart Hive.
          </span>
        </div>
      )}

      {data && (
        <>
          <div className="cards">
            <article className="card">
              <h2 className="card__label">Songs</h2>
              <p className="card__value">{number.format(data.tracks)}</p>
              <p className="card__meta">{playingTime(data)}</p>
            </article>
            <article className="card">
              <h2 className="card__label">Albums</h2>
              <p className="card__value">{number.format(data.albums)}</p>
              <p className="card__meta">{number.format(data.artists)} artists</p>
            </article>
            <article className="card">
              <h2 className="card__label">On disk</h2>
              <p className="card__value">{formatBytes(data.sizeBytes)}</p>
              <p className="card__meta">Original files, never re-encoded</p>
            </article>
            <article className="card">
              <h2 className="card__label">Needs attention</h2>
              <p className="card__value">{number.format(data.needsAttention.length)}</p>
              <p className="card__meta">
                {data.needsAttention.length
                  ? "Listed below"
                  : data.duplicates?.length
                    ? `Every file was read · ${number.format(data.duplicates.length)} duplicate ${data.duplicates.length === 1 ? "copy" : "copies"}`
                    : "Every file was read"}
              </p>
            </article>
          </div>

          <LookupPanel />

          <section className="panel" aria-labelledby="folders-h">
            <h2 id="folders-h" className="panel__title">
              Music folders
            </h2>
            <ul className="rows">
              {data.folders.map((f) => (
                <li key={f.path} className="row">
                  <span className="row__icon" aria-hidden>
                    <FolderOpen size={16} />
                  </span>
                  <div className="row__text">
                    <p className="row__title mono">{f.path}</p>
                    <p className="row__meta">
                      {f.exists ? `${number.format(f.trackCount)} songs` : "This folder can't be found (is the drive connected?)"}
                    </p>
                  </div>
                </li>
              ))}
            </ul>
            <p className="note">
              Copy albums into a music folder, or use Upload. Browser uploads are saved to{" "}
              <span className="mono">{data.uploadFolder}</span>.
            </p>
          </section>

          {data.queue.length > 0 && (
            <section className="panel" aria-labelledby="queue-h">
              <h2 id="queue-h" className="panel__title">
                Import queue
              </h2>
              <ul className="rows">
                {data.queue.map((item) => (
                  <QueueRow key={item.id} item={item} />
                ))}
              </ul>
              {data.queued > data.queue.length && (
                <p className="note">and {number.format(data.queued - data.queue.length)} more</p>
              )}
            </section>
          )}

          <section className="panel" aria-labelledby="attention-h">
            <h2 id="attention-h" className="panel__title">
              Needs attention
            </h2>
            {data.needsAttention.length ? (
              <ul className="rows">
                {data.needsAttention.map((item) => (
                  <ProblemRow key={item.id} item={item} />
                ))}
              </ul>
            ) : (
              <p className="note">Nothing. Every file in the music folders was read.</p>
            )}
          </section>

          {data.duplicates && data.duplicates.length > 0 && <Duplicates items={data.duplicates} />}

          {data.recentlyAdded && data.recentlyAdded.length > 0 && (
            <section className="panel" aria-labelledby="recent-h">
              <h2 id="recent-h" className="panel__title">
                Recently added
              </h2>
              <ul className="rows">
                {data.recentlyAdded.map((a) => (
                  <li key={a.id} className="row">
                    <Artwork id={a.artworkId} title={a.title} />
                    <div className="row__text">
                      <p className="row__title">{a.title}</p>
                      <p className="row__meta">
                        {a.artistName}
                        {a.year ? ` · ${a.year}` : ""} · {a.trackCount} {a.trackCount === 1 ? "song" : "songs"}
                      </p>
                    </div>
                    <span className={`quality quality--${a.tier}`}>
                      {a.tier === "hires" ? "Hi-Res" : a.tier === "lossless" ? "Lossless" : "Lossy"}
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </>
      )}
    </section>
  );
}
