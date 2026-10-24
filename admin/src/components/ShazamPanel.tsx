import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { type FormEvent, useState } from "react";

import { saveShazam, type ShazamSettingsUpdate, shazamQuery } from "../api/listen";
import { QueryError } from "./QueryError";

/** Shazam for songs that aren't at home, and the ShazamKit key Android needs. */
export function ShazamPanel() {
  const client = useQueryClient();
  const { data, error, refetch, isFetching } = useQuery(shazamQuery);
  const [teamId, setTeamId] = useState<string | null>(null);
  const [keyId, setKeyId] = useState<string | null>(null);
  const [key, setKey] = useState("");
  const save = useMutation({
    mutationFn: (body: ShazamSettingsUpdate) => saveShazam(body),
    onSuccess: (fresh) => {
      client.setQueryData(shazamQuery.queryKey, fresh);
      setTeamId(null);
      setKeyId(null);
      setKey("");
    },
  });

  function submit(e: FormEvent) {
    e.preventDefault();
    const body: ShazamSettingsUpdate = {};
    if (teamId !== null) body.teamId = teamId.trim().toUpperCase();
    if (keyId !== null) body.keyId = keyId.trim().toUpperCase();
    if (key.trim()) body.privateKey = key.trim();
    save.mutate(body);
  }

  const changed = teamId !== null || keyId !== null || key.trim() !== "";
  return (
    <section className="panel" aria-labelledby="shazam-h">
      <div className="panel__head">
        <h2 id="shazam-h" className="panel__title">
          Shazam for songs that aren&apos;t at home
        </h2>
        {data && (
          <label className="switch">
            <input
              type="checkbox"
              role="switch"
              aria-label="Shazam"
              checked={data.enabled}
              disabled={save.isPending}
              onChange={(e) => save.mutate({ enabled: e.target.checked })}
            />
            <span>{data.enabled ? "On" : "Off"}</span>
          </label>
        )}
      </div>
      <p className="note">
        When home doesn&apos;t know a song, Listen asks Shazam (Apple) and offers &ldquo;Ask to add it&rdquo;. The phone
        sends Apple a fingerprint of the sound, never the sound, and only after home couldn&apos;t name it. Off: Listen
        knows the songs at home only.
      </p>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {data && (
        <form className="form" onSubmit={submit}>
          <p className="note">
            iPhones, iPads and Macs need nothing more. <strong>Android phones</strong> need the ShazamKit key from the
            Apple Developer account (Certificates, IDs &amp; Profiles → Keys, with ShazamKit ticked):{" "}
            {data.androidReady ? "set, Android can use Shazam." : "not set yet."}
          </p>
          <div className="form__grid">
            <div className="field">
              <label htmlFor="shazam-team">Team ID</label>
              <input
                id="shazam-team"
                className="input mono"
                maxLength={10}
                placeholder="ABCDE12345"
                value={teamId ?? data.teamId ?? ""}
                onChange={(e) => setTeamId(e.target.value)}
              />
            </div>
            <div className="field">
              <label htmlFor="shazam-key-id">Key ID</label>
              <input
                id="shazam-key-id"
                className="input mono"
                maxLength={10}
                placeholder="XYZ9876543"
                value={keyId ?? data.keyId ?? ""}
                onChange={(e) => setKeyId(e.target.value)}
              />
            </div>
          </div>
          <div className="field">
            <label htmlFor="shazam-key">Key (the .p8 file&apos;s text)</label>
            <textarea
              id="shazam-key"
              className="input mono"
              rows={4}
              placeholder={data.keySet ? "Saved. Paste a new one to replace it." : "-----BEGIN PRIVATE KEY-----"}
              value={key}
              onChange={(e) => setKey(e.target.value)}
            />
            <p className="field__hint">It stays on this computer; the apps get hour-long tokens made from it.</p>
          </div>
          {save.error && <QueryError error={save.error} retry={() => save.reset()} />}
          <div className="actions">
            <button className="button button--primary" type="submit" disabled={!changed || save.isPending}>
              {save.isPending ? "Saving…" : "Save"}
            </button>
            {data.keySet && (
              <button
                className="link-button"
                type="button"
                disabled={save.isPending}
                onClick={() => save.mutate({ privateKey: "" })}
              >
                Remove the key
              </button>
            )}
          </div>
        </form>
      )}
    </section>
  );
}
