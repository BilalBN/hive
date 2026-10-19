import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useState } from "react";

import { fetchAudit } from "../api/people";
import { QueryError } from "../components/QueryError";
import { ActivityRows } from "./Overview";

const PAGE = 50;

/** Every admin action, sign-in and device change, newest first. */
export function ActivityPage() {
  const [offset, setOffset] = useState(0);
  const { data, error, refetch, isFetching } = useQuery({
    queryKey: ["audit", offset],
    queryFn: () => fetchAudit(offset, PAGE),
    placeholderData: keepPreviousData,
  });
  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">Activity</h1>
        <p className="page__summary">Every admin action, sign-in and device change, for the record.</p>
      </header>
      {error && <QueryError error={error} retry={() => refetch()} busy={isFetching} />}
      {data && (
        <section className="panel">
          <ActivityRows items={data.items} />
          {data.total > PAGE && (
            <div className="pager">
              <button
                className="button button--secondary"
                type="button"
                disabled={offset === 0}
                onClick={() => setOffset(Math.max(0, offset - PAGE))}
              >
                Newer
              </button>
              <span className="note">
                {offset + 1}–{Math.min(offset + PAGE, data.total)} of {data.total}
              </span>
              <button
                className="button button--secondary"
                type="button"
                disabled={offset + PAGE >= data.total}
                onClick={() => setOffset(offset + PAGE)}
              >
                Older
              </button>
            </div>
          )}
        </section>
      )}
    </section>
  );
}
