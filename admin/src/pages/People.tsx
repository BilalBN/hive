import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate, useSearch } from "@tanstack/react-router";
import { ChevronLeft, MonitorSmartphone, ShieldCheck, UserRound } from "lucide-react";
import { useState } from "react";

import {
  type AdminDevice,
  type AdminPerson,
  ago,
  fetchPeople,
  fetchPerson,
  type PersonEdit,
  PLATFORM,
  revokeDevice,
  updatePerson,
} from "../api/people";
import { QueryError } from "../components/QueryError";
import { ActivityRows } from "./Overview";

const INVITE_PATH: string = "/invite";

export const peopleQuery = {
  queryKey: ["people"],
  queryFn: fetchPeople,
} as const;
const personQuery = (id: string) => ({ queryKey: ["person", id], queryFn: () => fetchPerson(id) }) as const;

function StatusTag({ person }: { person: AdminPerson }) {
  if (person.status === "suspended") return <span className="tag tag--warning">Suspended</span>;
  if (person.role === "admin")
    return (
      <span className="tag">
        <ShieldCheck size={12} aria-hidden /> Admin
      </span>
    );
  return null;
}

/** One device, with a way to sign it out. */
export function DeviceRow({ device, showPerson = false }: { device: AdminDevice; showPerson?: boolean }) {
  const client = useQueryClient();
  const revoke = useMutation({
    mutationFn: () => revokeDevice(device.id),
    onSuccess: () => {
      client.invalidateQueries({ queryKey: ["devices"] });
      client.invalidateQueries({ queryKey: ["person", device.personId] });
      client.invalidateQueries({ queryKey: peopleQuery.queryKey });
    },
  });
  const active = device.status === "active";
  return (
    <li className="row">
      <span className="row__icon" aria-hidden>
        <MonitorSmartphone size={16} />
      </span>
      <div className="row__text">
        <p className="row__title">
          {device.name}
          {showPerson && <span className="row__aside"> · {device.personName}</span>}
        </p>
        <p className="row__meta">
          {PLATFORM[device.platform]}
          {device.appVersion ? ` · Hive ${device.appVersion}` : ""} ·{" "}
          {active ? (device.lastSeenAt ? `seen ${ago(device.lastSeenAt)}` : "not used yet") : "signed out"}
        </p>
        {revoke.error && <p className="note note--error">{revoke.error.message}</p>}
      </div>
      {active && (
        <button
          className="button button--secondary"
          type="button"
          disabled={revoke.isPending}
          onClick={() => {
            if (
              globalThis.confirm?.(`Sign out ${device.name}? Its downloads are deleted next time it connects.`) ??
              true
            )
              revoke.mutate();
          }}
        >
          Sign out
        </button>
      )}
    </li>
  );
}

