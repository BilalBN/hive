import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { type FormEvent, useState } from "react";

import { type AdminPushUpdate, pushQuery, savePush, testPush } from "../api/push";
import { QueryError } from "./QueryError";

/** Notifications: how they reach phones, the Apple push key, and a test. */
export function PushPanel() {
  const client = useQueryClient();
  const { data } = useQuery(pushQuery);
  const [teamId, setTeamId] = useState<string | null>(null);
  const [keyId, setKeyId] = useState<string | null>(null);
  const [key, setKey] = useState("");
  const save = useMutation({
    mutationFn: (body: AdminPushUpdate) => savePush(body),
    onSuccess: (fresh) => {
      client.setQueryData(pushQuery.queryKey, fresh);
      setTeamId(null);
      setKeyId(null);
      setKey("");
    },
  });
  const test = useMutation({ mutationFn: testPush });
  if (!data) return null;

  function submit(e: FormEvent) {
    e.preventDefault();
    const body: AdminPushUpdate = {};
    if (teamId !== null) body.teamId = teamId.trim().toUpperCase();
    if (keyId !== null) body.keyId = keyId.trim().toUpperCase();
    if (key.trim()) body.privateKey = key.trim();
    save.mutate(body);
  }
  const changed = teamId !== null || keyId !== null || key.trim() !== "";

  return (
    <section className="panel" aria-labelledby="push-h">
      <h2 id="push-h" className="panel__title">
        Notifications
      </h2>
      <p className="note">
        Hive lets people know about new music, songs they asked for and (for admins) things waiting for you. A
        notification never says who or what. Open apps hear them at once; Android phones while Hive is closed through a
        UnifiedPush app such as ntfy (each person turns it on in the app&apos;s Settings).
      </p>
      <p className="note">
        <strong>iPhones and iPads</strong> while Hive is closed need an APNs key from the Apple Developer account
        (Certificates, IDs &amp; Profiles → Keys, with Apple Push Notifications ticked):{" "}
        {data.apnsReady ? "set." : "not set yet."}
      </p>
      <form className="form" onSubmit={submit}>
        <div className="form__grid">
          <div className="field">
            <label htmlFor="push-team">Team ID</label>
            <input
              id="push-team"
              className="input mono"
              maxLength={10}
              value={teamId ?? data.teamId ?? ""}
              onChange={(e) => setTeamId(e.target.value)}
            />
          </div>
          <div className="field">
            <label htmlFor="push-key-id">Key ID</label>
            <input
              id="push-key-id"
              className="input mono"
              maxLength={10}
              value={keyId ?? data.keyId ?? ""}
              onChange={(e) => setKeyId(e.target.value)}
            />
          </div>
        </div>
        <div className="field">
          <label htmlFor="push-key">APNs key (the .p8 file&apos;s text)</label>
          <textarea
            id="push-key"
            className="input mono"
            rows={4}
            placeholder={data.keySet ? "Saved. Paste a new one to replace it." : "-----BEGIN PRIVATE KEY-----"}
            value={key}
            onChange={(e) => setKey(e.target.value)}
          />
        </div>
        {save.error && <QueryError error={save.error} retry={() => save.reset()} />}
        <div className="actions">
          <button className="button button--primary" type="submit" disabled={!changed || save.isPending}>
            {save.isPending ? "Saving…" : "Save the key"}
          </button>
          <button
            className="button button--secondary"
            type="button"
            disabled={test.isPending}
            onClick={() => test.mutate()}
          >
            Send a test notification
          </button>
        </div>
        {test.data && (
          <p className="note">
            {test.data.sent
              ? "Sent to the admins' devices. It should arrive within a few seconds."
              : "No admin takes notifications yet."}
          </p>
        )}
      </form>
    </section>
  );
}
