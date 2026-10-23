import { api, ApiError, type Problem } from "./client";
import type { components } from "./schema";

// ---------------------------------------------------------------- M4: backups

type S = components["schemas"];
export type Backup = S["Backup"];
export type BackupStatus = S["BackupStatus"];
export type BackupSettings = S["BackupSettings"];

function take<T>(r: { data?: T; error?: unknown; response: Response }): T {
  if (r.data === undefined) throw new ApiError(r.response.status, (r.error ?? undefined) as Problem | undefined);
  return r.data;
}

const id = (backupId: string) => ({ params: { path: { backupId } } });

export const fetchBackups = async () => take(await api.GET("/api/v1/admin/backups"));
export const runBackup = async () => take(await api.POST("/api/v1/admin/backups"));
export const saveBackupSettings = async (body: BackupSettings) =>
  take(await api.PUT("/api/v1/admin/backups/settings", { body }));
export type FolderMove = { from: string; to: string };
export const restoreBackup = async (backupId: string, folders: FolderMove[] = []) =>
  take(
    await api.POST("/api/v1/admin/backups/{backupId}/restore", {
      ...id(backupId),
      body: folders.length ? { folders } : {},
    }),
  );
export const cancelRestore = async () => take(await api.DELETE("/api/v1/admin/backups/restore"));
export const deleteBackup = async (backupId: string) => {
  const r = await api.DELETE("/api/v1/admin/backups/{backupId}", id(backupId));
  if (!r.response.ok) throw new ApiError(r.response.status, (r.error ?? undefined) as Problem | undefined);
};
