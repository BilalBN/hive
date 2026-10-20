import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { RecognitionStatus, SongRequest } from "../api/listen";
import { mockApi } from "../test/mockApi";
import { renderAt } from "../test/render";

const status: RecognitionStatus = {
  tracks: 1240,
  fingerprinted: 930,
  waiting: 310,
  working: true,
  failed: 2,
  ffmpeg: true,
  matchesThisWeek: 9,
  noMatchThisWeek: 3,
  requestsWaiting: 1,
};

const heard: SongRequest = {
  id: "sr1",
  at: "2026-10-20T06:00:00Z",
  source: "listen",
  status: "waiting",
  note: "On the radio in the car",
  heardAt: "2026-10-20T05:58:00Z",
  personName: "Amma",
};

afterEach(() => vi.unstubAllGlobals());

describe("Recognition", () => {
  it("shows how many songs Listen knows and how it did this week", async () => {
    mockApi({ "GET /api/v1/admin/recognition": { body: status } });
    renderAt("/recognition");
    expect(await screen.findByText("930")).toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Songs fingerprinted" })).toHaveAttribute("aria-valuenow", "75");
    expect(screen.getByText(/310 to go/)).toBeInTheDocument();
    expect(screen.getByText(/2 songs couldn't be fingerprinted/)).toBeInTheDocument();
    expect(screen.getByText("of 12 times someone used Listen")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Waiting on Requests" })).toBeInTheDocument();
  });

  it("starts the fingerprints over after asking", async () => {
    const fetch = mockApi({
      "GET /api/v1/admin/recognition": { body: { ...status, working: false, waiting: 0, fingerprinted: 1240 } },
      "POST /api/v1/admin/recognition/rebuild": {
        body: { ...status, fingerprinted: 0, waiting: 1240, rebuiltAt: "2026-10-20T06:00:00Z" },
      },
    });
    vi.stubGlobal("confirm", () => true);
    renderAt("/recognition");
    expect(await screen.findByText(/Up to date/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Start over" }));
    expect(await screen.findByText(/1,240 to go/)).toBeInTheDocument();
    expect(fetch.mock.calls.some(([r]) => (r as Request).method === "POST")).toBe(true);
  });

  it("says plainly when FFmpeg is missing", async () => {
    mockApi({ "GET /api/v1/admin/recognition": { body: { ...status, ffmpeg: false } } });
    renderAt("/recognition");
    expect(await screen.findByRole("alert")).toHaveTextContent("Listen needs FFmpeg");
  });
});

describe("Songs people asked for", () => {
  it("lists them on Requests and marks one added", async () => {
    let decided: unknown;
    mockApi({
      "GET /api/v1/admin/requests": { body: { items: [], codes: [] } },
      "GET /api/v1/admin/song-requests": () => ({
        body: { items: decided ? [{ ...heard, status: "added" }] : [heard] },
      }),
      "PATCH /api/v1/admin/song-requests/sr1": (req) => {
        decided = true;
        void req.json().then((b) => (decided = b));
        return { body: { ...heard, status: "added" } };
      },
    });
    renderAt("/requests");
    const panel = await screen.findByRole("region", { name: "Songs people asked for" });
    const row = await within(panel).findByText("A song Listen heard");
    const li = row.closest("li")!;
    expect(within(li).getByText(/Amma · from Listen/)).toBeInTheDocument();
    expect(within(li).getByText("“On the radio in the car”")).toBeInTheDocument();
    expect(within(li).queryByText(/no name was given/)).toBeNull(); // the note says something
    fireEvent.click(within(li).getByRole("button", { name: "Mark as added" }));
    await waitFor(() => expect(decided).toEqual({ status: "added" }));
    expect(await within(panel).findByRole("button", { name: "Undo" })).toBeInTheDocument();
    expect(within(panel).getByText("Done lately")).toBeInTheDocument();
    expect(within(panel).getByText("Added")).toBeInTheDocument();
  });
});
