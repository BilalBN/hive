import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { Globe, Loader } from "lucide-react";
import { useId, useState } from "react";

import { type AcoustidTest, fetchLookup, type LookupStatus, retryLookup, testAcoustid, updateLookup } from "../api/client";
import { QueryError } from "./QueryError";

export const lookupQuery = {
  queryKey: ["lookup"],
  queryFn: fetchLookup,
  refetchInterval: (q: { state: { data?: LookupStatus } }) =>
    q.state.data?.enabled && (q.state.data.working || q.state.data.waiting > 0) ? 3000 : 20000,
} as const;

const number = new Intl.NumberFormat();

function summary(s: LookupStatus): string {
  if (!s.enabled) return "Off. Albums show what their files say, and nothing is looked up.";
  const parts = [`${number.format(s.found)} filled in`];
  if (s.soundMatches) parts.push(`${number.format(s.soundMatches)} recognised by sound`);
  if (s.review) parts.push(`${number.format(s.review)} to check`);
  if (s.notFound) parts.push(`${number.format(s.notFound)} not found`);
  if (s.failed) parts.push(`${number.format(s.failed)} couldn't be looked up`);
  if (s.waiting) parts.push(`${number.format(s.waiting)} waiting`);
  return parts.join(" · ");
}

/** The online lookup: on/off, progress, what leaves home, and an optional AcoustID key. */
export function LookupPanel() {
  const client = useQueryClient();
  const { data, error, refetch, isFetching } = useQuery(lookupQuery);
  const [key, setKey] = useState("");
  const keyId = useId();
  const save = (status: LookupStatus) => client.setQueryData(lookupQuery.queryKey, status);
  const toggle = useMutation({ mutationFn: (enabled: boolean) => updateLookup({ enabled }), onSuccess: save });
  const [tested, setTested] = useState<AcoustidTest | null>(null);
  const test = useMutation({
    mutationFn: testAcoustid,
    onSuccess: (r) => {
      setTested(r);
      save(r.status);
    },
  });
  const setAcoustid = useMutation({
    mutationFn: (acoustidKey: string) => updateLookup({ acoustidKey }),
    onSuccess: (s, acoustidKey) => {
      save(s);
      setKey("");
      setTested(null);
      // A new key is tried straight away, so a typo shows now rather than later.
      if (acoustidKey && s.fingerprinting) test.mutate();
    },
  });
  const retry = useMutation({ mutationFn: () => retryLookup({ all: true }), onSuccess: save });

  return (
    <section className="panel" aria-labelledby="lookup-h">
      <div className="panel__head">
        <h2 id="lookup-h" className="panel__title">
          <Globe size={18} aria-hidden /> Album details from the internet
        </h2>
        {data && (
          <label className="switch">
            <input
              type="checkbox"
              role="switch"
              checked={data.enabled}
              disabled={toggle.isPending}
              onChange={(e) => toggle.mutate(e.target.checked)}
            />
            <span>{data.enabled ? "On" : "Off"}</span>
          </label>
        )}
      </div>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {toggle.error && <QueryError error={toggle.error} retry={() => toggle.reset()} />}
      {data && (
        <>
          <p className="lookup__summary">
            {data.working && <Loader size={14} className="spin" aria-hidden />} {summary(data)}
          </p>
          <p className="note">
            Covers, language, film, cast and composers for each album, once, from MusicBrainz, Cover Art Archive and
            Wikidata. {data.sends}
          </p>
          {data.lastError && (
            <p className="note note--warning" role="status">
              Paused: {data.lastError}. It carries on by itself when the connection is back.
            </p>
          )}
          <div className="actions">
            {data.review > 0 && (
              <Link to="/albums" search={{ filter: "review" }} className="button button--primary">
                Check {number.format(data.review)} {data.review === 1 ? "match" : "matches"}
              </Link>
            )}
            {data.notFound + data.failed > 0 && (
              <button
                className="button button--secondary"
                type="button"
                disabled={retry.isPending || !data.enabled}
                onClick={() => retry.mutate()}
              >
                Look up again
              </button>
            )}
            <Link to="/albums" search={{ filter: "all" }} className="button button--secondary">
              Albums
            </Link>
          </div>
          <details className="details">
            <summary>
              {data.acoustidKey && data.fingerprinting
                ? "Recognising songs with no useful tags by their sound: on"
                : "Recognise songs with no useful tags by their sound (optional)"}
            </summary>
            <p className="note">
              With a free AcoustID application key and Chromaprint's <code>fpcalc</code> on the home computer (
              <code>brew install chromaprint</code>), Hive can recognise songs named "Track 01" by a fingerprint of their
              sound. Register an application at <span className="mono">acoustid.org/new-application</span> (any name, such
              as Hive) and paste the API key shown for that application, not the key for your own account.
              {data.acoustidKey && data.fingerprinting
                ? " Both are in place. It's used only for albums whose names alone weren't enough."
                : data.fingerprinting
                  ? " fpcalc is installed; add the key below."
                  : " fpcalc wasn't found on the home computer yet."}
            </p>
            {data.acoustidKey && data.fingerprinting && (
              <div className="actions">
                <button
                  className="button button--secondary"
                  type="button"
                  disabled={test.isPending}
                  onClick={() => test.mutate()}
                >
                  {test.isPending ? "Testing…" : "Test it"}
                </button>
                <span
                  className={(tested ? !tested.ok : !!data.acoustidProblem) ? "note note--error" : "note"}
                  role="status"
                >
                  {tested
                    ? tested.message
                    : data.acoustidProblem
                      ? data.acoustidProblem
                      : data.acoustidUsedAt
                        ? `Working. AcoustID last answered ${new Date(data.acoustidUsedAt).toLocaleString()}.`
                        : "Not used yet. Test it to check the key and fpcalc together."}
                </span>
              </div>
            )}
            {test.error && <QueryError error={test.error} retry={() => test.mutate()} />}
            <form
              className="key-form"
              onSubmit={(e) => {
                e.preventDefault();
                if (key.trim()) setAcoustid.mutate(key.trim());
              }}
            >
              <label htmlFor={keyId}>{data.acoustidKey ? "AcoustID key is set" : "AcoustID key"}</label>
              <input
                id={keyId}
                className="input mono"
                value={key}
                onChange={(e) => setKey(e.target.value)}
                placeholder={data.acoustidKey ? "Enter a new key to replace it" : "Paste the application key"}
                maxLength={64}
                autoComplete="off"
              />
              <button className="button button--secondary" type="submit" disabled={!key.trim() || setAcoustid.isPending}>
                Save key
              </button>
              {data.acoustidKey && (
                <button className="link-button" type="button" onClick={() => setAcoustid.mutate("")}>
                  Remove key
                </button>
              )}
            </form>
            {setAcoustid.error && <QueryError error={setAcoustid.error} retry={() => setAcoustid.reset()} />}
          </details>
        </>
      )}
    </section>
  );
}
