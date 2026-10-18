import { vi } from "vitest";

import type { Health, LibraryStatus } from "../api/client";

export const health: Health = {
  status: "ok",
  homeName: "Arun's home",
  serverVersion: "0.1.0",
  apiVersion: "0.2.0",
  minAppVersion: "0.1.0",
  serverTime: "2026-10-18T06:00:00Z",
};

export const library: LibraryStatus = {
  tracks: 1240,
  albums: 96,
  artists: 41,
  sizeBytes: 38 * 1024 ** 3,
  hoursOfMusic: 83.5,
  scanning: false,
  queued: 0,
  folders: [{ path: "/Users/arun/Music/Hive", exists: true, trackCount: 1240 }],
  uploadFolder: "/Users/arun/Music/Hive/Uploads",
  ffmpeg: true,
  queue: [],
  needsAttention: [
    { id: "7", path: "Incoming/broken.mp3", status: "failed", problem: "The file is damaged or not audio", updatedAt: "2026-10-18T06:00:00Z" },
  ],
  recentlyAdded: [
    { id: "a1", title: "Premam", artistName: "Rajesh Murugesan", year: 2015, trackCount: 12, tier: "lossless", addedAt: "2026-10-18T06:00:00Z" },
  ],
};

type Route = { status?: number; body: unknown };

/** Replace fetch with canned answers by path; anything else is a network failure. */
export function mockApi(routes: Record<string, Route | ((req: Request) => Route)> = {}) {
  const all: Record<string, Route | ((req: Request) => Route)> = {
    "GET /api/v1/health": { body: health },
    "GET /api/v1/admin/library/imports": { body: library },
    "GET /api/v1/admin/development-key": { body: { key: "hive-dev-7k2q-9mxp-4c8a-tr3z" } },
    ...routes,
  };
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = input instanceof Request ? input : new Request(String(input), init);
    const url = new URL(req.url);
    const route = all[`${req.method} ${url.pathname}`];
    if (!route) throw new TypeError("Failed to fetch");
    const r = typeof route === "function" ? route(req) : route;
    const status = r.status ?? 200;
    const type = status >= 400 ? "application/problem+json" : "application/json";
    return new Response(JSON.stringify(r.body), { status, headers: { "Content-Type": type } });
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}
