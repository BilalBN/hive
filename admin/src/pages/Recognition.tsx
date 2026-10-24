import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { CircleAlert, Music4, RotateCcw } from "lucide-react";

import { fetchRecognition, rebuildRecognition, type RecognitionStatus } from "../api/listen";
import { ago } from "../api/people";
import { QueryError } from "../components/QueryError";
import { ShazamPanel } from "../components/ShazamPanel";

const REQUESTS_PATH: string = "/requests";
const number = new Intl.NumberFormat();

export const recognitionQuery = {
  queryKey: ["recognition"],
  queryFn: fetchRecognition,
  refetchInterval: (q: { state: { data?: RecognitionStatus } }) => (q.state.data?.working ? 3000 : 30_000),
} as const;

function Coverage({ r }: { r: RecognitionStatus }) {
  const percent = r.tracks ? Math.floor((100 * r.fingerprinted) / r.tracks) : 100;
  return (
    <section className="panel" aria-labelledby="coverage-h">
      <h2 id="coverage-h" className="panel__title">
        Songs Listen can recognise
      </h2>
      <p className="recognition__figure">
        <strong>{number.format(r.fingerprinted)}</strong> of {number.format(r.tracks)}
        <span className="recognition__percent">{percent}%</span>
      </p>
      <div
        className={`progress ${percent === 100 ? "progress--success" : "progress--accent"}`}
        role="progressbar"
        aria-label="Songs fingerprinted"
        aria-valuenow={percent}
        aria-valuemin={0}
        aria-valuemax={100}
      >
        <span style={{ width: `${percent}%` }} />
      </div>
      <p className="note">
        {r.working || r.waiting > 0
          ? `Fingerprinting… ${number.format(r.waiting)} to go. Listen already knows the songs that are done.`
          : "Up to date. New music is fingerprinted as soon as it's added."}
        {r.failed > 0 &&
          ` ${number.format(r.failed)} ${r.failed === 1 ? "song" : "songs"} couldn't be fingerprinted (silent or unreadable).`}
      </p>
    </section>
  );
}

/** Fingerprint coverage, how Listen did this week, and starting the fingerprints over. */
export function RecognitionPage() {
  const client = useQueryClient();
  const { data: r, error, refetch, isFetching } = useQuery(recognitionQuery);
  const rebuild = useMutation({
    mutationFn: rebuildRecognition,
    onSuccess: (fresh) => client.setQueryData(recognitionQuery.queryKey, fresh),
  });
  const heard = r ? r.matchesThisWeek + r.noMatchThisWeek : 0;
  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Recognition</h1>
        <p className="page__summary">
          Listen in the apps recognises songs that are at home by their sound. Everything happens on this computer; the
          recordings are thrown away once matched.
        </p>
      </header>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {r && !r.ffmpeg && (
        <div className="banner banner--danger" role="alert">
          <CircleAlert size={18} aria-hidden />
          <span>Listen needs FFmpeg on the home computer. Install it, then restart Hive.</span>
        </div>
      )}
      {r && (
        <>
          <Coverage r={r} />
          <div className="cards">
            <article className="card">
              <h2 className="card__label">Found this week</h2>
              <p className="card__value">{number.format(r.matchesThisWeek)}</p>
              <p className="card__meta">
                {heard ? `of ${number.format(heard)} times someone used Listen` : "Nobody has used Listen this week"}
              </p>
            </article>
            <article className="card">
              <h2 className="card__label">Not at home</h2>
              <p className="card__value">{number.format(r.noMatchThisWeek)}</p>
              <p className="card__meta">Songs Listen heard that aren't in your music</p>
            </article>
            <article className="card">
              <h2 className="card__label">Songs asked for</h2>
              <p className="card__value">{number.format(r.requestsWaiting ?? 0)}</p>
              <p className="card__meta">
                <Link to={REQUESTS_PATH} className="link">
                  {r.requestsWaiting ? "Waiting on Requests" : "None waiting"}
                </Link>
              </p>
            </article>
          </div>
          <ShazamPanel />
          <section className="panel" aria-labelledby="rebuild-h">
            <h2 id="rebuild-h" className="panel__title">
              <Music4 size={18} aria-hidden /> Start the fingerprints over
            </h2>
            <p className="note">
              Only needed if Listen keeps missing songs you know are at home, or after a Hive update says to. Listen
              misses songs until it's finished again
              {r.rebuiltAt ? ` (last started over ${ago(r.rebuiltAt)})` : ""}.
            </p>
            {rebuild.error && <p className="note note--error">{rebuild.error.message}</p>}
            <div className="actions">
              <button
                className="button button--secondary"
                type="button"
                disabled={rebuild.isPending || r.tracks === 0}
                onClick={() => {
                  if (
                    globalThis.confirm?.("Fingerprint every song again? Listen misses songs until it's done.") ??
                    true
                  )
                    rebuild.mutate();
                }}
              >
                <RotateCcw size={16} aria-hidden /> Start over
              </button>
            </div>
          </section>
        </>
      )}
    </section>
  );
}
