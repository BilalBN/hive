import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate, useSearch } from "@tanstack/react-router";
import { ArrowLeft, Check, ExternalLink, ImageUp, Search, Undo2, X } from "lucide-react";
import { type FormEvent, useEffect, useId, useState } from "react";

import {
  type AdminAlbum,
  type AlbumEdit,
  type AlbumFilter,
  decideMatch,
  fetchAdminAlbum,
  fetchAdminAlbums,
  type FoundAlbum,
  type LookupState,
  setAlbumArtwork,
  updateAlbum,
} from "../api/client";
import { Artwork } from "../components/Artwork";
import { lookupQuery } from "../components/LookupPanel";
import { QueryError } from "../components/QueryError";
import { LANGUAGES, languageName } from "../languages";

export const FILTERS: { value: AlbumFilter; label: string }[] = [
  { value: "all", label: "All" },
  { value: "review", label: "To check" },
  { value: "noArt", label: "No cover" },
  { value: "noLanguage", label: "No language" },
  { value: "notFound", label: "Not found online" },
];

const STATE_LABEL: Record<LookupState, string> = {
  off: "Lookup off",
  waiting: "Waiting",
  working: "Looking up…",
  found: "Filled in",
  review: "To check",
  notFound: "Not found",
  failed: "Couldn't look up",
  edited: "Edited",
};

const SOURCE_LABEL: Record<string, string> = {
  tags: "from the files",
  albumArtistTag: "from the files",
  folder: "from the folder",
  script: "from the titles' script",
  lookup: "looked up",
  admin: "set by you",
};

/** Albums: find one to check or correct; the editor opens in place. */
export function AlbumsPage() {
  const search = useSearch({ from: "/albums" });
  return search.album ? <AlbumEditor albumId={search.album} /> : <AlbumList filter={search.filter} />;
}

function AlbumList({ filter }: { filter: AlbumFilter }) {
  const navigate = useNavigate({ from: "/albums" });
  const [q, setQ] = useState("");
  const [typed, setTyped] = useState("");
  useEffect(() => {
    const t = setTimeout(() => setQ(typed), 250);
    return () => clearTimeout(t);
  }, [typed]);
  const { data, error, refetch, isFetching, isPending } = useQuery({
    queryKey: ["admin-albums", filter, q],
    queryFn: () => fetchAdminAlbums(filter, q),
  });
  const searchId = useId();

  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Albums</h1>
        <p className="page__summary">
          Check what Hive filled in and correct anything. What you set stays, through rescans and lookups.
        </p>
      </header>
      <div className="toolbar">
        <div className="chips" role="group" aria-label="Show">
          {FILTERS.map((f) => (
            <button
              key={f.value}
              type="button"
              className={`chip${f.value === filter ? " chip--on" : ""}`}
              aria-pressed={f.value === filter}
              onClick={() => navigate({ search: { filter: f.value } })}
            >
              {f.label}
            </button>
          ))}
        </div>
        <label className="search" htmlFor={searchId}>
          <Search size={16} aria-hidden />
          <input
            id={searchId}
            className="input"
            type="search"
            placeholder="Album, artist, film, actor…"
            value={typed}
            onChange={(e) => setTyped(e.target.value)}
          />
        </label>
      </div>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {isPending && <p className="note">Loading…</p>}
      {data && (
        <section className="panel">
          {data.items.length === 0 ? (
            <p className="note">
              {filter === "review" ? "Nothing to check." : q ? `No albums match "${q}".` : "No albums here."}
            </p>
          ) : (
            <ul className="rows">
              {data.items.map(({ album: a, lookup, lookupNote }) => (
                <li key={a.id}>
                  <Link to="/albums" search={{ filter, album: a.id }} className="row row--link">
                    <Artwork id={a.artworkId} title={a.title} />
                    <div className="row__text">
                      <p className="row__title">{a.title}</p>
                      <p className="row__meta">
                        {[a.artistName, a.year, languageName(a.language), a.filmTitle && a.filmTitle !== a.title ? `Film: ${a.filmTitle}` : undefined]
                          .filter(Boolean)
                          .join(" · ")}
                      </p>
                      {lookup === "notFound" && lookupNote && <p className="row__meta">{lookupNote}</p>}
                    </div>
                    <span className={`state state--${lookup}`}>{STATE_LABEL[lookup]}</span>
                  </Link>
                </li>
              ))}
            </ul>
          )}
          {data.total > data.items.length && (
            <p className="note">
              Showing {data.items.length} of {data.total}. Search to narrow it down.
            </p>
          )}
        </section>
      )}
    </section>
  );
}

type Field = "title" | "artistName" | "year" | "language" | "filmTitle" | "filmYear";

