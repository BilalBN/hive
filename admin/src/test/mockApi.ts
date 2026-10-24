import { vi } from "vitest";

import type { AdminAlbum, Health, LibraryStatus, LookupStatus } from "../api/client";
import type { AdminOverview, AdminRequests, AdminSession } from "../api/people";

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
    {
      id: "7",
      path: "Incoming/broken.mp3",
      status: "failed",
      problem: "The file is damaged or not audio",
      updatedAt: "2026-10-18T06:00:00Z",
    },
  ],
  recentlyAdded: [
    {
      id: "a1",
      title: "Premam",
      artistName: "Rajesh Murugesan",
      year: 2015,
      trackCount: 12,
      tier: "lossless",
      addedAt: "2026-10-18T06:00:00Z",
    },
  ],
};

export const lookup: LookupStatus = {
  enabled: true,
  acoustidKey: false,
  fingerprinting: false,
  working: false,
  waiting: 0,
  found: 80,
  notFound: 6,
  review: 2,
  failed: 0,
  edited: 1,
  sends:
    "Album and artist names, song titles and lengths go to MusicBrainz, Cover Art Archive and Wikidata. Never the music itself, and nothing about who listens.",
};

export const kumbalangi: AdminAlbum = {
  album: {
    id: "kn",
    title: "Kumbalangi Nights",
    artistName: "Sushin Shyam",
    trackCount: 2,
    tier: "lossless",
    addedAt: "2026-10-18T06:00:00Z",
    durationMs: 420000,
    language: "ml",
    tracks: [
      {
        id: "t1",
        title: "ചെരാതുകൾ",
        artistName: "Sithara Krishnakumar",
        albumId: "kn",
        albumTitle: "Kumbalangi Nights",
        trackNumber: 1,
        durationMs: 210000,
        format: {
          codec: "flac",
          lossless: true,
          sampleRate: 44100,
          channels: 2,
          bitDepth: 16,
          tier: "lossless",
          label: "Lossless 16/44.1",
        },
        liked: false,
        composer: "Sushin Shyam",
        lyricist: "Anwar Ali",
      },
    ],
  },
  lookup: "review",
  lookupNote: "Found something that might be it: check it in Hive Admin.",
  edited: [],
  sources: { language: "script" },
  folder: "Malayalam/Kumbalangi Nights",
  found: {
    title: "Kumbalangi Nights (Original Motion Picture Soundtrack)",
    artistName: "Sushin Shyam",
    year: 2019,
    language: "ml",
    kind: "soundtrack",
    film: { title: "Kumbalangi Nights", year: 2019, wikidataId: "Q100" },
    credits: [{ role: "actor", name: "Fahadh Faasil" }],
    trackCount: 7,
    score: 0.62,
    source: "MusicBrainz · Wikidata",
    link: "https://musicbrainz.org/release/rel-kn",
  },
};

type Route = { status?: number; body: unknown };

/** Replace fetch with canned answers by path; anything else is a network failure. */
/** On the home computer, before the first admin is set up (the M1 state). */
export const homeSession: AdminSession = {
  signedIn: true,
  onHomeComputer: true,
  needsSetup: true,
  emailReady: false,
};

export const overview: AdminOverview = {
  homeName: "Arun's home",
  pendingRequests: 1,
  people: 3,
  devices: 5,
  tracks: 1240,
  albums: 96,
  sizeBytes: 38 * 1024 ** 3,
  losslessPercent: 72,
  emailReady: false,
  developmentKeyActive: true,
  alerts: [
    {
      level: "warning",
      text: "Email isn't set up, so sign-in codes show on Requests for you to pass on. Settings → Email.",
    },
  ],
  recent: [
    {
      id: "1",
      at: "2026-10-18T06:00:00Z",
      actor: "Arun",
      action: "invite.create",
      text: "Arun created an invite for amma@example.com (member).",
    },
  ],
};

export const requests: AdminRequests = {
  items: [
    {
      id: "r1",
      email: "basith@example.com",
      deviceName: "Basith's Pixel",
      platform: "android",
      status: "pending",
      invited: false,
      existingPerson: false,
      createdAt: "2026-10-18T06:00:00Z",
    },
  ],
  codes: [
    {
      email: "basith@example.com",
      code: "482913",
      purpose: "join",
      expiresAt: "2099-01-01T00:00:00Z",
    },
  ],
};

export function mockApi(routes: Record<string, Route | ((req: Request) => Route)> = {}) {
  const all: Record<string, Route | ((req: Request) => Route)> = {
    "GET /api/v1/health": { body: health },
    "GET /api/v1/admin/library/imports": { body: library },
    "GET /api/v1/admin/development-key": {
      body: { key: "hive-dev-7k2q-9mxp-4c8a-tr3z" },
    },
    "GET /api/v1/admin/library/lookup": { body: lookup },
    "GET /api/v1/admin/session": { body: homeSession },
    "GET /api/v1/admin/overview": { body: overview },
    "GET /api/v1/admin/library/tidy": { body: { items: [] } },
    "GET /api/v1/admin/song-requests": { body: { items: [] } },
    "GET /api/v1/admin/recognition/shazam": { body: { enabled: false, keySet: false, androidReady: false } },
    "GET /api/v1/admin/library/same-songs": { body: { items: [] } },
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
    return new Response(JSON.stringify(r.body), {
      status,
      headers: { "Content-Type": type },
    });
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}
