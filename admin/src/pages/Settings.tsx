import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Mail, ShieldCheck } from "lucide-react";
import { type FormEvent, useState } from "react";

import {
  type AdminSettings,
  type AdminSettingsEdit,
  type AuthenticatorSetup,
  confirmAuthenticator,
  fetchSettings,
  removeAuthenticator,
  startAuthenticator,
  testEmail,
  updateSettings,
} from "../api/people";
import { QueryError } from "../components/QueryError";
import { sessionQuery } from "../components/SignIn";
import { Qr } from "./Invite";

/** 127.0.0.1 and localhost mean "this computer": no use to a phone. */
export function isLoopback(address: string): boolean {
  return /^(https?:\/\/)?(127\.|localhost\b|\[::1\])/i.test(address.trim());
}

export const settingsQuery = {
  queryKey: ["settings"],
  queryFn: fetchSettings,
} as const;

function useSave() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (body: AdminSettingsEdit) => updateSettings(body),
    onSuccess: (s) => {
      client.setQueryData(settingsQuery.queryKey, s);
      client.invalidateQueries({ queryKey: ["overview"] });
      client.invalidateQueries({ queryKey: sessionQuery.queryKey });
    },
  });
}

function Saved({ show }: { show: boolean }) {
  return show ? (
    <span className="saved" role="status">
      Saved
    </span>
  ) : null;
}

function Home({ s }: { s: AdminSettings }) {
  const save = useSave();
  const [homeName, setHomeName] = useState(s.homeName);
  const [address, setAddress] = useState(s.address ?? "");
  const [link, setLink] = useState(s.privateNetworkLink ?? "");
  const [devices, setDevices] = useState(s.devicesPerPerson);
  const [swaps, setSwaps] = useState(s.swapsPerMonth);
  const submit = (e: FormEvent) => {
    e.preventDefault();
    // Only what changed: the address shown may be Hive's own guess, not a saved one.
    const body: AdminSettingsEdit = {};
    if (homeName.trim() !== s.homeName) body.homeName = homeName.trim();
    if (address.trim() !== (s.address ?? "")) body.address = address.trim();
    if (link.trim() !== (s.privateNetworkLink ?? "")) body.privateNetworkLink = link.trim();
    if (devices !== s.devicesPerPerson) body.devicesPerPerson = devices;
    if (swaps !== s.swapsPerMonth) body.swapsPerMonth = swaps;
    save.mutate(body);
  };
  const loopback = isLoopback(address);

  return (
    <form className="panel form" onSubmit={submit} aria-labelledby="home-h">
      <h2 id="home-h" className="panel__title">
        Home
      </h2>
      <div className="form__grid">
        <div className="field">
          <label className="field__control">
            <span>Home name</span>
            <input
              className="input"
              required
              maxLength={60}
              value={homeName}
              onChange={(e) => setHomeName(e.target.value)}
            />
          </label>
          <span className="field__hint">Shown in the apps, e.g. “Connected to {homeName || "home"}”.</span>
        </div>
        <div className="field">
          <label className="field__control">
            <span>Address for the apps</span>
            <input
              className="input mono"
              placeholder="http://100.84.12.7:8443"
              value={address}
              onChange={(e) => setAddress(e.target.value)}
            />
          </label>
          <span className={`field__hint${loopback ? " note--warning" : ""}`}>
            {loopback
              ? "This only works on this computer. Type its Tailscale address instead, like http://100.84.12.7:8443."
              : "This computer's private-network address. Invites carry it."}
          </span>
        </div>
        <div className="field">
          <label className="field__control">
            <span>Private-network link</span>
            <input
              className="input mono"
              placeholder="https://login.tailscale.com/…"
              value={link}
              onChange={(e) => setLink(e.target.value)}
            />
          </label>
          <span className="field__hint">Your Tailscale share link for this computer, included with invites.</span>
        </div>
        <label className="field">
          <span>Devices per person</span>
          <input
            className="input"
            type="number"
            min={1}
            max={20}
            value={devices}
            onChange={(e) => setDevices(Number(e.target.value))}
          />
        </label>
        <div className="field">
          <label className="field__control">
            <span>Device swaps per 30 days</span>
            <input
              className="input"
              type="number"
              min={0}
              max={20}
              value={swaps}
              onChange={(e) => setSwaps(Number(e.target.value))}
            />
          </label>
          <span className="field__hint">Removing a device to add another. You can always override for someone.</span>
        </div>
      </div>
      {save.error && <p className="note note--error">{save.error.message}</p>}
      <div className="actions">
        <button className="button button--primary" type="submit" disabled={save.isPending}>
          Save
        </button>
        <Saved show={save.isSuccess} />
      </div>
    </form>
  );
}

