import { CircleAlert, RefreshCw } from "lucide-react";

import { ApiError } from "../api/client";

/** One banner for any failed load, in plain words, with a retry. */
export function QueryError({ error, retry, busy }: { error: unknown; retry: () => void; busy?: boolean }) {
  const homeOnly = error instanceof ApiError && error.needsHomeComputer;
  const message = homeOnly
    ? "For now Hive Admin only opens on the home computer itself: use http://127.0.0.1:8443/admin/ there. Signing in from other devices arrives in M2."
    : error instanceof ApiError
      ? error.message
      : "The admin panel can't reach the Hive server. Check that it is running on the home PC.";
  return (
    <div className="banner banner--danger" role="alert">
      <CircleAlert size={18} aria-hidden />
      <span>{message}</span>
      {!homeOnly && (
        <button className="button button--secondary" type="button" onClick={retry} disabled={busy}>
          <RefreshCw size={16} aria-hidden /> Try again
        </button>
      )}
    </div>
  );
}
