import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { Backup, BackupStatus } from "../api/backups";
import { mockApi } from "../test/mockApi";
import { renderAt } from "../test/render";

const daily: Backup = {
  id: "hive-backup-20261021-030000000-scheduled.zip",
  at: "2026-10-21T03:00:00Z",
  sizeBytes: 48 * 1024 ** 2,
  kind: "scheduled",
  serverVersion: "0.3.0",
  people: 4,
  tracks: 1240,
};

const status: BackupStatus = {
  folder: "/Volumes/Backup/Hive",
  enabled: true,
  time: "03:00",
  keep: 14,
  running: false,
  lastAt: "2026-10-21T03:00:00Z",
  items: [daily],
};

afterEach(() => vi.unstubAllGlobals());

describe("Backups", () => {
  it("lists backups and makes one now", async () => {
    let ran = false;
    mockApi({
      "GET /api/v1/admin/backups": () => ({
        body: ran ? { ...status, items: [{ ...daily, id: "new", kind: "manual" }, daily] } : status,
      }),
      "POST /api/v1/admin/backups": () => {
        ran = true;
        return { body: { ...daily, id: "new", kind: "manual" } };
      },
    });
    renderAt("/backups");
    expect(await screen.findByText(/Daily · 48.0 MB · 4 people · 1,240 songs/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Back up now" }));
    expect(await screen.findByText(/Made by hand/)).toBeInTheDocument();
  });

  it("restores at the next start, and the restore can be cancelled", async () => {
    let staged = false;
    vi.stubGlobal("confirm", () => true);
    const pendingRestore = { id: daily.id, backupAt: daily.at, stagedAt: "2026-10-22T10:00:00Z" };
    mockApi({
      "GET /api/v1/admin/backups": () => ({ body: staged ? { ...status, pendingRestore } : status }),
      [`POST /api/v1/admin/backups/${daily.id}/restore`]: () => {
        staged = true;
        return { body: { ...status, pendingRestore } };
      },
      "DELETE /api/v1/admin/backups/restore": () => {
        staged = false;
        return { body: status };
      },
    });
    renderAt("/backups");
    const row = (await screen.findByText(/Daily · 48.0 MB/)).closest("li")!;
    fireEvent.click(within(row).getByRole("button", { name: "Restore" }));
    expect(await screen.findByText(/Restore waiting/)).toBeInTheDocument();
    expect(within(row).getByRole("button", { name: "Restore" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "Cancel restore" }));
    await waitFor(() => expect(screen.queryByText(/Restore waiting/)).toBeNull());
  });

  it("saves the schedule and folder, and says when the folder can't be used", async () => {
    let sent: unknown;
    mockApi({
      "GET /api/v1/admin/backups": { body: status },
      "PUT /api/v1/admin/backups/settings": (req) => {
        void req.json().then((b) => (sent = b));
        return { status: 422, body: { title: "Invalid", status: 422, detail: "Hive can't write to E:\\x." } };
      },
    });
    renderAt("/backups");
    const folder = await screen.findByLabelText("Backup folder");
    fireEvent.change(folder, { target: { value: "E:\\x" } });
    fireEvent.change(screen.getByLabelText("At"), { target: { value: "02:30" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(await screen.findByText(/can't write/)).toBeInTheDocument();
    expect(sent).toEqual({ enabled: true, time: "02:30", keep: 14, folder: "E:\\x" });
  });

  it("says plainly when the last backup failed", async () => {
    mockApi({
      "GET /api/v1/admin/backups": {
        body: { ...status, lastError: "Hive can't reach the backup folder. Is the drive connected?" },
      },
    });
    renderAt("/backups");
    expect(await screen.findByRole("alert")).toHaveTextContent("Is the drive connected?");
  });
});