function Email({ s }: { s: AdminSettings }) {
  const save = useSave();
  const e0 = s.email;
  const [host, setHost] = useState(e0.host);
  const [port, setPort] = useState(e0.port);
  const [security, setSecurity] = useState(e0.security);
  const [username, setUsername] = useState(e0.username);
  const [password, setPassword] = useState("");
  const [from, setFrom] = useState(e0.from);
  const [to, setTo] = useState("");
  const test = useMutation({
    mutationFn: () => testEmail(to.trim() || undefined),
  });

  const gmail = () => {
    setHost("smtp.gmail.com");
    setPort(587);
    setSecurity("starttls");
    if (!from && username) setFrom(username);
  };
  const submit = (e: FormEvent) => {
    e.preventDefault();
    test.reset();
    save.mutate({
      email: {
        host: host.trim(),
        port,
        security,
        username: username.trim(),
        from: (from || username).trim(),
        ...(password ? { password } : {}),
      },
    });
    setPassword("");
  };

  return (
    <form className="panel form" onSubmit={submit} aria-labelledby="email-h">
      <div className="panel__head">
        <h2 id="email-h" className="panel__title">
          Email
        </h2>
        <span className={`tag ${s.email.ready ? "tag--success" : "tag--warning"}`}>
          {s.email.ready ? "Ready" : "Not set up"}
        </span>
      </div>
      <p className="note">
        Hive sends sign-in codes, invites and “someone is waiting” notes from your own email account. Notes never say
        who or what. With Gmail: turn on 2-Step Verification, then make an app password at
        myaccount.google.com/apppasswords and paste it below.
      </p>
      <div className="actions">
        <button className="button button--secondary" type="button" onClick={gmail}>
          <Mail size={16} aria-hidden /> Use Gmail settings
        </button>
      </div>
      <div className="form__grid">
        <label className="field">
          <span>Email address (sign-in)</span>
          <input
            className="input"
            type="email"
            autoComplete="off"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
        </label>
        <label className="field">
          <span>App password</span>
          <input
            className="input mono"
            type="password"
            autoComplete="new-password"
            placeholder={e0.passwordSet ? "Saved (type to replace)" : "16 letters from Google"}
            value={password}
            onChange={(e) => setPassword(e.target.value.replace(/\s/g, ""))}
          />
        </label>
        <label className="field">
          <span>Mail server</span>
          <input className="input mono" value={host} onChange={(e) => setHost(e.target.value)} />
        </label>
        <label className="field">
          <span>Port</span>
          <input
            className="input"
            type="number"
            min={1}
            max={65535}
            value={port}
            onChange={(e) => setPort(Number(e.target.value))}
          />
        </label>
        <label className="field">
          <span>Security</span>
          <select
            className="input"
            value={security}
            onChange={(e) => setSecurity(e.target.value as AdminSettings["email"]["security"])}
          >
            <option value="starttls">STARTTLS (port 587)</option>
            <option value="ssl">SSL (port 465)</option>
            <option value="none">None</option>
          </select>
        </label>
        <label className="field">
          <span>From</span>
          <input
            className="input"
            type="email"
            placeholder={username}
            value={from}
            onChange={(e) => setFrom(e.target.value)}
          />
        </label>
      </div>
      {save.error && <p className="note note--error">{save.error.message}</p>}
      <div className="actions">
        <button className="button button--primary" type="submit" disabled={save.isPending}>
          Save
        </button>
        <Saved show={save.isSuccess} />
      </div>
      <div className="test-email">
        <label className="field">
          <span>Send a test to</span>
          <input
            className="input"
            type="email"
            placeholder="Your own email"
            value={to}
            onChange={(e) => setTo(e.target.value)}
          />
        </label>
        <button
          className="button button--secondary"
          type="button"
          disabled={!s.email.ready || test.isPending}
          onClick={() => test.mutate()}
        >
          {test.isPending ? "Sending…" : "Send test email"}
        </button>
      </div>
      {test.data && <p className={`note ${test.data.ok ? "" : "note--error"}`}>{test.data.message}</p>}
      {test.error && <p className="note note--error">{test.error.message}</p>}
    </form>
  );
}

