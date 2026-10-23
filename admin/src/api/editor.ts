import { api, ApiError, type Problem } from "./client";
import type { components } from "./schema";

// ------------------------------------------- M4: song details and the same song twice

type S = components["schemas"];
export type TrackEdit = S["TrackEdit"];
export type SameSongCopy = S["SameSongCopy"];
export type SameSongGroup = S["SameSongGroup"];
export type SameSongs = S["SameSongs"];
export type SameSongResult = S["SameSongResult"];

function take<T>(r: { data?: T; error?: unknown; response: Response }): T {
  if (r.data === undefined) throw new ApiError(r.response.status, (r.error ?? undefined) as Problem | undefined);
  return r.data;
}

export const updateTrack = async (trackId: string, body: TrackEdit) =>
  take(await api.PATCH("/api/v1/admin/library/tracks/{trackId}", { params: { path: { trackId } }, body }));
export const sameSongsQuery = {
  queryKey: ["admin-same-songs"],
  queryFn: async () => take(await api.GET("/api/v1/admin/library/same-songs")),
};
export const keepCopy = async (keep: string, remove: string[]) =>
  take(await api.POST("/api/v1/admin/library/same-songs/resolve", { body: { keep, remove } }));
export const keepBoth = async (key: string) =>
  take(await api.POST("/api/v1/admin/library/same-songs/keep-both", { body: { key } }));
