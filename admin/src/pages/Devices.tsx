import { useQuery } from "@tanstack/react-query";

import { fetchDevices } from "../api/people";
import { QueryError } from "../components/QueryError";
import { DeviceRow } from "./People";

export const devicesQuery = {
  queryKey: ["devices"],
  queryFn: fetchDevices,
} as const;

/** Every phone and computer across the family. */
export function DevicesPage() {
  const { data, error, refetch, isFetching } = useQuery(devicesQuery);
  const active = data?.filter((d) => d.status === "active") ?? [];
  const signedOut = data?.filter((d) => d.status !== "active") ?? [];
  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Devices</h1>
        <p className="page__summary">
          Every phone and computer across the family. Signing one out stops it within 15 minutes and deletes its
          downloads next time it connects.
        </p>
      </header>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {data && (
        <>
          <section className="panel" aria-labelledby="active-h">
            <h2 id="active-h" className="panel__title">
              Signed in
            </h2>
            {active.length ? (
              <ul className="rows">
                {active.map((d) => (
                  <DeviceRow key={d.id} device={d} showPerson />
                ))}
              </ul>
            ) : (
              <p className="note">No devices yet.</p>
            )}
          </section>
          {signedOut.length > 0 && (
            <section className="panel" aria-labelledby="out-h">
              <h2 id="out-h" className="panel__title">
                Signed out
              </h2>
              <ul className="rows">
                {signedOut.map((d) => (
                  <DeviceRow key={d.id} device={d} showPerson />
                ))}
              </ul>
            </section>
          )}
        </>
      )}
    </section>
  );
}
