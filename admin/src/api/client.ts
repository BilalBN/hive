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

export async function fetchDevelopmentKey(): Promise<string> {
  const { data, error, response } = await api.GET("/api/v1/admin/development-key");
  if (!data) fail(response, error);
  return data.key;
}

/** Cover art from the server, at one of its sizes. */
export function artworkUrl(artworkId: string, size: 96 | 192 | 300 | 600 = 96): string {
  return `/api/v1/media/artwork/${encodeURIComponent(artworkId)}?size=${size}`;
}
