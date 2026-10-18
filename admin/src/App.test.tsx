import { screen, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { allSections } from "./nav";
import { renderAt } from "./test/render";

const health = {
  status: "ok",
  homeName: "Arun's home",
  serverVersion: "0.1.0",
  apiVersion: "0.1.0",
  minAppVersion: "0.1.0",
  serverTime: "2026-10-18T06:00:00Z",
};

function mockFetch(ok: boolean) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () =>
      ok
        ? new Response(JSON.stringify(health), { status: 200, headers: { "Content-Type": "application/json" } })
        : Promise.reject(new TypeError("Failed to fetch")),
    ),
  );
}

describe("Hive Admin shell", () => {
  beforeEach(() => mockFetch(true));
  afterEach(() => vi.unstubAllGlobals());

  it("lists every section in the navigation", async () => {
    renderAt("/");
    const nav = await screen.findByRole("navigation", { name: "Admin sections" });
    for (const s of allSections) {
      expect(within(nav).getByRole("link", { name: s.label })).toBeInTheDocument();
    }
  });

  it("shows home as online on the Overview", async () => {
    renderAt("/");
    expect(await screen.findByText("Home is running.")).toBeInTheDocument();
    expect(await screen.findByText("Online")).toBeInTheDocument();
    expect(screen.getAllByText(/Arun's home/).length).toBeGreaterThan(0);
  });

  it("says which milestone builds an unbuilt page", async () => {
    renderAt("/devices");
    expect(await screen.findByRole("heading", { name: "Devices" })).toBeInTheDocument();
    expect(screen.getByText("Arrives in M2")).toBeInTheDocument();
  });

  it("explains when the server can't be reached", async () => {
    mockFetch(false);
    renderAt("/");
    expect(await screen.findByRole("alert")).toHaveTextContent("can't reach the Hive server");
    expect(screen.getByText("Offline")).toBeInTheDocument();
  });
});
