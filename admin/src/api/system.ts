import { api, ApiError, type Problem } from "./client";
import type { components, operations } from "./schema";

// ---------------------------------------------------------------- M4: system health and logs

type S = components["schemas"];
export type SystemHealth = S["SystemHealth"];
export type LogLine = S["LogLine"];
export type LogQuery = NonNullable<operations["adminGetLogs"]["parameters"]["query"]>;

function take<T>(r: { data?: T; error?: unknown; response: Response }): T {
  if (r.data === undefined) throw new ApiError(r.response.status, (r.error ?? undefined) as Problem | undefined);
  return r.data;
}

export const fetchSystem = async () => take(await api.GET("/api/v1/admin/system"));
export const fetchLogs = async (query: LogQuery) => take(await api.GET("/api/v1/admin/logs", { params: { query } }));
export const LOG_FILE = "/api/v1/admin/logs/file";
