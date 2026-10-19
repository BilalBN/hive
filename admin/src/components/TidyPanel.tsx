import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowRight, Sparkles, Undo2 } from "lucide-react";
import { useMemo, useState } from "react";

import { applyTidy, fetchTidy, type TidyItem, undoTidy } from "../api/people";
import { QueryError } from "./QueryError";

export const tidyQuery = { queryKey: ["tidy"], queryFn: fetchTidy } as const;

function TidyList({
  items,
  action,
  busy,
  onRun,
}: {
  items: TidyItem[];
  action: "apply" | "undo";
  busy: boolean;
  onRun: (ids: string[]) => void;
}) {
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const all = items.length > 0 && items.every((i) => picked.has(i.trackId));
  const toggle = (id: string) =>
    setPicked((p) => {
      const n = new Set(p);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  const chosen = items.filter((i) => picked.has(i.trackId)).map((i) => i.trackId);
  return (
    <>
      <div className="toolbar">
        <label className="check">
          <input
            type="checkbox"
            checked={all}
            onChange={() => setPicked(all ? new Set() : new Set(items.map((i) => i.trackId)))}
          />
          <span>Select all ({items.length})</span>
        </label>
        <button
          className={`button ${action === "apply" ? "button--primary" : "button--secondary"}`}
          type="button"
          disabled={!chosen.length || busy}
          onClick={() => {
            onRun(chosen);
            setPicked(new Set());
          }}
        >
          {action === "apply" ? <Sparkles size={16} aria-hidden /> : <Undo2 size={16} aria-hidden />}
          {!chosen.length
            ? action === "apply"
              ? "Tidy selected"
              : "Undo selected"
            : `${action === "apply" ? "Tidy" : "Undo"} ${chosen.length} ${chosen.length === 1 ? "song" : "songs"}`}
        </button>
      </div>
      <ul className="rows rows--tidy">
        {items.map((i) => (
          <li key={i.trackId} className="row">
            <input
              type="checkbox"
              aria-label={`${action === "apply" ? "Tidy" : "Undo"} ${i.before}`}
              checked={picked.has(i.trackId)}
              onChange={() => toggle(i.trackId)}
            />
            <div className="row__text">
              <p className="row__title tidy">
                <span className="tidy__before">{i.before}</span>
                <ArrowRight size={14} aria-label="becomes" className="tidy__arrow" />
                <span className="tidy__after">{i.after}</span>
              </p>
              <p className="row__meta">{i.albumTitle}</p>
            </div>
          </li>
        ))}
      </ul>
    </>
  );
}

/**
 * Song titles with download clutter ("01 - Song [www.site.com] 320kbps").
 * Tidy names are what Hive shows: the files never change, and undo is a click.
 */
export function TidyPanel() {
  const client = useQueryClient();
  const { data, error, refetch, isFetching } = useQuery(tidyQuery);
  const [open, setOpen] = useState(false);
  const set = (items: TidyItem[]) => client.setQueryData(tidyQuery.queryKey, items);
  const apply = useMutation({ mutationFn: applyTidy, onSuccess: set });
  const undo = useMutation({ mutationFn: undoTidy, onSuccess: set });
  const [waiting, done] = useMemo(
    () => [data?.filter((i) => !i.applied) ?? [], data?.filter((i) => i.applied) ?? []],
    [data],
  );
  if (!data && !error) return null;
  return (
    <section className="panel" aria-labelledby="tidy-h">
      <div className="panel__head">
        <h2 id="tidy-h" className="panel__title">
          Tidy song names
        </h2>
        {(waiting.length > 0 || done.length > 0) && (
          <button className="link-button" type="button" onClick={() => setOpen(!open)}>
            {open ? "Hide" : "Review"}
          </button>
        )}
      </div>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {data && (
        <p className="note">
          {waiting.length
            ? `${waiting.length} ${waiting.length === 1 ? "song has" : "songs have"} clutter from download sites in the title. Tidy names change what Hive shows; your files stay as they are.`
            : "Song titles look clean."}
          {done.length ? ` ${done.length} tidied so far.` : ""}
        </p>
      )}
      {(apply.error || undo.error) && <p className="note note--error">{(apply.error ?? undo.error)!.message}</p>}
      {open && waiting.length > 0 && (
        <TidyList items={waiting} action="apply" busy={apply.isPending} onRun={(ids) => apply.mutate(ids)} />
      )}
      {open && done.length > 0 && (
        <>
          <h3 className="panel__subtitle">Tidied</h3>
          <TidyList items={done} action="undo" busy={undo.isPending} onRun={(ids) => undo.mutate(ids)} />
        </>
      )}
    </section>
  );
}
