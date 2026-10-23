import { type FormEvent, useState } from "react";
import { useMutation } from "@tanstack/react-query";

import type { AdminAlbum } from "../api/client";
import { type TrackEdit, updateTrack } from "../api/editor";
import { QueryError } from "./QueryError";

type Song = AdminAlbum["album"]["tracks"][number];
type Field = "title" | "artistName" | "trackNumber" | "discNumber" | "composer" | "lyricist";

const LABELS: Record<Field, string> = {
  title: "Song title",
  artistName: "Singers",
  trackNumber: "Song number",
  discNumber: "Disc",
  composer: "Music",
  lyricist: "Lyrics",
};
const NUMBERS: Field[] = ["trackNumber", "discNumber"];

function initial(t: Song): Record<Field, string> {
  return {
    title: t.title,
    artistName: t.artistName,
    trackNumber: t.trackNumber ? String(t.trackNumber) : "",
    discNumber: t.discNumber ? String(t.discNumber) : "",
    composer: t.composer ?? "",
    lyricist: t.lyricist ?? "",
  };
}

/** Correct one song's details. Hive keeps the corrections; the file is never changed. */
export function SongEditor({
  song,
  edited,
  onSaved,
  onClose,
}: {
  song: Song;
  edited: string[];
  onSaved: (a: AdminAlbum) => void;
  onClose: () => void;
}) {
  const original = initial(song);
  const [form, setForm] = useState(original);
  const save = useMutation({
    mutationFn: (edit: TrackEdit) => updateTrack(song.id, edit),
    onSuccess: (a) => {
      onSaved(a);
      onClose();
    },
  });
  const changed = (Object.keys(form) as Field[]).filter((f) => form[f] !== original[f]);

  function submit(e: FormEvent) {
    e.preventDefault();
    const edit: Record<string, string | number | null> = {};
    for (const f of changed) {
      const v = form[f].trim();
      edit[f] = NUMBERS.includes(f) ? (v ? Number(v) : null) : v || null;
    }
    save.mutate(edit as TrackEdit);
  }

  return (
    <form className="form song-editor" onSubmit={submit} aria-label={`Details of ${song.title}`}>
      <div className="form__grid">
        {(Object.keys(LABELS) as Field[]).map((f) => (
          <div className="field" key={f}>
            <label htmlFor={`s-${song.id}-${f}`}>{LABELS[f]}</label>
            <input
              id={`s-${song.id}-${f}`}
              className="input"
              value={form[f]}
              required={f === "title" || f === "artistName"}
              maxLength={NUMBERS.includes(f) ? 3 : 512}
              inputMode={NUMBERS.includes(f) ? "numeric" : undefined}
              pattern={NUMBERS.includes(f) ? "\\d{1,3}" : undefined}
              onChange={(e) => setForm({ ...form, [f]: e.target.value })}
            />
            <p className="field__hint">
              {edited.includes(f) ? "Set by you" : "From the file"}
              {edited.includes(f) && (
                <button
                  type="button"
                  className="link-button"
                  onClick={() => save.mutate({ [f]: null } as TrackEdit)}
                  aria-label={`Undo ${LABELS[f].toLowerCase()}`}
                >
                  Undo
                </button>
              )}
            </p>
          </div>
        ))}
      </div>
      {save.error && <QueryError error={save.error} retry={() => save.reset()} />}
      <p className="note">
        The music file isn&apos;t changed; Hive keeps your corrections, even when the file is read again.
      </p>
      <div className="actions">
        <button className="button button--primary" type="submit" disabled={!changed.length || save.isPending}>
          {save.isPending ? "Saving…" : "Save song"}
        </button>
        <button className="button button--secondary" type="button" onClick={onClose}>
          Cancel
        </button>
      </div>
    </form>
  );
}
