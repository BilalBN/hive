import createClient from "openapi-fetch";

import type { components, paths } from "./schema";

/**
 * Typed client for the Hive API, generated from api/openapi.yaml. Same origin as
 * the panel. `fetch` is looked up on every call so tests can replace it.
 */
export const api = createClient<paths>({
  baseUrl: globalThis.location?.origin ?? "",
  fetch: (request) => globalThis.fetch(request),
});

export type Health = components["schemas"]["Health"];
export type Problem = components["schemas"]["Problem"];
export type LibraryStatus = components["schemas"]["LibraryStatus"];
export type ImportItem = components["schemas"]["ImportItem"];
export type AlbumSummary = components["schemas"]["AlbumSummary"];

/** A failed call, with the server's own words when it sent a Problem body. */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly problem?: Problem,
  ) {
    super(problem?.detail ?? problem?.title ?? `Server answered ${status}`);
  }

  /** M1: Hive Admin only works on the home computer itself (sign-in arrives in M2). */
  get needsHomeComputer(): boolean {
    return this.status === 401;
  }
}

function fail(response: Response, error: unknown): never {
  throw new ApiError(response.status, (error ?? undefined) as Problem | undefined);
}

export async function fetchHealth(): Promise<Health> {
  const { data, response } = await api.GET("/api/v1/health");
  if (!data) {
    throw new Error(`Server answered ${response.status}`);
  }
  return data;
}

export async function fetchLibrary(): Promise<LibraryStatus> {
  const { data, error, response } = await api.GET("/api/v1/admin/library/imports");
  if (!data) fail(response, error);
  return data;
}

export async function startScan(): Promise<LibraryStatus> {
  const { data, error, response } = await api.POST("/api/v1/admin/library/scan");
  if (!data) fail(response, error);
  return data;
}

/** Take a file off Needs attention or Duplicate copies (it comes back if the file changes). */
export async function ignoreImport(importId: string): Promise<LibraryStatus> {
  const { data, error, response } = await api.POST("/api/v1/admin/library/imports/{importId}/ignore", {
    params: { path: { importId } },
  });
  if (!data) fail(response, error);
  return data;
}

/** Delete one exact copy from disk; the server compares both files again first. */
export async function deleteCopy(importId: string): Promise<LibraryStatus> {
  const { data, error, response } = await api.POST("/api/v1/admin/library/imports/{importId}/delete-copy", {
    params: { path: { importId } },
  });
  if (!data) fail(response, error);
  return data;
}

export async function deleteAllCopies(): Promise<LibraryStatus> {
  const { data, error, response } = await api.POST("/api/v1/admin/library/imports/delete-copies");
  if (!data) fail(response, error);
  return data;
}

export async function fetchDevelopmentKey(): Promise<string> {
  const { data, error, response } = await api.GET("/api/v1/admin/development-key");
  if (!data) fail(response, error);
  return data.key;
}

/** Cover art from the server, at one of its sizes. */
export function artworkUrl(artworkId: string, size: 96 | 192 | 300 | 600 = 96): string {
  return `/api/v1/media/artwork/${encodeURIComponent(artworkId)}?size=${size}`;
}

// ---------------------------------------------------------------- M1.5: lookup and album editor

export type LookupStatus = components["schemas"]["LookupStatus"];
export type LookupState = components["schemas"]["LookupState"];
export type AdminAlbum = components["schemas"]["AdminAlbum"];
export type AdminAlbumPage = components["schemas"]["AdminAlbumPage"];
export type AlbumEdit = components["schemas"]["AlbumEdit"];
export type FoundAlbum = components["schemas"]["FoundAlbum"];
export type Credit = components["schemas"]["Credit"];
export type AlbumFilter = "all" | "review" | "noArt" | "noLanguage" | "notFound";

export async function fetchLookup(): Promise<LookupStatus> {
  const { data, error, response } = await api.GET("/api/v1/admin/library/lookup");
  if (!data) fail(response, error);
  return data;
}

