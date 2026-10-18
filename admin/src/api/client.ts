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

export async function fetchHealth(): Promise<Health> {
  const { data, response } = await api.GET("/api/v1/health");
  if (!data) {
    throw new Error(`Server answered ${response.status}`);
  }
  return data;
}
