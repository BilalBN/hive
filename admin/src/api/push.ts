import { api, ApiError, type Problem } from "./client";
import type { components } from "./schema";

// ---------------------------------------------------------------- M6: notifications

export type AdminPush = components["schemas"]["AdminPush"];
export type AdminPushUpdate = components["schemas"]["AdminPushUpdate"];

function take<T>(r: { data?: T; error?: unknown; response: Response }): T {
  if (r.data === undefined) throw new ApiError(r.response.status, (r.error ?? undefined) as Problem | undefined);
  return r.data;
}

export const pushQuery = {
  queryKey: ["admin-push"],
  queryFn: async () => take(await api.GET("/api/v1/admin/push")),
};
export const savePush = async (body: AdminPushUpdate) => take(await api.PUT("/api/v1/admin/push", { body }));
export const testPush = async () => take(await api.POST("/api/v1/admin/push/test"));
