import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";

import { keepBoth, keepCopy, type SameSongCopy, type SameSongGroup, sameSongsQuery } from "../api/editor";

const size = (b: number) => (b >= 1e9 ? `${(b / 1e9).toFixed(1)} GB` : `${Math.max(1, Math.round(b / 1e6))} MB`);

function counts(c: SameSongCopy): string {
  const out = [];
  if (c.likes) out.push(`${c.likes} ${c.likes === 1 ? "like" : "likes"}`);
  if (c.plays) out.push(`${c.plays} ${c.plays === 1 ? "play" : "plays"}`);
  if (c.inPlaylists) out.push(`in ${c.inPlaylists} ${c.inPlaylists === 1 ? "playlist" : "playlists"}`);
  return out.join(" · ");
}

function Group({ group }: { group: SameSongGroup }) {
  const client = useQueryClient();
  const [note, setNote] = useState<string | null>(null);
  const refresh = () => {
    client.invalidateQueries({ queryKey: sameSongsQuery.queryKey });
    client.invalidateQueries({ queryKey: ["library"] });
    client.invalidateQueries({ queryKey: ["admin-albums"] });
  };
  const keep = useMutation({
    mutationFn: (c: SameSongCopy) =>
      keepCopy(
        c.trackId,
        group.copies.filter((o) => o.trackId !== c.trackId).map((o) => o.trackId),
      ),
    onSuccess: (r) => {
      const m = r.moved;
      setNote(
        `Done. ${r.deleted} ${r.deleted === 1 ? "file" : "files"} deleted; moved ${m.likes} likes, ${m.plays} plays, ${m.playlistEntries} playlist entries.`,
      );
      refresh();
    },
  });
  const both = useMutation({ mutationFn: () => keepBoth(group.key), onSuccess: refresh });
  const busy = keep.isPending || both.isPending;
  const first = group.copies[0];
  const error = keep.error ?? both.error;
  return (
    <li className="row row--stack">
      <p className="row__title">
        {first.title} · <span className="row__meta">{first.artistName}</span>
      </p>
      <ul className="rows">
        {group.copies.map((c) => (
          <li key={c.trackId} className="row">
            <div className="row__text">
              <p className="row__meta">
                <span className={`quality quality--${c.lossless ? "lossless" : "lossy"}`}>{c.format}</span>{" "}
                {c.albumTitle} · {size(c.sizeBytes)}
                {c.best && <strong> · Better copy</strong>}
              </p>
              <p className="row__meta mono">{c.file}</p>
              {counts(c) && <p className="row__meta">{counts(c)}</p>}
            </div>
            <button
              className={`button ${c.best ? "button--primary" : "button--secondary"}`}
              type="button"
              disabled={busy}
              aria-label={`Keep the ${c.format} copy on ${c.albumTitle}`}
              onClick={() => {
                const others = group.copies.length - 1;
                if (
                  window.confirm(
                    `Keep this copy and delete the other ${others === 1 ? "file" : `${others} files`} from the home computer? Likes, plays and playlists move to this one.`,
                  )
                ) {
                  keep.mutate(c);
                }
              }}
            >
              Keep this copy
            </button>
          </li>
        ))}
      </ul>
      <div className="actions">
        <button className="link-button" type="button" disabled={busy} onClick={() => both.mutate()}>
          They&apos;re different, keep both
        </button>
      </div>
      {error && <p className="row__meta row__meta--error">{error.message}</p>}
      {note && <p className="note">{note}</p>}
    </li>
  );
}

/** The same song in two different files (an MP3 and a FLAC on different albums, say). */
export function SameSongs() {
  const { data } = useQuery(sameSongsQuery);
  if (!data || data.items.length === 0) return null;
  return (
    <section className="panel" aria-labelledby="same-h">
      <h2 id="same-h" className="panel__title">
        Same song twice · {data.items.length}
      </h2>
      <p className="note">
        These look like the same song in different files. Keeping one moves everyone&apos;s likes, plays and playlist
        entries to it and deletes the other file. Hive suggests the better-sounding copy.
      </p>
      <ul className="rows">
        {data.items.map((g) => (
          <Group key={g.key} group={g} />
        ))}
      </ul>
    </section>
  );
}