function Person({ id }: { id: string }) {
  const client = useQueryClient();
  const navigate = useNavigate();
  const { data, error, refetch, isFetching } = useQuery(personQuery(id));
  const [limit, setLimit] = useState<string>("");
  const edit = useMutation({
    mutationFn: (body: PersonEdit) => updatePerson(id, body),
    onSuccess: (d) => {
      client.setQueryData(personQuery(id).queryKey, d);
      client.invalidateQueries({ queryKey: peopleQuery.queryKey });
      client.invalidateQueries({ queryKey: ["devices"] });
      setLimit("");
    },
  });

  return (
    <section className="page">
      <button className="back" type="button" onClick={() => navigate({ to: "/people", search: {} })}>
        <ChevronLeft size={16} aria-hidden /> People
      </button>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {data && (
        <>
          <header className="page__header">
            <h1 className="page__title">{data.person.name}</h1>
            <p className="page__summary">
              {data.person.email} · {data.person.role === "admin" ? "Admin" : "Member"} · joined{" "}
              {ago(data.person.createdAt)}
              {data.person.status === "suspended" ? " · suspended" : ""}
            </p>
          </header>
          {edit.error && <p className="note note--error">{edit.error.message}</p>}

          <section className="panel" aria-labelledby="devices-h">
            <h2 id="devices-h" className="panel__title">
              Devices ({data.person.devicesUsed} of {data.person.deviceLimit})
            </h2>
            <p className="note">
              {data.swapsUsed} of {data.swapsPerMonth} device swaps used in the last 30 days.
            </p>
            {data.devices.length ? (
              <ul className="rows">
                {data.devices.map((d) => (
                  <DeviceRow key={d.id} device={d} />
                ))}
              </ul>
            ) : (
              <p className="note">No devices yet.</p>
            )}
          </section>

          <section className="panel" aria-labelledby="manage-h">
            <h2 id="manage-h" className="panel__title">
              Manage
            </h2>
            <div className="manage">
              <div className="manage__row">
                <div>
                  <p className="manage__title">{data.person.status === "suspended" ? "Reinstate" : "Suspend"}</p>
                  <p className="note">
                    {data.person.status === "suspended"
                      ? "Let them back in. Their devices work again."
                      : "Stops music on every device of theirs within 15 minutes. Nothing is deleted."}
                  </p>
                </div>
                <button
                  className="button button--secondary"
                  type="button"
                  disabled={edit.isPending}
                  onClick={() =>
                    edit.mutate({
                      status: data.person.status === "suspended" ? "active" : "suspended",
                    })
                  }
                >
                  {data.person.status === "suspended" ? "Reinstate" : "Suspend"}
                </button>
              </div>
              <div className="manage__row">
                <div>
                  <p className="manage__title">Role</p>
                  <p className="note">
                    {data.person.role === "admin" ? "Can use Hive Admin." : "Listens; can't open Hive Admin."}
                  </p>
                </div>
                <button
                  className="button button--secondary"
                  type="button"
                  disabled={edit.isPending}
                  onClick={() =>
                    edit.mutate({
                      role: data.person.role === "admin" ? "member" : "admin",
                    })
                  }
                >
                  {data.person.role === "admin" ? "Make member" : "Make admin"}
                </button>
              </div>
              <div className="manage__row">
                <div>
                  <p className="manage__title">Device limit</p>
                  <p className="note">
                    {data.person.deviceLimitOverride
                      ? `${data.person.deviceLimit} for ${data.person.name} (set here).`
                      : `${data.person.deviceLimit}, the home's usual limit.`}
                  </p>
                </div>
                <div className="inline-form">
                  <input
                    className="input input--small"
                    type="number"
                    min={1}
                    max={20}
                    aria-label="New device limit"
                    placeholder={String(data.person.deviceLimit)}
                    value={limit}
                    onChange={(e) => setLimit(e.target.value)}
                  />
                  <button
                    className="button button--secondary"
                    type="button"
                    disabled={!limit || edit.isPending}
                    onClick={() => edit.mutate({ deviceLimit: Number(limit) })}
                  >
                    Set
                  </button>
                  {data.person.deviceLimitOverride && (
                    <button
                      className="link-button"
                      type="button"
                      disabled={edit.isPending}
                      onClick={() => edit.mutate({ deviceLimit: null })}
                    >
                      Use the usual limit
                    </button>
                  )}
                </div>
              </div>
              <div className="manage__row">
                <div>
                  <p className="manage__title">Simple mode</p>
                  <p className="note">Bigger buttons and fewer choices in the app.</p>
                </div>
                <label className="switch">
                  <input
                    type="checkbox"
                    checked={data.person.simpleMode}
                    disabled={edit.isPending}
                    onChange={(e) => edit.mutate({ simpleMode: e.target.checked })}
                  />
                  <span>{data.person.simpleMode ? "On" : "Off"}</span>
                </label>
              </div>
              <div className="manage__row">
                <div>
                  <p className="manage__title">Sign out everywhere</p>
                  <p className="note">For a lost phone. They join again with their email on each device.</p>
                </div>
                <button
                  className="button button--secondary"
                  type="button"
                  disabled={edit.isPending || data.person.devicesUsed === 0}
                  onClick={() => {
                    if (globalThis.confirm?.(`Sign ${data.person.name} out of every device?`) ?? true)
                      edit.mutate({ resetDevices: true });
                  }}
                >
                  Sign out everywhere
                </button>
              </div>
            </div>
          </section>

          <section className="panel" aria-labelledby="activity-h">
            <h2 id="activity-h" className="panel__title">
              Activity
            </h2>
            <ActivityRows items={data.activity} />
          </section>
        </>
      )}
    </section>
  );
}

/** Everyone with access, their devices used and status. */
export function PeoplePage() {
  const search = useSearch({ strict: false }) as { person?: string };
  const { data, error, refetch, isFetching } = useQuery(peopleQuery);
  if (search.person) return <Person id={search.person} />;
  return (
    <section className="page">
      <header className="page__header page__header--actions">
        <div>
          <h1 className="page__title">People</h1>
          <p className="page__summary">Everyone with access, their devices and status.</p>
        </div>
        <Link to={INVITE_PATH} className="button button--primary">
          Invite someone
        </Link>
      </header>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {data && data.length === 0 && <p className="note">Nobody yet. Invite the family from Invite.</p>}
      {data && data.length > 0 && (
        <section className="panel">
          <ul className="rows">
            {data.map((p) => (
              <li key={p.id}>
                <Link to="/people" search={{ person: p.id }} className="row row--link">
                  <span className="row__icon" aria-hidden>
                    <UserRound size={16} />
                  </span>
                  <div className="row__text">
                    <p className="row__title">
                      {p.name} <StatusTag person={p} />
                    </p>
                    <p className="row__meta">
                      {p.email} · {p.devicesUsed} of {p.deviceLimit} devices
                      {p.lastActiveAt ? ` · active ${ago(p.lastActiveAt)}` : ""}
                    </p>
                  </div>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      )}
    </section>
  );
}
