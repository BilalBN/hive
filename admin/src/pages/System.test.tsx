import { screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { LogLine, SystemHealth } from "../api/system";
import { mockApi } from "../test/mockApi";
import { renderAt } from "../test/render";

const report: SystemHealth = {
  serverVersion: "0.4.0",
  startedAt: "2026-10-20T03:00:00Z",
  uptimeSeconds: 3 * 86400 + 4 * 3600,
  system: "Windows 11",
  python: "3.12.7",
  packaged: true,
  dataFolder: "C:\\ProgramData\\Hive",
  databaseBytes: 20 * 1024 ** 2,
  disks: [
    {
      label: "Hive's data",
      path: "C:\\ProgramData\\Hive",
      freeBytes: 200 * 1024 ** 3,
      totalBytes: 500 * 1024 ** 3,
      level: "ok",
    },
    { label: "Music: Music", path: "D:\\Music", freeBytes: 3 * 1024 ** 3, totalBytes: 1000 * 1024 ** 3, level: "low" },
  ],
  minAppVersion: "0.3.0",
  devices: 6,
  devicesOnOldApps: 1,
  errorsToday: 0,
  warningsToday: 2,
  ffmpeg: true,
  lastBackupAt: new Date().toISOString(),
  problems: [
    {
      key: "disk-low:Music: Music",
      level: "warning",
      text: "The drive for Music: Music is running low (3.0 GB free).",
    },
  ],
};

afterEach(() => vi.unstubAllGlobals());

describe("System health", () => {
  it("shows drives, backups, apps and what needs a look", async () => {
    mockApi({ "GET /api/v1/admin/system": { body: report } });
    renderAt("/system");
    expect(await screen.findByRole("alert")).toHaveTextContent("running low");
    expect(screen.getByText("3 days, 4 hr")).toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Music: Music: 100% used" })).toBeInTheDocument();
    expect(screen.getByText(/1 older than 0.3.0/)).toBeInTheDocument();
  });

  it("says all is well when nothing needs a look", async () => {
    mockApi({ "GET /api/v1/admin/system": { body: { ...report, problems: [], devicesOnOldApps: 0 } } });
    renderAt("/system");
    expect(await screen.findByText(/All good/)).toBeInTheDocument();
  });
});

describe("Logs", () => {
  it("lists lines and filters them", async () => {
    const lines: LogLine[] = [
      { id: 2, at: "2026-10-23T10:00:01Z", level: "WARNING", area: "scan", text: "a folder couldn't be read" },
      { id: 1, at: "2026-10-23T10:00:00Z", level: "INFO", area: "server", text: "Hive started" },
    ];
    const asked: string[] = [];
    mockApi({
      "GET /api/v1/admin/logs": (req) => {
        asked.push(new URL(req.url).search);
        return { body: { items: lines, areas: ["scan", "server"] } };
      },
    });
    renderAt("/logs");
    expect(await screen.findByText("a folder couldn't be read")).toBeInTheDocument();
    expect(screen.getByText("WARN")).toBeInTheDocument();
    const { fireEvent } = await import("@testing-library/react");
    fireEvent.change(screen.getByLabelText("Show"), { target: { value: "ERROR" } });
    await vi.waitFor(() => expect(asked.at(-1)).toContain("level=ERROR"));
  });
});
