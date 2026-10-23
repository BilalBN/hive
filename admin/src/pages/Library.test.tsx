import { fireEvent, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { library, lookup, mockApi } from "../test/mockApi";
import { renderAt } from "../test/render";

afterEach(() => vi.unstubAllGlobals());

describe("Library page", () => {
  it("shows what's in the library and what needs attention", async () => {
    mockApi();
    renderAt("/library");
    expect(await screen.findByText("1,240")).toBeInTheDocument();
    expect(screen.getByText("83.5 hours of music")).toBeInTheDocument();
    expect(screen.getByText("38.0 GB")).toBeInTheDocument();
    expect(screen.getByText("Incoming/broken.mp3")).toBeInTheDocument();
    expect(screen.getByText("The file is damaged or not audio")).toBeInTheDocument();
    expect(screen.getByText("Premam")).toBeInTheDocument();
    expect(screen.getByText("/Users/arun/Music/Hive/Uploads")).toBeInTheDocument();
    expect(screen.queryByText(/FFmpeg isn't installed/)).not.toBeInTheDocument();
  });

  it("warns when FFmpeg is missing", async () => {
    mockApi({
      "GET /api/v1/admin/library/imports": {
        body: { ...library, ffmpeg: false },
      },
    });
    renderAt("/library");
    expect(await screen.findByText(/FFmpeg isn't installed/)).toBeInTheDocument();
  });

  it("starts a scan and shows the queue", async () => {
    const scanning = {
      ...library,
      scanning: true,
      queued: 2,
      queue: [
        {
          id: "1",
          path: "Premam/01 Malare.flac",
          status: "working",
          updatedAt: "2026-10-18T06:00:00Z",
        },
        {
          id: "2",
          path: "Premam/02 Aluva Puzha.flac",
          status: "queued",
          updatedAt: "2026-10-18T06:00:00Z",
        },
      ],
    };
    const fetchMock = mockApi({
      "POST /api/v1/admin/library/scan": { body: scanning },
    });
    renderAt("/library");
    const btn = await screen.findByRole("button", { name: /Scan now/ });
    await screen.findByText("1,240");
    fireEvent.click(btn);
    expect(await screen.findByText("01 Malare.flac")).toBeInTheDocument();
    expect(screen.getByText("Reading")).toBeInTheDocument();
    expect(screen.getByText(/2 files to go/)).toBeInTheDocument();
    expect(fetchMock.mock.calls.some(([r]) => (r as Request).method === "POST")).toBe(true);
  });

  it("lists duplicate copies apart and deletes them", async () => {
    const copy = {
      id: "9",
      path: "Uploads/English/New/Perfect.mp3",
      status: "duplicate" as const,
      problem: "Same file as Uploads/English/Perfect.mp3, so it was skipped",
      updatedAt: "2026-10-18T06:00:00Z",
    };
    const withCopies = {
      ...library,
      duplicates: [copy, { ...copy, id: "10", path: "Uploads/English/New/Kiss me.mp3" }],
    };
    const cleaned = { ...library, duplicates: [] };
    const fetchMock = mockApi({
      "GET /api/v1/admin/library/imports": { body: withCopies },
      "POST /api/v1/admin/library/imports/delete-copies": { body: cleaned },
      "POST /api/v1/admin/library/imports/7/ignore": {
        body: { ...withCopies, needsAttention: [] },
      },
    });
    vi.stubGlobal("confirm", () => true);
    renderAt("/library");
    expect(await screen.findByText("Duplicate copies · 2")).toBeInTheDocument();
    expect(screen.getByText("Uploads/English/New/Perfect.mp3")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Ignore Incoming/broken.mp3" }));
    expect(await screen.findByText(/Nothing. Every file/)).toBeInTheDocument();
    expect(screen.getByText(/2 duplicate copies/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Delete all copies" }));
    await vi.waitFor(() => expect(screen.queryByText(/Duplicate copies/)).not.toBeInTheDocument());
    const posts = fetchMock.mock.calls.map(([r]) => r as Request).filter((r) => r.method === "POST");
    expect(posts.map((r) => new URL(r.url).pathname)).toEqual([
      "/api/v1/admin/library/imports/7/ignore",
      "/api/v1/admin/library/imports/delete-copies",
    ]);
  });

  it("tests the AcoustID key and says what's wrong", async () => {
    const ready = { ...lookup, acoustidKey: true, fingerprinting: true };
    mockApi({
      "GET /api/v1/admin/library/lookup": { body: ready },
      "POST /api/v1/admin/library/lookup/test-acoustid": {
        body: {
          ok: false,
          message: "AcoustID doesn't accept this key. Hive needs an application key, not the key for your own account",
          status: ready,
        },
      },
    });
    renderAt("/library");
    expect(await screen.findByText("Recognising songs with no useful tags by their sound: on")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Test it" }));
    expect(await screen.findByText(/doesn't accept this key/)).toBeInTheDocument();
  });

  it("asks to sign in again when the session has ended", async () => {
    let signedIn = true;
    mockApi({
      "GET /api/v1/admin/library/imports": {
        status: 401,
        body: { title: "Sign-in needed", status: 401 },
      },
      "GET /api/v1/admin/session": () => {
        const s = {
          signedIn,
          onHomeComputer: false,
          needsSetup: false,
          emailReady: true,
        };
        signedIn = false;
        return { body: s };
      },
    });
    renderAt("/library");
    expect(await screen.findByRole("heading", { name: "Sign in to Hive Admin" })).toBeInTheDocument();
  });

  it("offers tidy names for songs with download clutter, display only", async () => {
    let applied: string[] = [];
    mockApi({
      "GET /api/v1/admin/library/tidy": {
        body: {
          items: [
            {
              trackId: "t1",
              albumId: "a1",
              albumTitle: "Premam",
              before: "01 - Malare [Songs.pk]",
              after: "Malare",
              applied: false,
            },
            {
              trackId: "t2",
              albumId: "a1",
              albumTitle: "Premam",
              before: "Kalippu (www.site.com) 320kbps",
              after: "Kalippu",
              applied: false,
            },
          ],
        },
      },
      "POST /api/v1/admin/library/tidy": () => {
        applied = ["t1", "t2"];
        return {
          body: {
            items: [
              {
                trackId: "t1",
                albumId: "a1",
                albumTitle: "Premam",
                before: "01 - Malare [Songs.pk]",
                after: "Malare",
                applied: true,
              },
              {
                trackId: "t2",
                albumId: "a1",
                albumTitle: "Premam",
                before: "Kalippu (www.site.com) 320kbps",
                after: "Kalippu",
                applied: true,
              },
            ],
          },
        };
      },
    });
    renderAt("/library");
    expect(await screen.findByText(/2 songs have clutter/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Review" }));
    expect(screen.getByText("01 - Malare [Songs.pk]")).toBeInTheDocument();
    fireEvent.click(screen.getByLabelText("Select all (2)"));
    fireEvent.click(screen.getByRole("button", { name: "Tidy 2 songs" }));
    expect(await screen.findByText(/2 tidied so far/)).toBeInTheDocument();
    expect(applied).toEqual(["t1", "t2"]);
  });

  it("keeps the better copy of the same song", async () => {
    let sent: unknown;
    const copy = {
      title: "Dreams",
      artistName: "Fleetwood Mac",
      durationMs: 257000,
      likes: 0,
      plays: 0,
      inPlaylists: 0,
    };
    const group = {
      key: "a+b",
      copies: [
        {
          ...copy,
          trackId: "a",
          albumId: "r",
          albumTitle: "Rumours",
          format: "FLAC 24-bit 96 kHz",
          lossless: true,
          sizeBytes: 98e6,
          file: "Fleetwood Mac/Rumours/02 Dreams.flac",
          best: true,
        },
        {
          ...copy,
          trackId: "b",
          albumId: "c",
          albumTitle: "Best of 77",
          format: "MP3 192 kbps",
          lossless: false,
          sizeBytes: 6e6,
          file: "Compilations/05 Dreams.mp3",
          likes: 2,
          inPlaylists: 1,
          best: false,
        },
      ],
    };
    let groups = [group];
    mockApi({
      "GET /api/v1/admin/library/same-songs": () => ({ body: { items: groups } }),
      "POST /api/v1/admin/library/same-songs/resolve": (req) => {
        void req
          .clone()
          .json()
          .then((b) => (sent = b));
        groups = [];
        return { body: { moved: { likes: 2, plays: 0, playlistEntries: 1 }, deleted: 1 } };
      },
    });
    vi.stubGlobal("confirm", () => true);
    renderAt("/library");
    expect(await screen.findByText("Same song twice · 1")).toBeInTheDocument();
    expect(screen.getByText("2 likes · in 1 playlist")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Keep the FLAC 24-bit 96 kHz copy on Rumours" }));
    await waitFor(() => expect(sent).toEqual({ keep: "a", remove: ["b"] }));
    await waitFor(() => expect(screen.queryByText("Same song twice · 1")).not.toBeInTheDocument());
  });
});