function initial(a: AdminAlbum): Record<Field, string> {
  return {
    title: a.album.title,
    artistName: a.album.artistName,
    year: a.album.year ? String(a.album.year) : "",
    language: a.album.language ?? "",
    filmTitle: a.album.film?.title ?? a.album.filmTitle ?? "",
    filmYear: a.album.film?.year ? String(a.album.film.year) : "",
  };
}

function AlbumEditor({ albumId }: { albumId: string }) {
  const client = useQueryClient();
  const search = useSearch({ from: "/albums" });
  const key = ["admin-album", albumId];
  const { data, error, refetch, isFetching } = useQuery({ queryKey: key, queryFn: () => fetchAdminAlbum(albumId) });
  const [form, setForm] = useState<Record<Field, string> | null>(null);
  useEffect(() => {
    if (data) setForm(initial(data));
  }, [data]);
  const done = (a: AdminAlbum) => {
    client.setQueryData(key, a);
    client.invalidateQueries({ queryKey: ["admin-albums"] });
    client.invalidateQueries({ queryKey: lookupQuery.queryKey });
    client.invalidateQueries({ queryKey: ["library"] });
  };
  const save = useMutation({ mutationFn: (edit: AlbumEdit) => updateAlbum(albumId, edit), onSuccess: done });
  const decide = useMutation({ mutationFn: (accept: boolean) => decideMatch(albumId, accept), onSuccess: done });
  const cover = useMutation({ mutationFn: (file: File) => setAlbumArtwork(albumId, file), onSuccess: done });

  const back = (
    <Link to="/albums" search={{ filter: search.filter }} className="link back">
      <ArrowLeft size={16} aria-hidden /> Albums
    </Link>
  );
  if (error) {
    return (
      <section className="page">
        {back}
        <QueryError error={error} retry={() => refetch()} busy={isFetching} />
      </section>
    );
  }
  if (!data || !form) {
    return (
      <section className="page">
        {back}
        <p className="note">Loading…</p>
      </section>
    );
  }
  const a = data.album;
  const original = initial(data);
  const changed = (Object.keys(form) as Field[]).filter((f) => form[f] !== original[f]);

  function submit(e: FormEvent) {
    e.preventDefault();
    const edit: AlbumEdit = {};
    for (const f of changed) {
      const v = form![f].trim();
      if (f === "year" || f === "filmYear") edit[f] = v ? Number(v) : null;
      else edit[f] = v || null;
    }
    save.mutate(edit);
  }

  const field = (f: Field, label: string, input: React.ReactNode) => {
    const edited = data.edited.includes(f);
    const source =
      data.sources[f] ?? (f.startsWith("film") && a.film?.wikidataId ? "lookup" : undefined);
    return (
      <div className="field">
        <label htmlFor={`f-${f}`}>{label}</label>
        {input}
        <p className="field__hint">
          {edited ? "Set by you" : source ? SOURCE_LABEL[source] ?? source : " "}
          {edited && (
            <button type="button" className="link-button" onClick={() => save.mutate({ [f]: null } as AlbumEdit)}>
              <Undo2 size={12} aria-hidden /> Undo
            </button>
          )}
        </p>
      </div>
    );
  };
  const text = (f: Field, props: React.InputHTMLAttributes<HTMLInputElement> = {}) => (
    <input
      id={`f-${f}`}
      className="input"
      value={form[f]}
      onChange={(e) => setForm({ ...form, [f]: e.target.value })}
      {...props}
    />
  );

  return (
    <section className="page">
      {back}
      <header className="album-head">
        <div className="album-head__art">
          <Artwork id={a.artworkId} title={a.title} size={160} />
          <label className="button button--secondary">
            <ImageUp size={16} aria-hidden /> Replace cover
            <input
              type="file"
              accept="image/jpeg,image/png,image/webp"
              hidden
              onChange={(e) => {
                const file = e.target.files?.[0];
                if (file) cover.mutate(file);
                e.target.value = "";
              }}
            />
          </label>
          {data.edited.includes("artwork") && (
            <button type="button" className="link-button" onClick={() => save.mutate({ artwork: null })}>
              Use the files' cover
            </button>
          )}
        </div>
        <div>
          <h1 className="page__title">{a.title}</h1>
          <p className="page__summary">
            {[a.artistName, a.year, languageName(a.language), `${a.trackCount} ${a.trackCount === 1 ? "song" : "songs"}`]
              .filter(Boolean)
              .join(" · ")}
          </p>
          {data.folder && <p className="note mono">{data.folder}</p>}
          <p className="note">
            <span className={`state state--${data.lookup}`}>{STATE_LABEL[data.lookup]}</span> {data.lookupNote}
          </p>
        </div>
      </header>
      {cover.error && <QueryError error={cover.error} retry={() => cover.reset()} />}

      {data.lookup === "review" && data.found && (
        <FoundCard found={data.found} busy={decide.isPending} onDecide={(accept) => decide.mutate(accept)} />
      )}
      {decide.error && <QueryError error={decide.error} retry={() => decide.reset()} />}

      <form className="panel form" onSubmit={submit}>
        <h2 className="panel__title">Details</h2>
        <div className="form__grid">
          {field("title", "Album title", text("title", { maxLength: 512, required: true }))}
          {field("artistName", "Album artist", text("artistName", { maxLength: 512, required: true }))}
          {field("year", "Year", text("year", { inputMode: "numeric", pattern: "\\d{4}", maxLength: 4 }))}
          {field(
            "language",
            "Language",
            <select
              id="f-language"
              className="input"
              value={form.language}
              onChange={(e) => setForm({ ...form, language: e.target.value })}
            >
              <option value="">Not known</option>
              {LANGUAGES.map((l) => (
                <option key={l.code} value={l.code}>
                  {l.name}
                  {l.native !== l.name ? ` · ${l.native}` : ""}
                </option>
              ))}
            </select>,
          )}
          {field("filmTitle", "Film (for soundtracks)", text("filmTitle", { maxLength: 512 }))}
          {field("filmYear", "Film year", text("filmYear", { inputMode: "numeric", pattern: "\\d{4}", maxLength: 4 }))}
        </div>
        {save.error && <QueryError error={save.error} retry={() => save.reset()} />}
        <div className="actions">
          <button className="button button--primary" type="submit" disabled={!changed.length || save.isPending}>
            {save.isPending ? "Saving…" : "Save changes"}
          </button>
          {changed.length > 0 && (
            <button className="button button--secondary" type="button" onClick={() => setForm(original)}>
              Cancel
            </button>
          )}
        </div>
      </form>

      {a.credits && a.credits.length > 0 && (
        <section className="panel">
          <h2 className="panel__title">People</h2>
          <p className="row__meta">
            {a.credits.map((c) => `${c.name} (${ROLE[c.role]})`).join(" · ")}
          </p>
        </section>
      )}

      <section className="panel">
        <h2 className="panel__title">Songs</h2>
        <ol className="rows">
          {a.tracks.map((t) => (
            <li key={t.id} className="row">
              <span className="row__icon mono">{t.trackNumber ?? ""}</span>
              <div className="row__text">
                <p className="row__title">{t.title}</p>
                <p className="row__meta">
                  {[t.artistName, t.composer && `Music: ${t.composer}`, t.lyricist && `Lyrics: ${t.lyricist}`]
                    .filter(Boolean)
                    .join(" · ")}
                </p>
              </div>
              <span className={`quality quality--${t.format.tier}`}>{t.format.label}</span>
            </li>
          ))}
        </ol>
      </section>
    </section>
  );
}

