import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { Check, Copy, Trash2, UserPlus } from "lucide-react";
import QRCode from "qrcode";
import { type FormEvent, useEffect, useState } from "react";

import { type AdminInvite, createInvite, fetchInvites, revokeInvite, until } from "../api/people";
import { QueryError } from "../components/QueryError";
import { isLoopback } from "./Settings";

const SETTINGS_PATH: string = "/settings";

export const invitesQuery = {
  queryKey: ["invites"],
  queryFn: fetchInvites,
} as const;

function CopyButton({ text, label = "Copy" }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      className="button button--secondary"
      type="button"
      onClick={async () => {
        await navigator.clipboard?.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
      }}
    >
      {copied ? <Check size={16} aria-hidden /> : <Copy size={16} aria-hidden />}
      {copied ? "Copied" : label}
    </button>
  );
}

/** The Hive code as a QR the app scans. */
export function Qr({ text, label }: { text: string; label: string }) {
  const [svg, setSvg] = useState("");
  useEffect(() => {
    let live = true;
    QRCode.toString(text, { type: "svg", margin: 1, errorCorrectionLevel: "M" })
      .then((s) => live && setSvg(s))
      .catch(() => live && setSvg(""));
    return () => {
      live = false;
    };
  }, [text]);
  return <div className="qr" role="img" aria-label={label} dangerouslySetInnerHTML={{ __html: svg }} />;
}

function joinAddress(link?: string): string {
  try {
    return link ? (new URL(link).searchParams.get("a") ?? "") : "";
  } catch {
    return "";
  }
}

function Created({ invite, onDone }: { invite: AdminInvite; onDone: () => void }) {
  const address = joinAddress(invite.joinLink);
  const steps = [
    invite.privateNetworkLink
      ? "Open the private-network link and join (install Tailscale first if asked)."
      : "Get them on your private network (Tailscale): share your home computer with them.",
    "Install Hive on their phone or computer.",
    "In Hive, scan this QR or type the code. Then they confirm their email.",
  ];
  return (
    <section className="panel panel--accent" aria-labelledby="created-h">
      <h2 id="created-h" className="panel__title">
        Invite ready
        {invite.name ? ` for ${invite.name}` : invite.email ? ` for ${invite.email}` : ""}
      </h2>
      <p className="note">
        The code is shown once. {until(invite.expiresAt)}.
        {invite.email ? " They're let in as soon as they confirm this email." : " You'll approve them on Requests."}
      </p>
      {isLoopback(address) && (
        <p className="note note--warning">
          This invite points at {address}, which only works on this computer. Set the address for the apps in{" "}
          <Link to={SETTINGS_PATH} className="link">
            Settings
          </Link>
          , cancel this invite and make a new one.
        </p>
      )}
      <div className="invite">
        {invite.joinLink && <Qr text={invite.joinLink} label={`QR code for the Hive invite ${invite.code}`} />}
        <div className="invite__text">
          <p className="invite__code mono">{invite.code}</p>
          <ol className="steps">
            {steps.map((s) => (
              <li key={s}>{s}</li>
            ))}
          </ol>
          <div className="actions">
            {invite.code && <CopyButton text={invite.code} label="Copy code" />}
            {invite.privateNetworkLink && (
              <CopyButton text={invite.privateNetworkLink} label="Copy private-network link" />
            )}
            <button className="button button--secondary" type="button" onClick={onDone}>
              Done
            </button>
          </div>
          {!invite.privateNetworkLink && (
            <p className="note">
              Add your Tailscale share link in{" "}
              <Link to={SETTINGS_PATH} className="link">
                Settings
              </Link>{" "}
              and it's included with every invite.
            </p>
          )}
        </div>
      </div>
    </section>
  );
}

function InviteRow({ invite }: { invite: AdminInvite }) {
  const client = useQueryClient();
  const revoke = useMutation({
    mutationFn: () => revokeInvite(invite.id),
    onSuccess: () => client.invalidateQueries({ queryKey: invitesQuery.queryKey }),
  });
  return (
    <li className="row">
      <div className="row__text">
        <p className="row__title">{invite.name ?? invite.email ?? "Anyone with the code"}</p>
        <p className="row__meta">
          {[invite.name && invite.email, invite.role === "admin" ? "Admin" : "Member", until(invite.expiresAt)]
            .filter(Boolean)
            .join(" · ")}
        </p>
      </div>
      <button
        className="button button--secondary"
        type="button"
        disabled={revoke.isPending}
        onClick={() => revoke.mutate()}
      >
        <Trash2 size={16} aria-hidden /> Cancel invite
      </button>
    </li>
  );
}

/** Invite someone: a Hive code (and QR) plus the private-network link. */
export function InvitePage() {
  const client = useQueryClient();
  const list = useQuery(invitesQuery);
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<"member" | "admin">("member");
  const [days, setDays] = useState(7);
  const [created, setCreated] = useState<AdminInvite | null>(null);
  const create = useMutation({
    mutationFn: () =>
      createInvite({
        ...(name.trim() ? { name: name.trim() } : {}),
        ...(email.trim() ? { email: email.trim() } : {}),
        role,
        days,
      }),
    onSuccess: (inv) => {
      setCreated(inv);
      setName("");
      setEmail("");
      client.invalidateQueries({ queryKey: invitesQuery.queryKey });
    },
  });
  const submit = (e: FormEvent) => {
    e.preventDefault();
    create.mutate();
  };

  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Invite</h1>
        <p className="page__summary">Invite someone with a private-network link and a Hive code.</p>
      </header>

      {created ? (
        <Created invite={created} onDone={() => setCreated(null)} />
      ) : (
        <form className="panel form" onSubmit={submit}>
          <div className="form__grid">
            <label className="field">
              <span>Name</span>
              <input className="input" maxLength={80} value={name} onChange={(e) => setName(e.target.value)} />
            </label>
            <div className="field">
              <label className="field__control">
                <span>Email</span>
                <input
                  className="input"
                  type="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  aria-describedby="email-hint"
                />
              </label>
              <span className="field__hint" id="email-hint">
                With an email, they're let in when they confirm it. Without one, you approve them.
              </span>
            </div>
            <label className="field">
              <span>Role</span>
              <select className="input" value={role} onChange={(e) => setRole(e.target.value as "member" | "admin")}>
                <option value="member">Member: listens</option>
                <option value="admin">Admin: also runs Hive Admin</option>
              </select>
            </label>
            <label className="field">
              <span>Works for</span>
              <select className="input" value={days} onChange={(e) => setDays(Number(e.target.value))}>
                {[1, 3, 7, 14, 30].map((d) => (
                  <option key={d} value={d}>
                    {d === 1 ? "1 day" : `${d} days`}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {create.error && <p className="note note--error">{create.error.message}</p>}
          <div className="actions">
            <button className="button button--primary" type="submit" disabled={create.isPending}>
              <UserPlus size={16} aria-hidden /> {create.isPending ? "Creating…" : "Create invite"}
            </button>
          </div>
        </form>
      )}

      <section className="panel" aria-labelledby="open-h">
        <h2 id="open-h" className="panel__title">
          Open invites
        </h2>
        {list.error && <QueryError error={list.error} retry={() => list.refetch()} busy={list.isFetching} />}
        {list.data && list.data.length === 0 && <p className="note">None. Used and expired invites drop off.</p>}
        {list.data && list.data.length > 0 && (
          <ul className="rows">
            {list.data.map((inv) => (
              <InviteRow key={inv.id} invite={inv} />
            ))}
          </ul>
        )}
      </section>
    </section>
  );
}
