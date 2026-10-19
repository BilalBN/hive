import { fireEvent, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { kumbalangi, lookup, mockApi } from "../test/mockApi";
import { renderAt } from "../test/render";

afterEach(() => vi.unstubAllGlobals());

const page = {
  items: [
    {
      album: {
        id: "kn",
        title: "Kumbalangi Nights",
        artistName: "Sushin Shyam",
        year: 2019,
        language: "ml",
        trackCount: 2,
        tier: "lossless",
        addedAt: "2026-10-18T06:00:00Z",
      },
      lookup: "review",
    },
  ],
  total: 1,
  offset: 0,
};

describe("Lookup on the Library page", () => {
  it("shows progress, what leaves home, and turns off", async () => {
    const fetchMock = mockApi({
      "PATCH /api/v1/admin/library/lookup": (req) => {
        void req;
        return { body: { ...lookup, enabled: false } };
      },
    });
    renderAt("/library");
    expect(await screen.findByText(/80 filled in · 2 to check · 6 not found/)).toBeInTheDocument();
    expect(screen.getByText(/Never the music itself/)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /Check 2 matches/ })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("switch"));
    expect(await screen.findByText(/Off\. Albums show what their files say/)).toBeInTheDocument();
    const patch = fetchMock.mock.calls.map(([r]) => r as Request).find((r) => r.method === "PATCH")!;
    expect(await patch.clone().json()).toEqual({ enabled: false });
  });
});

