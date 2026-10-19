import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { Check, CircleAlert, Copy, Info, KeyRound, RefreshCw, TriangleAlert, UserCheck } from "lucide-react";
import { useState } from "react";

import { fetchDevelopmentKey } from "../api/client";
import { ago, type AuditEntry, fetchOverview } from "../api/people";
import { healthQuery } from "../components/ServerStatus";
import { sessionQuery } from "../components/SignIn";
import { formatBytes } from "../upload/queue";
import { libraryQuery } from "./Library";

// Routes are built from nav.ts at runtime, so link targets are plain strings.
const LIBRARY_PATH: string = "/library";
const REQUESTS_PATH: string = "/requests";
const SETUP_PATH: string = "/setup";
const ACTIVITY_PATH: string = "/activity";
const SETTINGS_PATH: string = "/settings";

export const overviewQuery = {
  queryKey: ["overview"],
  queryFn: fetchOverview,
  refetchInterval: 15_000,
} as const;

const number = new Intl.NumberFormat();

function DevelopmentKey() {
  const { data } = useQuery({
    queryKey: ["development-key"],
    queryFn: fetchDevelopmentKey,
    staleTime: Infinity,
  });
  const [copied, setCopied] = useState(false);
  if (!data) return null;
  return (
    <section className="panel panel--key" aria-labelledby="key-h">
      <h2 id="key-h" className="panel__title">
        <KeyRound size={18} aria-hidden /> Key for the apps
      </h2>
      <p className="note">
        Apps from before invites connect with this key. It stops working once you set up the first admin; after that
        everyone joins with an invite.
      </p>
      <div className="key">
        <code className="key__value mono">{data}</code>
        <button
          className="button button--secondary"
          type="button"
          onClick={async () => {
            await navigator.clipboard?.writeText(data);
            setCopied(true);
            setTimeout(() => setCopied(false), 2000);
          }}
        >
          {copied ? <Check size={16} aria-hidden /> : <Copy size={16} aria-hidden />}
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
    </section>
  );
}

export function ActivityRows({ items }: { items: AuditEntry[] }) {
  if (!items.length) return <p className="note">Nothing yet.</p>;
  return (
    <ul className="rows">
      {items.map((e) => (
        <li key={e.id} className="row">
          <div className="row__text">
            <p className="row__title row__title--plain">{e.text}</p>
            <p className="row__meta">
              {e.actor} · <time dateTime={e.at}>{ago(e.at)}</time>
            </p>
          </div>
        </li>
      ))}
    </ul>
  );
}

/** How home is doing: requests waiting, who's in, the library, and what changed lately. */
export function Overview() {
  const health = useQuery(healthQuery);
  const library = useQuery(libraryQuery);
  const session = useQuery(sessionQuery);
  const overview = useQuery(overviewQuery);
  const o = overview.data;
  const needsSetup = session.data?.needsSetup && session.data.onHomeComputer;

  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Overview</h1>
        <p className="page__summary">
          {health.isPending ? "Checking home…" : health.isError ? "Can't reach the server." : "Home is running."}
        </p>
      </header>

      {health.isError && (
        <div className="banner banner--danger" role="alert">
          <CircleAlert size={18} aria-hidden />
          <span>The admin panel can't reach the Hive server. Check that it is running on the home PC.</span>
          <button
            className="button button--secondary"
            type="button"
            onClick={() => health.refetch()}
            disabled={health.isFetching}
          >
            <RefreshCw size={16} aria-hidden /> Try again
          </button>
        </div>
      )}

      {needsSetup && (
        <section className="panel panel--accent" aria-labelledby="setup-h">
          <h2 id="setup-h" className="panel__title">
            Set up the first admin
          </h2>
          <p className="note">
            Add your name and email to start using invites, approvals and sign-in from other computers. Install the new
            apps first: once you're set up, apps that use the temporary key are asked to sign in again.
          </p>
          <div className="actions">
            <Link to={SETUP_PATH} className="button button--primary">
              Set up
            </Link>
          </div>
        </section>
      )}

      {o && o.pendingRequests > 0 && (
        <Link to={REQUESTS_PATH} className="banner banner--accent">
          <UserCheck size={18} aria-hidden />
          <span>
            {o.pendingRequests === 1
              ? "1 person is waiting to be let in."
              : `${o.pendingRequests} people are waiting to be let in.`}
          </span>
          <span className="banner__action">Review</span>
        </Link>
      )}

      {o?.alerts.map((a, i) => (
        <div
          key={i}
          className={`banner banner--${a.level === "problem" ? "danger" : a.level === "warning" ? "warning" : "info"}`}
        >
          {a.level === "info" ? <Info size={18} aria-hidden /> : <TriangleAlert size={18} aria-hidden />}
          <span>{a.text}</span>
          {a.text.includes("Settings") && (
            <Link to={SETTINGS_PATH} className="banner__action">
              Settings
            </Link>
          )}
        </div>
      ))}

      <div className="cards">
        <article className="card">
          <h2 className="card__label">Home PC</h2>
          <p className="card__value">{health.isPending ? "…" : health.isError ? "Offline" : "Online"}</p>
          <p className="card__meta">{health.data ? health.data.homeName : " "}</p>
        </article>
        <article className="card">
          <h2 className="card__label">People</h2>
          <p className="card__value">{o ? number.format(o.people) : "…"}</p>
          <p className="card__meta">{o ? `${number.format(o.devices)} devices` : " "}</p>
        </article>
        <article className="card">
          <h2 className="card__label">Library</h2>
          <p className="card__value">{library.data ? number.format(library.data.tracks) : "…"}</p>
          <p className="card__meta">
            <Link to={LIBRARY_PATH} className="link">
              {library.data?.scanning
                ? "Reading new music…"
                : o
                  ? `songs · ${formatBytes(o.sizeBytes)} · ${o.losslessPercent}% lossless`
                  : "songs · open Library"}
            </Link>
          </p>
        </article>
        <article className="card">
          <h2 className="card__label">Server version</h2>
          <p className="card__value mono">{health.data ? health.data.serverVersion : "…"}</p>
          <p className="card__meta">
            API {health.data ? health.data.apiVersion : "…"} · apps from {health.data?.minAppVersion ?? "…"}
          </p>
        </article>
      </div>

      {(o ? o.developmentKeyActive : !session.data || session.data.needsSetup) && <DevelopmentKey />}

      {o && (
        <section className="panel" aria-labelledby="recent-h">
          <div className="panel__head">
            <h2 id="recent-h" className="panel__title">
              Recent activity
            </h2>
            <Link to={ACTIVITY_PATH} className="link">
              See all
            </Link>
          </div>
          <ActivityRows items={o.recent} />
        </section>
      )}
    </section>
  );
}
