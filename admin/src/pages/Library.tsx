import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, FolderOpen, Loader, RefreshCw, TriangleAlert } from "lucide-react";

import { fetchLibrary, type ImportItem, type LibraryStatus, startScan } from "../api/client";
import { Artwork } from "../components/Artwork";
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

function ProblemRow({ item }: { item: ImportItem }) {
  return (
    <li className="row">
      <span className="row__icon row__icon--warning" aria-hidden>
        <TriangleAlert size={16} />
      </span>
      <div className="row__text">
        <p className="row__title mono">{item.path}</p>
        <p className="row__meta">{item.problem}</p>
      </div>
    </li>
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
              <p className="card__meta">{data.needsAttention.length ? "Listed below" : "Every file was read"}</p>
            </article>
          </div>

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
