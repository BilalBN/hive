import { useQuery } from "@tanstack/react-query";
import { CircleAlert, RefreshCw } from "lucide-react";

import { healthQuery } from "../components/ServerStatus";

function formatTime(iso: string): string {
  return new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

/**
 * M0 Overview: is home running? The full dashboard (requests, storage, network,
 * backups, activity) arrives in M2.
 */
export function Overview() {
  const { data, isPending, isError, refetch, isFetching } = useQuery(healthQuery);

  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Overview</h1>
        <p className="page__summary">
          {isPending ? "Checking home…" : isError ? "Can't reach the server." : "Home is running."}
        </p>
      </header>

      {isError && (
        <div className="banner banner--danger" role="alert">
          <CircleAlert size={18} aria-hidden />
          <span>The admin panel can't reach the Hive server. Check that it is running on the home PC.</span>
          <button className="button button--secondary" type="button" onClick={() => refetch()} disabled={isFetching}>
            <RefreshCw size={16} aria-hidden /> Try again
          </button>
        </div>
      )}

      <div className="cards">
        <article className="card">
          <h2 className="card__label">Home PC</h2>
          <p className="card__value">{isPending ? "…" : isError ? "Offline" : "Online"}</p>
          <p className="card__meta">{data ? data.homeName : " "}</p>
        </article>
        <article className="card">
          <h2 className="card__label">Server version</h2>
          <p className="card__value mono">{data ? data.serverVersion : "…"}</p>
          <p className="card__meta">API {data ? data.apiVersion : "…"}</p>
        </article>
        <article className="card">
          <h2 className="card__label">Oldest app allowed</h2>
          <p className="card__value mono">{data?.minAppVersion ?? "…"}</p>
          <p className="card__meta">Older apps are asked to update</p>
        </article>
        <article className="card">
          <h2 className="card__label">Server clock</h2>
          <p className="card__value card__value--small">{data ? formatTime(data.serverTime) : "…"}</p>
          <p className="card__meta">Apps sync their position to this</p>
        </article>
      </div>

      <p className="note">Requests, storage, the private network and recent activity join this page in M2.</p>
    </section>
  );
}
