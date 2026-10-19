import { screen, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { allSections } from "./nav";
import { mockApi } from "./test/mockApi";
import { renderAt } from "./test/render";

function mockFetch(ok: boolean) {
  if (ok) mockApi();
  else
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => Promise.reject(new TypeError("Failed to fetch"))),
    );
}

describe("Hive Admin shell", () => {
  beforeEach(() => mockFetch(true));
  afterEach(() => vi.unstubAllGlobals());

  it("lists every section in the navigation", async () => {
    renderAt("/");
    const nav = await screen.findByRole("navigation", {
      name: "Admin sections",
    });
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

  it("shows the key for the apps on the Overview", async () => {
    renderAt("/");
    expect(await screen.findByText("hive-dev-7k2q-9mxp-4c8a-tr3z")).toBeInTheDocument();
    expect(await screen.findByText("1,240")).toBeInTheDocument();
  });

  it("says which milestone builds an unbuilt page", async () => {
    renderAt("/backups");
    expect(await screen.findByRole("heading", { name: "Backups" })).toBeInTheDocument();
    expect(screen.getByText("Arrives in M4")).toBeInTheDocument();
  });

  it("explains when the server can't be reached", async () => {
    mockFetch(false);
    renderAt("/");
    expect(await screen.findByRole("alert")).toHaveTextContent("can't reach the Hive server");
    expect(screen.getByText("Offline")).toBeInTheDocument();
  });
});
