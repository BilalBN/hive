import { fireEvent, screen } from "@testing-library/react";
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
    mockApi({ "GET /api/v1/admin/library/imports": { body: { ...library, ffmpeg: false } } });
    renderAt("/library");
    expect(await screen.findByText(/FFmpeg isn't installed/)).toBeInTheDocument();
  });

  it("starts a scan and shows the queue", async () => {
    const scanning = {
      ...library,
      scanning: true,
      queued: 2,
      queue: [
        { id: "1", path: "Premam/01 Malare.flac", status: "working", updatedAt: "2026-10-18T06:00:00Z" },
        { id: "2", path: "Premam/02 Aluva Puzha.flac", status: "queued", updatedAt: "2026-10-18T06:00:00Z" },
      ],
    };
    const fetchMock = mockApi({ "POST /api/v1/admin/library/scan": { body: scanning } });
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
    const withCopies = { ...library, duplicates: [copy, { ...copy, id: "10", path: "Uploads/English/New/Kiss me.mp3" }] };
    const cleaned = { ...library, duplicates: [] };
    const fetchMock = mockApi({
      "GET /api/v1/admin/library/imports": { body: withCopies },
      "POST /api/v1/admin/library/imports/delete-copies": { body: cleaned },
      "POST /api/v1/admin/library/imports/7/ignore": { body: { ...withCopies, needsAttention: [] } },
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

  it("explains that Hive Admin opens on the home computer for now", async () => {
    mockApi({
      "GET /api/v1/admin/library/imports": { status: 401, body: { title: "Sign-in needed", status: 401 } },
    });
    renderAt("/library");
    expect(await screen.findByRole("alert")).toHaveTextContent("only opens on the home computer");
  });
});
