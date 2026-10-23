import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, DatabaseBackup, History, RotateCcw, Trash2 } from "lucide-react";
import { type FormEvent, useEffect, useState } from "react";

import {
  type Backup,
  type BackupStatus,
  cancelRestore,
  deleteBackup,
  fetchBackups,
  restoreBackup,
  runBackup,
  saveBackupSettings,
} from "../api/backups";
import { QueryError } from "../components/QueryError";
import { formatBytes } from "../upload/queue";
import { libraryQuery } from "./Library";

export const backupsQuery = {
  queryKey: ["backups"],
  queryFn: fetchBackups,
  refetchInterval: 30_000,
} as const;

const when = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
const number = new Intl.NumberFormat();

const KIND: Record<Backup["kind"], string> = {
  manual: "Made by hand",
  scheduled: "Daily",
  "before-restore": "Safety copy before a restore",
  "before-update": "Safety copy before an update",
};

function Schedule({ status }: { status: BackupStatus }) {
  const client = useQueryClient();
  const [enabled, setEnabled] = useState(status.enabled);
  const [time, setTime] = useState(status.time);
  const [keep, setKeep] = useState(status.keep);
  const [folder, setFolder] = useState(status.folder);
  // Follow what's saved (another admin, or after saving).
  useEffect(() => {
    setEnabled(status.enabled);
    setTime(status.time);
    setKeep(status.keep);
    setFolder(status.folder);
  }, [status.enabled, status.time, status.keep, status.folder]);
  const save = useMutation({
    mutationFn: () =>
      saveBackupSettings({
        enabled,
        time,
        keep,
        ...(folder.trim() !== status.folder ? { folder: folder.trim() } : {}),
      }),
    onSuccess: (fresh) => client.setQueryData(backupsQuery.queryKey, fresh),
  });
  const changed =
    enabled !== status.enabled || time !== status.time || keep !== status.keep || folder.trim() !== status.folder;
  const submit = (e: FormEvent) => {
    e.preventDefault();
    save.mutate();
  };
  return (
    <form className="panel form" onSubmit={submit} aria-labelledby="schedule-h">
      <h2 id="schedule-h" className="panel__title">
        Schedule and place
      </h2>
      <div className="form__grid">
        <div className="field">
          <span>Daily backup</span>
          <label className="switch">
            <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
            <span>{enabled ? "On" : "Off"}</span>
          </label>
        </div>
        <label className="field">
          <span>At</span>
          <input
            className="input"
            type="time"
            value={time}
            disabled={!enabled}
            onChange={(e) => setTime(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Keep</span>
          <select className="input" value={keep} onChange={(e) => setKeep(Number(e.target.value))}>
            {[3, 7, 14, 30, 60].map((n) => (
              <option key={n} value={n}>
                The last {n}
              </option>
            ))}
          </select>
        </label>
        <div className="field field--wide">
          <label className="field__control">
            <span>Backup folder</span>
            <input className="input mono" value={folder} onChange={(e) => setFolder(e.target.value)} />
          </label>
          <span className="field__hint">
            Best on a different drive from Hive, like an external backup drive (for example{" "}
            <code className="mono">E:\Hive backups</code> or <code className="mono">/Volumes/Backup/Hive</code>).
          </span>
        </div>
      </div>
      {save.error && <p className="note note--error">{save.error.message}</p>}
      <div className="actions">
        <button className="button button--primary" type="submit" disabled={!changed || save.isPending}>
          {save.isPending ? "Saving…" : "Save"}
        </button>
      </div>
    </form>
  );
}

/** Moving to this computer: where each of the backup's music folders is now. */
function FolderMoves({
  from,
  here,
  value,
  onChange,
}: {
  from: string[];
  here: string[];
  value: Record<string, string>;
  onChange: (v: Record<string, string>) => void;
}) {
  return (
    <div className="moves">
      <p className="note">
        This backup was made on another computer, or before the music moved. Where is each music folder now? Songs keep
        their likes, plays and playlists.
      </p>
      {from.map((old) => (
        <label key={old} className="field">
          <span className="mono">{old}</span>
          <select
            className="input"
            value={value[old] ?? ""}
            onChange={(e) => onChange({ ...value, [old]: e.target.value })}
          >
            <option value="">Leave it as it was</option>
            {here.map((h) => (
              <option key={h} value={h}>
                Now in {h}
              </option>
            ))}
          </select>
        </label>
      ))}
    </div>
  );
}

function BackupRow({ b, pending, here }: { b: Backup; pending: boolean; here: string[] }) {
  const client = useQueryClient();
  const elsewhere = b.musicFolders.filter((f) => !here.includes(f));
  const [asking, setAsking] = useState(false);
  const [moves, setMoves] = useState<Record<string, string>>(() =>
    Object.fromEntries(elsewhere.map((f, i) => [f, here[i] ?? here[0] ?? ""])),
  );
  const restore = useMutation({
    mutationFn: () =>
      restoreBackup(
        b.id,
        Object.entries(moves)
          .filter(([, to]) => to)
          .map(([from, to]) => ({ from, to })),
      ),
    onSuccess: (fresh) => {
      setAsking(false);
      client.setQueryData(backupsQuery.queryKey, fresh);
    },
  });
  const remove = useMutation({
    mutationFn: () => deleteBackup(b.id),
    onSuccess: () => client.invalidateQueries({ queryKey: backupsQuery.queryKey }),
  });
  const at = when.format(new Date(b.at));
  const confirmRestore = () => {
    if (
      globalThis.confirm?.(
        `Restore the backup from ${at}? Everything changes back to how it was then when Hive restarts. ` +
          "Today's state is backed up first, and anyone signed out since stays signed out.",
      ) ??
      true
    )
      restore.mutate();
  };
  return (
    <li className="row row--stack">
      <div className="row__line">
        <span className="row__icon" aria-hidden>
          <History size={16} />
        </span>
        <div className="row__text">
          <p className="row__title">{at}</p>
          <p className="row__meta">
            {KIND[b.kind]} · {formatBytes(b.sizeBytes)} · {number.format(b.people)}{" "}
            {b.people === 1 ? "person" : "people"} · {number.format(b.tracks)} {b.tracks === 1 ? "song" : "songs"} ·
            Hive {b.serverVersion}
          </p>
          {(restore.error || remove.error) && (
            <p className="note note--error">{(restore.error ?? remove.error)!.message}</p>
          )}
        </div>
        <div className="row__actions">
          <button
            className="button button--secondary"
            type="button"
            disabled={pending || restore.isPending}
            onClick={() => (elsewhere.length && here.length ? setAsking(!asking) : confirmRestore())}
          >
            <RotateCcw size={16} aria-hidden /> Restore
          </button>
          <button
            className="button button--secondary"
            type="button"
            aria-label={`Delete the backup from ${at}`}
            disabled={remove.isPending}
            onClick={() => {
              if (globalThis.confirm?.(`Delete the backup from ${at}?`) ?? true) remove.mutate();
            }}
          >
            <Trash2 size={16} aria-hidden />
          </button>
        </div>
      </div>
      {asking && (
        <div className="row__more">
          <FolderMoves from={elsewhere} here={here} value={moves} onChange={setMoves} />
          <div className="actions">
            <button className="button button--secondary" type="button" onClick={() => setAsking(false)}>
              Cancel
            </button>
            <button
              className="button button--primary"
              type="button"
              disabled={restore.isPending}
              onClick={confirmRestore}
            >
              Restore this backup
            </button>
          </div>
        </div>
      )}
    </li>
  );
}

/** Backups: everything Hive knows, daily or now, and putting one back. */
export function BackupsPage() {
  const client = useQueryClient();
  const { data, error, refetch, isFetching } = useQuery(backupsQuery);
  const library = useQuery(libraryQuery);
  const here = library.data?.folders.map((f) => f.path) ?? [];
  const now = useMutation({
    mutationFn: runBackup,
    onSuccess: () => client.invalidateQueries({ queryKey: backupsQuery.queryKey }),
  });
  const cancel = useMutation({
    mutationFn: cancelRestore,
    onSuccess: (fresh) => client.setQueryData(backupsQuery.queryKey, fresh),
  });
  const restoredRecently =
    data?.restored && Date.now() - new Date(data.restored.at).getTime() < 7 * 86_400_000 ? data.restored : null;
  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Backups</h1>
        <p className="page__summary">
          Everything Hive knows: people, devices, likes, playlists, history, settings and covers. Your music files
          aren't included; they stay in the music folders, so back up that drive separately.
        </p>
      </header>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {data?.pendingRestore && (
        <div className="banner banner--warning" role="status">
          <RotateCcw size={18} aria-hidden />
          <span>
            Restore waiting: the backup from {when.format(new Date(data.pendingRestore.backupAt))} is put in place when
            Hive restarts. Stop Hive on the home computer and start it again.
          </span>
          <button
            className="button button--secondary"
            type="button"
            disabled={cancel.isPending}
            onClick={() => cancel.mutate()}
          >
            Cancel restore
          </button>
        </div>
      )}
      {restoredRecently && (
        <div className="banner banner--info" role="status">
          <History size={18} aria-hidden />
          <span>
            Restored {restoredRecently.id} on {when.format(new Date(restoredRecently.at))}.
          </span>
        </div>
      )}
      {data?.lastError && (
        <div className="banner banner--danger" role="alert">
          <CircleAlert size={18} aria-hidden />
          <span>The last backup didn't work: {data.lastError}</span>
        </div>
      )}
      {data && (
        <>
          <section className="panel" aria-labelledby="backups-h">
            <div className="panel__head">
              <h2 id="backups-h" className="panel__title">
                Backups in the folder
              </h2>
              <button
                className="button button--primary"
                type="button"
                disabled={now.isPending || data.running}
                onClick={() => now.mutate()}
              >
                <DatabaseBackup size={16} aria-hidden /> {now.isPending || data.running ? "Backing up…" : "Back up now"}
              </button>
            </div>
            {now.error && <p className="note note--error">{now.error.message}</p>}
            {data.items.length ? (
              <ul className="rows">
                {data.items.map((b) => (
                  <BackupRow key={b.id} b={b} pending={!!data.pendingRestore} here={here} />
                ))}
              </ul>
            ) : (
              <p className="note">
                No backups yet.{" "}
                {data.enabled
                  ? `The first daily one runs at ${data.time}, or back up now.`
                  : "Back up now to make one."}
              </p>
            )}
          </section>
          <Schedule status={data} />
        </>
      )}
    </section>
  );
}
