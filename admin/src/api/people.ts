import { api, ApiError, type Problem } from "./client";
import type { components } from "./schema";

// ---------------------------------------------------------------- M2: people, devices and signing in

type S = components["schemas"];
export type AdminSession = S["AdminSession"];
export type EmailStarted = S["EmailStarted"];
export type AuthenticatorSetup = S["AuthenticatorSetup"];
export type AdminOverview = S["AdminOverview"];
export type AdminAlert = S["AdminAlert"];
export type AuditEntry = S["AuditEntry"];
export type AuditPage = S["AuditPage"];
export type AdminRequests = S["AdminRequests"];
export type AdminAccessRequest = S["AdminAccessRequest"];
export type PendingCode = S["PendingCode"];
export type AdminInvite = S["AdminInvite"];
export type InviteCreate = S["InviteCreate"];
export type AdminPerson = S["AdminPerson"];
export type AdminPersonDetail = S["AdminPersonDetail"];
export type PersonEdit = S["PersonEdit"];
export type AdminDevice = S["AdminDevice"];
export type Platform = S["Platform"];
export type AdminSettings = S["AdminSettings"];
export type AdminSettingsEdit = S["AdminSettingsEdit"];
export type EmailTestResult = S["EmailTestResult"];
export type TidyItem = S["TidyItem"];

/** Unwrap an openapi-fetch result, or throw the server's own words. */
function take<T>(r: { data?: T; error?: unknown; response: Response }): T {
  if (r.data === undefined) throw new ApiError(r.response.status, (r.error ?? undefined) as Problem | undefined);
  return r.data;
}

function done(r: { error?: unknown; response: Response }): void {
  if (!r.response.ok) throw new ApiError(r.response.status, (r.error ?? undefined) as Problem | undefined);
}

export const fetchSession = async () => take(await api.GET("/api/v1/admin/session"));
export const signOut = async () => done(await api.DELETE("/api/v1/admin/session"));
export const setUpAdmin = async (body: { name: string; email: string }) =>
  take(await api.POST("/api/v1/admin/setup", { body }));
export const startSignIn = async (email: string) =>
  take(await api.POST("/api/v1/admin/session/email", { body: { email } }));
export const finishSignIn = async (body: { verificationId: string; code: string; authenticatorCode?: string }) =>
  take(await api.POST("/api/v1/admin/session/email/verify", { body }));

export const startAuthenticator = async () => take(await api.POST("/api/v1/admin/me/authenticator"));
export const confirmAuthenticator = async (code: string) =>
  take(await api.PUT("/api/v1/admin/me/authenticator", { body: { code } }));
export const removeAuthenticator = async () => take(await api.DELETE("/api/v1/admin/me/authenticator"));

export const fetchOverview = async () => take(await api.GET("/api/v1/admin/overview"));

export const fetchRequests = async () => take(await api.GET("/api/v1/admin/requests"));
const path = (requestId: string) => ({ params: { path: { requestId } } });
export const approveRequest = async (requestId: string, name?: string) =>
  take(
    await api.POST("/api/v1/admin/requests/{requestId}/approve", {
      ...path(requestId),
      body: name ? { name } : {},
    }),
  );
export const declineRequest = async (requestId: string) =>
  take(
    await api.POST("/api/v1/admin/requests/{requestId}/decline", {
      ...path(requestId),
      body: {},
    }),
  );
export const undoDecision = async (requestId: string) =>
  take(await api.POST("/api/v1/admin/requests/{requestId}/undo", path(requestId)));

export const fetchInvites = async () => take(await api.GET("/api/v1/admin/invites")).items;
export const createInvite = async (body: InviteCreate) => take(await api.POST("/api/v1/admin/invites", { body }));
export const revokeInvite = async (inviteId: string) =>
  done(
    await api.DELETE("/api/v1/admin/invites/{inviteId}", {
      params: { path: { inviteId } },
    }),
  );

export const fetchPeople = async () => take(await api.GET("/api/v1/admin/people")).items;
export const fetchPerson = async (personId: string) =>
  take(
    await api.GET("/api/v1/admin/people/{personId}", {
      params: { path: { personId } },
    }),
  );
export const updatePerson = async (personId: string, body: PersonEdit) =>
  take(
    await api.PATCH("/api/v1/admin/people/{personId}", {
      params: { path: { personId } },
      body,
    }),
  );

export const fetchDevices = async () => take(await api.GET("/api/v1/admin/devices")).items;
export const revokeDevice = async (deviceId: string) =>
  take(
    await api.POST("/api/v1/admin/devices/{deviceId}/revoke", {
      params: { path: { deviceId } },
    }),
  );

export const fetchSettings = async () => take(await api.GET("/api/v1/admin/settings"));
export const updateSettings = async (body: AdminSettingsEdit) =>
  take(await api.PATCH("/api/v1/admin/settings", { body }));
export const testEmail = async (to?: string) =>
  take(
    await api.POST("/api/v1/admin/settings/email/test", {
      body: to ? { to } : {},
    }),
  );

export const fetchAudit = async (offset = 0, limit = 50) =>
  take(
    await api.GET("/api/v1/admin/audit", {
      params: { query: { offset, limit } },
    }),
  );

export const fetchTidy = async () => take(await api.GET("/api/v1/admin/library/tidy")).items;
export const applyTidy = async (trackIds: string[]) =>
  take(await api.POST("/api/v1/admin/library/tidy", { body: { trackIds } })).items;
export const undoTidy = async (trackIds: string[]) =>
  take(await api.POST("/api/v1/admin/library/tidy/undo", { body: { trackIds } })).items;

// ---------------------------------------------------------------- words shared by the pages

export const PLATFORM: Record<Platform, string> = {
  android: "Android",
  ios: "iPhone or iPad",
  macos: "Mac",
  windows: "Windows",
  linux: "Linux",
  web: "Browser",
};

/** "5 minutes ago", "yesterday", or the date. */
export function ago(iso: string, now = Date.now()): string {
  const s = Math.round((now - new Date(iso).getTime()) / 1000);
  if (s < 45) return "just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} hr ago`;
  const d = Math.round(h / 24);
  if (d === 1) return "yesterday";
  if (d < 7) return `${d} days ago`;
  return new Date(iso).toLocaleDateString(undefined, { dateStyle: "medium" });
}

export function until(iso: string, now = Date.now()): string {
  const m = Math.round((new Date(iso).getTime() - now) / 60000);
  if (m <= 0) return "expired";
  if (m < 60) return `${m} min left`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h} hr left`;
  return `${Math.round(h / 24)} days left`;
}