const ROLE: Record<string, string> = {
  singer: "singer",
  composer: "music",
  lyricist: "lyrics",
  musicDirector: "music director",
  actor: "cast",
  director: "director",
};

function FoundCard({
  found,
  busy,
  onDecide,
}: {
  found: FoundAlbum;
  busy: boolean;
  onDecide: (accept: boolean) => void;
}) {
  return (
    <section className="panel panel--accent" aria-labelledby="found-h">
      <h2 id="found-h" className="panel__title">
        Is this the album?
      </h2>
      <div className="found">
        <Artwork id={found.artworkId} title={found.title} size={96} />
        <div className="row__text">
          <p className="row__title">{found.title}</p>
          <p className="row__meta">
            {[found.artistName, found.year, languageName(found.language), found.trackCount && `${found.trackCount} songs`]
              .filter(Boolean)
              .join(" · ")}
          </p>
          {found.film && (
            <p className="row__meta">
              Film: {found.film.title}
              {found.film.year ? ` (${found.film.year})` : ""}
              {found.credits?.length ? ` · ${found.credits.slice(0, 5).map((c) => c.name).join(", ")}` : ""}
            </p>
          )}
          <p className="row__meta">
            {Math.round(found.score * 100)}% sure · {found.source}
            {found.link && (
              <>
                {" · "}
                <a className="link" href={found.link} target="_blank" rel="noreferrer">
                  Check it <ExternalLink size={12} aria-hidden />
                </a>
              </>
            )}
          </p>
        </div>
      </div>
      <div className="actions">
        <button className="button button--primary" type="button" disabled={busy} onClick={() => onDecide(true)}>
          <Check size={16} aria-hidden /> Yes, use this
        </button>
        <button className="button button--secondary" type="button" disabled={busy} onClick={() => onDecide(false)}>
          <X size={16} aria-hidden /> Not this
        </button>
      </div>
    </section>
  );
}
