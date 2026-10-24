import { api, ApiError, type Problem } from "./client";
import type { components } from "./schema";

// ---------------------------------------------------------------- M3: Listen, song requests and recognition

type S = components["schemas"];
export type SongRequest = S["SongRequest"];
export type SongRequestStatus = SongRequest["status"];
export type RecognitionStatus = S["RecognitionStatus"];

function take<T>(r: { data?: T; error?: unknown; response: Response }): T {
  if (r.data === undefined) throw new ApiError(r.response.status, (r.error ?? undefined) as Problem | undefined);
  return r.data;
}

export const fetchSongRequests = async () => take(await api.GET("/api/v1/admin/song-requests")).items;

export const decideSongRequest = async (songRequestId: string, status: SongRequestStatus) =>
  take(
    await api.PATCH("/api/v1/admin/song-requests/{songRequestId}", {
      params: { path: { songRequestId } },
      body: { status },
    }),
  );

export const fetchRecognition = async () => take(await api.GET("/api/v1/admin/recognition"));
export const rebuildRecognition = async () => take(await api.POST("/api/v1/admin/recognition/rebuild"));

// ---------------------------------------------------------------- M5: Shazam

export type ShazamSettings = S["ShazamSettings"];
export type ShazamSettingsUpdate = S["ShazamSettingsUpdate"];
export const shazamQuery = {
  queryKey: ["shazam"],
  queryFn: async () => take(await api.GET("/api/v1/admin/recognition/shazam")),
};
export const saveShazam = async (body: ShazamSettingsUpdate) =>
  take(await api.PUT("/api/v1/admin/recognition/shazam", { body }));
