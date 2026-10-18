import { useQuery } from "@tanstack/react-query";

import { fetchHealth } from "../api/client";

export const healthQuery = {
  queryKey: ["health"],
  queryFn: fetchHealth,
  refetchInterval: 15_000,
} as const;

/** The small card at the foot of the navigation: is home online, and which version. */
export function ServerStatus() {
  const { data, isError, isPending } = useQuery(healthQuery);
  const state = isPending ? "checking" : isError ? "offline" : "online";
  const text = { checking: "Checking…", offline: "Can't reach the server", online: `${data?.homeName ?? "Home"} online` }[state];

  return (
    <div className="server-status" role="status" aria-live="polite">
      <div className="server-status__line">
        <span className={`dot dot--${state}`} aria-hidden />
        <span className="server-status__name">{text}</span>
      </div>
      {data && <div className="server-status__meta mono">v{data.serverVersion}</div>}
    </div>
  );
}
