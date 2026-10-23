import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { CircleAlert, HardDrive, Info, TriangleAlert } from "lucide-react";

import { ago } from "../api/people";
import { fetchSystem, type SystemHealth } from "../api/system";
import { QueryError } from "../components/QueryError";
import { formatBytes } from "../upload/queue";

const LOGS_PATH: string = "/logs";
const BACKUPS_PATH: string = "/backups";
const SETTINGS_PATH: string = "/settings";
const number = new Intl.NumberFormat();

export const systemQuery = { queryKey: ["system"], queryFn: fetchSystem, refetchInterval: 30_000 } as const;

function uptime(seconds: number): string {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d) return `${d} ${d === 1 ? "day" : "days"}${h ? `, ${h} hr` : ""}`;
  if (h) return `${h} hr ${m} min`;
  return `${m} min`;
}

function Disks({ r }: { r: SystemHealth }) {
  return (
    <section className="panel" aria-labelledby="disks-h">
      <h2 id="disks-h" className="panel__title">
        <HardDrive size={18} aria-hidden /> Drives
      </h2>
      <ul className="rows">
        {r.disks.map((d) => {
          const used = d.totalBytes ? Math.round((100 * (d.totalBytes - d.freeBytes)) / d.totalBytes) : 0;
          return (
            <li key={d.label} className="row row--stack">
              <div className="row__line">
                <div className="row__text">
                  <p className="row__title">{d.label}</p>
                  <p className="row__meta mono">{d.path}</p>
                </div>
                <span className={`state ${d.level === "ok" ? "state--found" : "state--failed"}`}>
                  {formatBytes(d.freeBytes)} free of {formatBytes(d.totalBytes)}
                </span>
              </div>
              <div
                className={`progress ${d.level === "ok" ? "progress--accent" : "progress--danger"}`}
                role="progressbar"
                aria-label={`${d.label}: ${used}% used`}
                aria-valuenow={used}
                aria-valuemin={0}
                aria-valuemax={100}
              >
                <span style={{ width: `${used}%` }} />
              </div>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

/** System health: how the home computer is doing. */
export function SystemPage() {
  const { data: r, error, refetch, isFetching } = useQuery(systemQuery);
  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">System health</h1>
        <p className="page__summary">
          How the home computer is doing. Admins get an email when a drive runs low or backups stop working.
        </p>
      </header>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {r?.problems.map((p) => (
        <div
          key={p.key}
          className={`banner banner--${p.level === "problem" ? "danger" : p.level === "warning" ? "warning" : "info"}`}
          role={p.level === "info" ? "status" : "alert"}
        >
          {p.level === "info" ? (
            <Info size={18} aria-hidden />
          ) : p.level === "problem" ? (
            <CircleAlert size={18} aria-hidden />
          ) : (
            <TriangleAlert size={18} aria-hidden />
          )}
          <span>{p.text}</span>
        </div>
      ))}
      {r && (
        <>
          {r.problems.length === 0 && (
            <div className="banner banner--info" role="status">
              <Info size={18} aria-hidden />
              <span>All good: drives have room, backups are running.</span>
            </div>
          )}
          <div className="cards">
            <article className="card">
              <h2 className="card__label">Running for</h2>
              <p className="card__value">{uptime(r.uptimeSeconds)}</p>
              <p className="card__meta">
                Hive {r.serverVersion} · {r.system}
                {r.packaged ? "" : " · from the code"}
              </p>
            </article>
            <article className="card">
              <h2 className="card__label">Last backup</h2>
              <p className="card__value card__value--small">{r.lastBackupAt ? ago(r.lastBackupAt) : "None yet"}</p>
              <p className="card__meta">
                <Link to={BACKUPS_PATH} className="link">
                  Backups
                </Link>
              </p>
            </article>
            <article className="card">
              <h2 className="card__label">Today</h2>
              <p className="card__value">{number.format(r.errorsToday)}</p>
              <p className="card__meta">
                {r.errorsToday === 1 ? "error" : "errors"} · {number.format(r.warningsToday)} warnings ·{" "}
                <Link to={LOGS_PATH} className="link">
                  Logs
                </Link>
              </p>
            </article>
            <article className="card">
              <h2 className="card__label">Apps</h2>
              <p className="card__value">{number.format(r.devices)}</p>
              <p className="card__meta">
                devices ·{" "}
                {r.devicesOnOldApps
                  ? `${r.devicesOnOldApps} older than ${r.minAppVersion}`
                  : `all on ${r.minAppVersion} or newer`}{" "}
                ·{" "}
                <Link to={SETTINGS_PATH} className="link">
                  change
                </Link>
              </p>
            </article>
          </div>
          <Disks r={r} />
          <section className="panel" aria-labelledby="where-h">
            <h2 id="where-h" className="panel__title">
              Where Hive keeps things
            </h2>
            <p className="note">
              Everything Hive knows is in <code className="mono">{r.dataFolder}</code> (database{" "}
              {formatBytes(r.databaseBytes)}). FFmpeg: {r.ffmpeg ? "found" : "missing"}. Python {r.python}.
            </p>
          </section>
        </>
      )}
    </section>
  );
}
