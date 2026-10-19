import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, MonitorSmartphone, Undo2, X } from "lucide-react";
import { useEffect, useState } from "react";

import {
  type AdminAccessRequest,
  type AdminRequests,
  ago,
  approveRequest,
  declineRequest,
  fetchRequests,
  PLATFORM,
  undoDecision,
  until,
} from "../api/people";
import { QueryError } from "../components/QueryError";

export const requestsQuery = {
  queryKey: ["requests"],
  queryFn: fetchRequests,
  refetchInterval: 5000,
} as const;

function useNow(ms = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}

function Waiting({ r }: { r: AdminAccessRequest }) {
  const client = useQueryClient();
  const [name, setName] = useState("");
  const refresh = () => {
    client.invalidateQueries({ queryKey: requestsQuery.queryKey });
    client.invalidateQueries({ queryKey: ["overview"] });
  };
  const approve = useMutation({
    mutationFn: () => approveRequest(r.id, name.trim() || undefined),
    onSuccess: refresh,
  });
  const decline = useMutation({
    mutationFn: () => declineRequest(r.id),
    onSuccess: refresh,
  });
  const busy = approve.isPending || decline.isPending;
  return (
    <li className="row row--request">
      <span className="row__icon" aria-hidden>
        <MonitorSmartphone size={16} />
      </span>
      <div className="row__text">
        <p className="row__title">{r.email}</p>
        <p className="row__meta">
          {r.deviceName} · {PLATFORM[r.platform]} · {ago(r.createdAt)}
          {r.existingPerson ? " · already in Hive, adding a device" : ""}
        </p>
        {r.note && <p className="row__meta">“{r.note}”</p>}
        {!r.existingPerson && (
          <input
            className="input input--small"
            aria-label={`Name for ${r.email}`}
            placeholder="Name in Hive (optional)"
            maxLength={80}
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
        )}
        {(approve.error || decline.error) && (
          <p className="note note--error">{(approve.error ?? decline.error)!.message}</p>
        )}
      </div>
      <div className="row__actions">
        <button className="button button--secondary" type="button" disabled={busy} onClick={() => decline.mutate()}>
          <X size={16} aria-hidden /> Decline
        </button>
        <button className="button button--primary" type="button" disabled={busy} onClick={() => approve.mutate()}>
          <Check size={16} aria-hidden /> Approve
        </button>
      </div>
    </li>
  );
}

function Decided({ r, now }: { r: AdminAccessRequest; now: number }) {
  const client = useQueryClient();
  const undo = useMutation({
    mutationFn: () => undoDecision(r.id),
    onSuccess: () => client.invalidateQueries({ queryKey: requestsQuery.queryKey }),
  });
  const canUndo = r.undoUntil && new Date(r.undoUntil).getTime() > now;
  const seconds = canUndo ? Math.ceil((new Date(r.undoUntil!).getTime() - now) / 1000) : 0;
  return (
    <li className="row">
      <span className={`dot ${r.status === "approved" ? "dot--online" : "dot--offline"}`} aria-hidden />
      <div className="row__text">
        <p className="row__title">{r.email}</p>
        <p className="row__meta">
          {r.status === "approved" ? "Approved" : "Declined"}
          {r.invited ? " (invited)" : ""} · {r.deviceName} · {ago(r.decidedAt ?? r.createdAt, now)}
        </p>
      </div>
      {canUndo && (
        <button
          className="button button--secondary"
          type="button"
          disabled={undo.isPending}
          onClick={() => undo.mutate()}
        >
          <Undo2 size={16} aria-hidden /> Undo ({seconds})
        </button>
      )}
    </li>
  );
}

function Codes({ data, now }: { data: AdminRequests; now: number }) {
  if (!data.codes.length) return null;
  return (
    <section className="panel panel--accent" aria-labelledby="codes-h">
      <h2 id="codes-h" className="panel__title">
        Codes to pass on
      </h2>
      <p className="note">
        Email isn't set up yet, so Hive can't send these. Tell each person their code (a message or a call is fine). Set
        up email in Settings to send them automatically.
      </p>
      <ul className="rows">
        {data.codes.map((c) => (
          <li key={`${c.email}-${c.code}`} className="row">
            <div className="row__text">
              <p className="row__title">{c.email}</p>
              <p className="row__meta">
                {c.purpose === "admin" ? "Admin sign-in" : "Joining Hive"} · {until(c.expiresAt, now)}
              </p>
            </div>
            <code className="code-chip mono">{c.code}</code>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** People and devices waiting to be let in, with what was decided lately. */
export function RequestsPage() {
  const { data, error, refetch, isFetching } = useQuery(requestsQuery);
  const now = useNow();
  const waiting = data?.items.filter((r) => r.status === "pending") ?? [];
  const decided = data?.items.filter((r) => r.status !== "pending") ?? [];
  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Requests</h1>
        <p className="page__summary">
          People who proved their email and want in. Invited people are let in automatically.
        </p>
      </header>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {data && (
        <>
          <Codes data={data} now={now} />
          <section className="panel" aria-labelledby="waiting-h">
            <h2 id="waiting-h" className="panel__title">
              Waiting
            </h2>
            {waiting.length ? (
              <ul className="rows">
                {waiting.map((r) => (
                  <Waiting key={r.id} r={r} />
                ))}
              </ul>
            ) : (
              <p className="note">Nobody is waiting. Invite someone and they'll be let in as soon as they join.</p>
            )}
          </section>
          {decided.length > 0 && (
            <section className="panel" aria-labelledby="decided-h">
              <h2 id="decided-h" className="panel__title">
                Recently decided
              </h2>
              <ul className="rows">
                {decided.map((r) => (
                  <Decided key={r.id} r={r} now={now} />
                ))}
              </ul>
            </section>
          )}
        </>
      )}
    </section>
  );
}
