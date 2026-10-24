import { api, ApiError, type Problem } from "./client";
import type { components } from "./schema";

// ---------------------------------------------------------------- M6: music videos

export type AdminVideos = components["schemas"]["AdminVideos"];

function take<T>(r: { data?: T; error?: unknown; response: Response }): T {
  if (r.data === undefined) throw new ApiError(r.response.status, (r.error ?? undefined) as Problem | undefined);
  return r.data;
}

export const videosQuery = {
  queryKey: ["admin-videos"],
  queryFn: async () => take(await api.GET("/api/v1/admin/library/videos")),
};