function SignInSecurity() {
  const client = useQueryClient();
  const session = useQuery(sessionQuery);
  const [setup, setSetup] = useState<AuthenticatorSetup | null>(null);
  const [code, setCode] = useState("");
  const start = useMutation({
    mutationFn: startAuthenticator,
    onSuccess: setSetup,
  });
  const confirm = useMutation({
    mutationFn: () => confirmAuthenticator(code),
    onSuccess: (s) => {
      client.setQueryData(sessionQuery.queryKey, s);
      client.invalidateQueries({ queryKey: ["overview"] });
      setSetup(null);
      setCode("");
    },
  });
  const remove = useMutation({
    mutationFn: removeAuthenticator,
    onSuccess: (s) => client.setQueryData(sessionQuery.queryKey, s),
  });
  const s = session.data;
  if (!s) return null;
  if (!s.me) {
    return (
      <section className="panel" aria-labelledby="signin-h">
        <h2 id="signin-h" className="panel__title">
          Your sign-in
        </h2>
        <p className="note">Set up the first admin (Overview) before adding an authenticator.</p>
      </section>
    );
  }
  return (
    <section className="panel" aria-labelledby="signin-h">
      <div className="panel__head">
        <h2 id="signin-h" className="panel__title">
          Your sign-in
        </h2>
        <span className={`tag ${s.me.authenticator ? "tag--success" : "tag--warning"}`}>
          {s.me.authenticator ? "Authenticator on" : "No authenticator"}
        </span>
      </div>
      <p className="note">
        Away from the home computer you sign in with a code sent to {s.me.email} and a code from an authenticator app
        (Google Authenticator, Microsoft Authenticator, 1Password and the like).
      </p>
      {setup ? (
        <div className="invite">
          <Qr text={setup.uri} label="QR code to add Hive to your authenticator app" />
          <div className="invite__text">
            <ol className="steps">
              <li>In your authenticator app, add an account and scan this QR.</li>
              <li>
                Can't scan? Type this key: <code className="mono">{setup.secret}</code>
              </li>
              <li>Type the 6-digit code it shows for Hive.</li>
            </ol>
            <div className="inline-form">
              <input
                className="input input--small mono"
                inputMode="numeric"
                maxLength={6}
                aria-label="Code from the authenticator app"
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
              />
              <button
                className="button button--primary"
                type="button"
                disabled={code.length !== 6 || confirm.isPending}
                onClick={() => confirm.mutate()}
              >
                Confirm
              </button>
              <button className="link-button" type="button" onClick={() => setSetup(null)}>
                Cancel
              </button>
            </div>
            {confirm.error && <p className="note note--error">{confirm.error.message}</p>}
          </div>
        </div>
      ) : (
        <div className="actions">
          <button
            className="button button--secondary"
            type="button"
            disabled={start.isPending}
            onClick={() => start.mutate()}
          >
            <ShieldCheck size={16} aria-hidden />{" "}
            {s.me.authenticator ? "Replace authenticator" : "Set up authenticator"}
          </button>
          {s.me.authenticator && s.onHomeComputer && (
            <button className="link-button" type="button" disabled={remove.isPending} onClick={() => remove.mutate()}>
              Remove authenticator
            </button>
          )}
        </div>
      )}
      {start.error && <p className="note note--error">{start.error.message}</p>}
    </section>
  );
}

/** Names, limits, email and how you sign in. */
export function SettingsPage() {
  const { data, error, refetch, isFetching } = useQuery(settingsQuery);
  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Settings</h1>
        <p className="page__summary">Names, limits, email and how you sign in.</p>
      </header>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {data && (
        // Re-seed the forms when the saved settings change underneath them.
        <div key={`${data.homeName}|${data.email.ready}|${data.email.passwordSet}`} className="stack">
          <Home s={data} />
          <Email s={data} />
          <SignInSecurity />
        </div>
      )}
    </section>
  );
}
