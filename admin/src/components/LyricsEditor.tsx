import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Search } from "lucide-react";
import { useEffect, useId, useState } from "react";

import { type AdminLyrics, fetchLyrics, findLyrics, saveLyrics } from "../api/client";
import { QueryError } from "./QueryError";

const SOURCE: Record<AdminLyrics["source"], string> = {
  admin: "Set by you here.",
  file: "From the song's file (its tags or a .lrc file beside it).",
  online: "Found on LRCLIB.",
  none: "No lyrics yet.",
};

/** Type, paste or find a song's lyrics. Timed LRC lines follow the song in the app. */
export function LyricsEditor({ trackId, title, onSaved }: { trackId: string; title: string; onSaved?: () => void }) {
  const client = useQueryClient();
  const key = ["lyrics", trackId];
  const { data, error, refetch, isFetching } = useQuery({ queryKey: key, queryFn: () => fetchLyrics(trackId) });
  const [text, setText] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const boxId = useId();
  useEffect(() => {
    if (data && text === null) setText(data.text);
  }, [data, text]);

  const save = useMutation({
    mutationFn: (value: string) => saveLyrics(trackId, value),
    onSuccess: (l) => {
      client.setQueryData(key, l);
      setText(l.text);
      setNote(l.source === "admin" ? "Saved. The app shows these now." : "Removed. " + SOURCE[l.source]);
      onSaved?.();
    },
  });
  const find = useMutation({
    mutationFn: () => findLyrics(trackId),
    onSuccess: (f) => {
      setNote(f.found ? `${f.message} Check them, then Save.` : f.message);
      if (f.found && f.text) setText(f.text);
    },
  });

  if (error) return <QueryError error={error} retry={() => refetch()} busy={isFetching} />;
  if (!data || text === null) return <p className="note">Loading lyrics…</p>;
  const changed = text.trim() !== data.text.trim();
  return (
    <div className="lyrics-editor">
      <label htmlFor={boxId} className="lyrics-editor__label">
        Lyrics for {title}
      </label>
      <textarea
        id={boxId}
        className="input lyrics-editor__text"
        value={text}
        rows={10}
        placeholder={"Type or paste the lyrics.\nFor lyrics that follow the song, start lines with a time: [01:23.45] a line"}
        onChange={(e) => {
          setText(e.target.value);
          setNote(null);
        }}
      />
      <p className="note">{note ?? SOURCE[data.source]}</p>
      {(save.error || find.error) && (
        <QueryError error={(save.error ?? find.error)!} retry={() => (save.error ? save.reset() : find.reset())} />
      )}
      <div className="actions">
        <button
          className="button button--primary"
          type="button"
          disabled={!changed || save.isPending}
          onClick={() => save.mutate(text)}
        >
          {save.isPending ? "Saving…" : "Save lyrics"}
        </button>
        <button className="button button--secondary" type="button" disabled={find.isPending} onClick={() => find.mutate()}>
          <Search size={16} aria-hidden /> {find.isPending ? "Searching…" : "Find online"}
        </button>
        {data.source === "admin" && (
          <button className="link-button" type="button" disabled={save.isPending} onClick={() => save.mutate("")}>
            {data.fileHasLyrics ? "Use the file's lyrics" : "Remove lyrics"}
          </button>
        )}
      </div>
    </div>
  );
}