describe("Albums page", () => {
  it("approves a match and sets a language right in the list", async () => {
    const found = {
      title: "Kumbalangi Nights",
      artistName: "Sushin Shyam",
      year: 2019,
      language: "ml",
      score: 0.62,
      source: "MusicBrainz · Wikidata",
    };
    const items = [
      { album: { ...page.items[0].album, language: undefined }, lookup: "review", found },
      {
        album: { ...page.items[0].album, id: "pm", title: "Premam", language: undefined },
        lookup: "review",
        found: { ...found, title: "Premam" },
      },
    ];
    const fetchMock = mockApi({
      "GET /api/v1/admin/library/albums": { body: { items, total: 2, offset: 0 } },
      "POST /api/v1/admin/library/albums/kn/match": { body: kumbalangi },
      "POST /api/v1/admin/library/albums/pm/match": { body: kumbalangi },
      "PATCH /api/v1/admin/library/albums/kn": { body: kumbalangi },
    });
    renderAt("/albums?filter=review");
    const row = (await screen.findByRole("link", { name: "Kumbalangi Nights" })).closest("li")!;
    expect(row).toHaveTextContent(/Found Kumbalangi Nights · 2019 · Malayalam/);
    expect(row).toHaveTextContent("62% sure");
    fireEvent.change(screen.getByLabelText("Language of Kumbalangi Nights"), { target: { value: "ml" } });
    fireEvent.click(screen.getAllByRole("button", { name: "Approve" })[0]);
    fireEvent.click(screen.getByRole("button", { name: "Approve all 2" }));
    await waitFor(() => {
      const calls = fetchMock.mock.calls.map(
        ([r]) => `${(r as Request).method} ${new URL((r as Request).url).pathname}`,
      );
      expect(calls).toContain("PATCH /api/v1/admin/library/albums/kn");
      expect(calls).toContain("POST /api/v1/admin/library/albums/kn/match");
      expect(calls).toContain("POST /api/v1/admin/library/albums/pm/match");
    });
  });

  it("lists albums to check and opens one", async () => {
    mockApi({
      "GET /api/v1/admin/library/albums": { body: page },
      "GET /api/v1/admin/library/albums/kn": { body: kumbalangi },
    });
    renderAt("/albums?filter=review");
    const link = await screen.findByRole("link", { name: "Kumbalangi Nights" });
    expect(link.closest("li")).toHaveTextContent("To check");
    expect(screen.getByRole("button", { name: "To check" })).toHaveAttribute("aria-pressed", "true");
    fireEvent.click(link);
    expect(await screen.findByText("Is this the album?")).toBeInTheDocument();
    expect(screen.getByText(/62% sure · MusicBrainz · Wikidata/)).toBeInTheDocument();
    expect(screen.getByText(/Film: Kumbalangi Nights \(2019\)/)).toBeInTheDocument();
    expect(screen.getByText("from the titles' script")).toBeInTheDocument();
    expect(screen.getByText(/Music: Sushin Shyam · Lyrics: Anwar Ali/)).toBeInTheDocument();
  });

  it("accepts a match", async () => {
    const fetchMock = mockApi({
      "GET /api/v1/admin/library/albums/kn": { body: kumbalangi },
      "POST /api/v1/admin/library/albums/kn/match": {
        body: { ...kumbalangi, lookup: "found", found: undefined, lookupNote: "Added album details from MusicBrainz." },
      },
    });
    renderAt("/albums?album=kn");
    fireEvent.click(await screen.findByRole("button", { name: /Yes, use this/ }));
    expect(await screen.findByText("Filled in")).toBeInTheDocument();
    expect(screen.queryByText("Is this the album?")).not.toBeInTheDocument();
    const post = fetchMock.mock.calls.map(([r]) => r as Request).find((r) => r.method === "POST")!;
    expect(await post.clone().json()).toEqual({ accept: true });
  });

  it("saves only what changed, and can undo it", async () => {
    let saved: unknown;
    mockApi({
      "GET /api/v1/admin/library/albums/kn": { body: { ...kumbalangi, lookup: "found", found: undefined } },
      "PATCH /api/v1/admin/library/albums/kn": (req) => {
        void req
          .clone()
          .json()
          .then((b) => (saved = b));
        return {
          body: {
            ...kumbalangi,
            lookup: "edited",
            found: undefined,
            edited: ["language"],
            sources: { language: "admin" },
            album: { ...kumbalangi.album, language: "ta" },
          },
        };
      },
    });
    renderAt("/albums?album=kn");
    const language = await screen.findByLabelText("Language");
    fireEvent.change(language, { target: { value: "ta" } });
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    await waitFor(() => expect(saved).toEqual({ language: "ta" }));
    expect(await screen.findByText("Set by you")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Undo/ })).toBeInTheDocument();
  });

  it("finds lyrics online, then saves them", async () => {
    const lrc = "[00:12.00]Cherathukal\n[00:15.50]Ninnil";
    const fetchMock = mockApi({
      "GET /api/v1/admin/library/albums/kn": { body: kumbalangi },
      "GET /api/v1/admin/library/tracks/t1/lyrics": {
        body: { text: "", source: "none", kind: "none", fileHasLyrics: false },
      },
      "POST /api/v1/admin/library/tracks/t1/lyrics/find": {
        body: { found: true, text: lrc, kind: "synced", message: "Timed lyrics from LRCLIB." },
      },
      "PUT /api/v1/admin/library/tracks/t1/lyrics": {
        body: { text: lrc, source: "admin", kind: "synced", fileHasLyrics: false },
      },
    });
    renderAt("/albums?album=kn");
    fireEvent.click(await screen.findByRole("button", { name: "Lyrics for ചെരാതുകൾ" }));
    expect(await screen.findByText("No lyrics yet.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Find online/ }));
    expect(await screen.findByText(/Timed lyrics from LRCLIB. Check them, then Save./)).toBeInTheDocument();
    expect(screen.getByRole("textbox", { name: "Lyrics for ചെരാതുകൾ" })).toHaveValue(lrc.replace("\\n", "\n"));
    fireEvent.click(screen.getByRole("button", { name: "Save lyrics" }));
    expect(await screen.findByText("Saved. The app shows these now.")).toBeInTheDocument();
    const put = fetchMock.mock.calls.map(([r]) => r as Request).find((r) => r.method === "PUT")!;
    expect(await put.clone().json()).toEqual({ text: lrc });
  });
});