export async function updateLookup(body: { enabled?: boolean; acoustidKey?: string }): Promise<LookupStatus> {
  const { data, error, response } = await api.PATCH("/api/v1/admin/library/lookup", { body });
  if (!data) fail(response, error);
  return data;
}

export async function retryLookup(body: { albumIds?: string[]; all?: boolean }): Promise<LookupStatus> {
  const { data, error, response } = await api.POST("/api/v1/admin/library/lookup/retry", { body });
  if (!data) fail(response, error);
  return data;
}

export type AcoustidTest = components["schemas"]["AcoustidTest"];

export async function testAcoustid(): Promise<AcoustidTest> {
  const { data, error, response } = await api.POST("/api/v1/admin/library/lookup/test-acoustid");
  if (!data) fail(response, error);
  return data;
}

export async function fetchAdminAlbums(filter: AlbumFilter, q: string, offset = 0): Promise<AdminAlbumPage> {
  const { data, error, response } = await api.GET("/api/v1/admin/library/albums", {
    params: { query: { filter, offset, limit: 100, ...(q.trim() ? { q: q.trim() } : {}) } },
  });
  if (!data) fail(response, error);
  return data;
}

export async function fetchAdminAlbum(albumId: string): Promise<AdminAlbum> {
  const { data, error, response } = await api.GET("/api/v1/admin/library/albums/{albumId}", {
    params: { path: { albumId } },
  });
  if (!data) fail(response, error);
  return data;
}

export async function updateAlbum(albumId: string, body: AlbumEdit): Promise<AdminAlbum> {
  const { data, error, response } = await api.PATCH("/api/v1/admin/library/albums/{albumId}", {
    params: { path: { albumId } },
    // openapi-typescript reads the null-only `artwork` field as `undefined`.
    body: body as Omit<AlbumEdit, "artwork">,
  });
  if (!data) fail(response, error);
  return data;
}

export async function decideMatch(albumId: string, accept: boolean): Promise<AdminAlbum> {
  const { data, error, response } = await api.POST("/api/v1/admin/library/albums/{albumId}/match", {
    params: { path: { albumId } },
    body: { accept },
  });
  if (!data) fail(response, error);
  return data;
}

/** Replace an album's cover with an image file (JPEG, PNG or WebP). */
export async function setAlbumArtwork(albumId: string, file: Blob): Promise<AdminAlbum> {
  const response = await globalThis.fetch(
    `${globalThis.location?.origin ?? ""}/api/v1/admin/library/albums/${encodeURIComponent(albumId)}/artwork`,
    { method: "PUT", body: file, headers: { "Content-Type": file.type || "image/jpeg" } },
  );
  const body = await response.json().catch(() => undefined);
  if (!response.ok) throw new ApiError(response.status, body as Problem | undefined);
  return body as AdminAlbum;
}

// ---------------------------------------------------------------- lyrics

export type AdminLyrics = components["schemas"]["AdminLyrics"];
export type LyricsFound = components["schemas"]["LyricsFound"];

export async function fetchLyrics(trackId: string): Promise<AdminLyrics> {
  const { data, error, response } = await api.GET("/api/v1/admin/library/tracks/{trackId}/lyrics", {
    params: { path: { trackId } },
  });
  if (!data) fail(response, error);
  return data;
}

/** Plain lines or timed LRC; empty removes the lyrics set here. */
export async function saveLyrics(trackId: string, text: string): Promise<AdminLyrics> {
  const { data, error, response } = await api.PUT("/api/v1/admin/library/tracks/{trackId}/lyrics", {
    params: { path: { trackId } },
    body: { text },
  });
  if (!data) fail(response, error);
  return data;
}

/** Ask LRCLIB; nothing is saved. */
export async function findLyrics(trackId: string): Promise<LyricsFound> {
  const { data, error, response } = await api.POST("/api/v1/admin/library/tracks/{trackId}/lyrics/find", {
    params: { path: { trackId } },
  });
  if (!data) fail(response, error);
  return data;
}
