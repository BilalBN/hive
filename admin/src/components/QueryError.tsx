import { useQueryClient } from "@tanstack/react-query";
import { CircleAlert, RefreshCw } from "lucide-react";
import { useEffect } from "react";

import { ApiError } from "../api/client";

/** One banner for any failed load, in plain words, with a retry. */
export function QueryError({ error, retry, busy }: { error: unknown; retry: () => void; busy?: boolean }) {
  const client = useQueryClient();
  const signedOut = error instanceof ApiError && error.needsSignIn;
  // The session ended (or was never there): ask again, which shows sign-in.
  useEffect(() => {
    if (signedOut) client.invalidateQueries({ queryKey: ["admin-session"] });
  }, [signedOut, client]);
  const message = signedOut
    ? "Your session ended. Sign in again to carry on."
    : error instanceof ApiError
      ? error.message
      : "The admin panel can't reach the Hive server. Check that it is running on the home PC.";
  return (
    <div className="banner banner--danger" role="alert">
      <CircleAlert size={18} aria-hidden />
      <span>{message}</span>
      {!signedOut && (
        <button className="button button--secondary" type="button" onClick={retry} disabled={busy}>
          <RefreshCw size={16} aria-hidden /> Try again
        </button>
      )}
    </div>
  );
}
