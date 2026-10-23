import { useQuery } from "@tanstack/react-query";
import { Download } from "lucide-react";
import { useState } from "react";

import { fetchLogs, LOG_FILE, type LogLine, type LogQuery } from "../api/system";
import { QueryError } from "../components/QueryError";

const time = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit" });
const day = new Intl.DateTimeFormat(undefined, { dateStyle: "medium" });

const LEVELS: { value: NonNullable<LogQuery["level"]>; label: string }[] = [
  { value: "INFO", label: "Everything" },
  { value: "WARNING", label: "Warnings and errors" },
  { value: "ERROR", label: "Errors only" },
  { value: "DEBUG", label: "Everything, with details" },
];

function Line({ l }: { l: LogLine }) {
  const at = new Date(l.at);
  return (
    <li className={`log log--${l.level.toLowerCase()}`}>
      <time className="log__time mono" dateTime={l.at} title={day.format(at)}>
        {time.format(at)}
      </time>
      <span className="log__level">{l.level === "WARNING" ? "WARN" : l.level}</span>
      <span className="log__area mono">{l.area}</span>
      <span className="log__text">{l.text}</span>
    </li>
  );
}

/** Logs: what the server has been doing, newest first. */
export function LogsPage() {
  const [level, setLevel] = useState<NonNullable<LogQuery["level"]>>("INFO");
  const [area, setArea] = useState("");
  const [q, setQ] = useState("");
  const [live, setLive] = useState(true);
  const query: LogQuery = { level, limit: 500, ...(area ? { area } : {}), ...(q.trim() ? { q: q.trim() } : {}) };
  const { data, error, refetch, isFetching } = useQuery({
    queryKey: ["logs", query],
    queryFn: () => fetchLogs(query),
    refetchInterval: live ? 5000 : false,
  });
  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Logs</h1>
        <p className="page__summary">
          What the server has been doing since it started, newest first. Song titles and what people play aren't logged.
        </p>
      </header>
      <div className="panel form logs__filters">
        <label className="field">
          <span>Show</span>
          <select className="input" value={level} onChange={(e) => setLevel(e.target.value as typeof level)}>
            {LEVELS.map((l) => (
              <option key={l.value} value={l.value}>
                {l.label}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          <span>From</span>
          <select className="input" value={area} onChange={(e) => setArea(e.target.value)}>
            <option value="">Every part of Hive</option>
            {data?.areas.map((a) => (
              <option key={a} value={a}>
                {a}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          <span>Containing</span>
          <input className="input" type="search" value={q} onChange={(e) => setQ(e.target.value)} />
        </label>
        <div className="field">
          <span>Live</span>
          <label className="switch">
            <input type="checkbox" checked={live} onChange={(e) => setLive(e.target.checked)} />
            <span>{live ? "On" : "Off"}</span>
          </label>
        </div>
        <a className="button button--secondary logs__download" href={LOG_FILE} download="hive.log">
          <Download size={16} aria-hidden /> Download the log file
        </a>
      </div>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {data && (
        <section className="panel" aria-label="Log lines">
          {data.items.length ? (
            <ul className="logs">
              {data.items.map((l) => (
                <Line key={l.id} l={l} />
              ))}
            </ul>
          ) : (
            <p className="note">Nothing matches.</p>
          )}
        </section>
      )}
    </section>
  );
}
