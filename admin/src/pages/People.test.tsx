import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { AdminPerson, AdminPersonDetail, AdminSettings } from "../api/people";
import { mockApi, requests } from "../test/mockApi";
import { renderAt } from "../test/render";

const amma: AdminPerson = {
  id: "p2",
  name: "Amma",
  email: "amma@example.com",
  role: "member",
  status: "active",
  devicesUsed: 1,
  deviceLimit: 4,
  simpleMode: true,
  createdAt: "2026-10-18T06:00:00Z",
};

const detail: AdminPersonDetail = {
  person: amma,
  devices: [
    {
      id: "d1",
      personId: "p2",
      personName: "Amma",
      name: "Amma's iPhone",
      platform: "ios",
      appVersion: "0.2.0",
      status: "active",
      createdAt: "2026-10-18T06:00:00Z",
    },
  ],
  swapsUsed: 0,
  swapsPerMonth: 2,
  activity: [],
};

const settings: AdminSettings = {
  homeName: "Arun's home",
  devicesPerPerson: 4,
  swapsPerMonth: 2,
  email: {
    host: "",
    port: 587,
    security: "starttls",
    username: "",
    from: "",
    passwordSet: false,
    ready: false,
  },
};

afterEach(() => vi.unstubAllGlobals());

describe("Signing in", () => {
  it("asks for an email code, then the codes, away from the home computer", async () => {
    const fetch = mockApi({
      "GET /api/v1/admin/session": {
        body: {
          signedIn: false,
          onHomeComputer: false,
          needsSetup: false,
          emailReady: true,
        },
      },
      "POST /api/v1/admin/session/email": {
        body: {
          verificationId: "v1",
          expiresAt: "2099-01-01T00:00:00Z",
          resendAfterSeconds: 30,
          emailSent: true,
        },
      },
      "POST /api/v1/admin/session/email/verify": {
        body: {
          signedIn: true,
          onHomeComputer: false,
          needsSetup: false,
          emailReady: true,
          me: {
            id: "p1",
            name: "Arun",
            email: "arun@example.com",
            authenticator: true,
          },
        },
      },
    });
    renderAt("/");
    fireEvent.change(await screen.findByLabelText("Email"), {
      target: { value: "arun@example.com" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Email me a code" }));
    fireEvent.change(await screen.findByLabelText("Code from the email"), {
      target: { value: "123456" },
    });
    fireEvent.change(screen.getByLabelText(/authenticator app/), {
      target: { value: "654321" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));
    expect(await screen.findByRole("navigation", { name: "Admin sections" })).toBeInTheDocument();
    expect(screen.getByText("Arun")).toBeInTheDocument();
    const verify = fetch.mock.calls.map(([r]) => r as Request).find((r) => r.url.endsWith("/email/verify"))!;
    expect(await verify.clone().json()).toEqual({
      verificationId: "v1",
      code: "123456",
      authenticatorCode: "654321",
    });
  });

  it("explains that setup happens on the home computer", async () => {
    mockApi({
      "GET /api/v1/admin/session": {
        body: {
          signedIn: false,
          onHomeComputer: false,
          needsSetup: true,
          emailReady: false,
        },
      },
    });
    renderAt("/");
    expect(
      await screen.findByRole("heading", {
        name: "Set up Hive Admin at home first",
      }),
    ).toBeInTheDocument();
  });
});

describe("Overview", () => {
  it("shows waiting requests, setup and email alerts", async () => {
    mockApi();
    renderAt("/");
    expect(await screen.findByText("1 person is waiting to be let in.")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Set up the first admin" })).toBeInTheDocument();
    expect(screen.getByText(/Email isn't set up/)).toBeInTheDocument();
    expect(screen.getByLabelText("1 waiting")).toBeInTheDocument();
  });
});

describe("Requests", () => {
  it("lists who's waiting and codes to pass on, and approves", async () => {
    let approved = false;
    mockApi({
      "GET /api/v1/admin/requests": () => ({
        body: approved
          ? {
              items: [
                {
                  ...requests.items[0],
                  status: "approved",
                  decidedAt: new Date().toISOString(),
                  undoUntil: new Date(Date.now() + 9000).toISOString(),
                },
              ],
              codes: [],
            }
          : requests,
      }),
      "POST /api/v1/admin/requests/r1/approve": () => {
        approved = true;
        return { body: { ...requests.items[0], status: "approved" } };
      },
    });
    renderAt("/requests");
    expect(await screen.findByText("482913")).toBeInTheDocument();
    const waiting = screen.getByRole("heading", { name: "Waiting" }).closest("section")!;
    expect(within(waiting).getByText(/Basith's Pixel · Android/)).toBeInTheDocument();
    fireEvent.click(within(waiting).getByRole("button", { name: "Approve" }));
    expect(await screen.findByRole("button", { name: /Undo/ })).toBeInTheDocument();
  });
});

describe("Invite", () => {
  it("creates an invite and shows its code once", async () => {
    mockApi({
      "GET /api/v1/admin/invites": { body: { items: [] } },
      "POST /api/v1/admin/invites": {
        body: {
          id: "i1",
          email: "amma@example.com",
          name: "Amma",
          role: "member",
          createdAt: "2026-10-18T06:00:00Z",
          expiresAt: new Date(Date.now() + 7 * 86400_000).toISOString(),
          code: "HIVE-7K2Q-9MXP",
          joinLink: "hive://join?a=http%3A%2F%2F100.84.12.7%3A8443&c=HIVE-7K2Q-9MXP",
          emailSent: true,
        },
      },
    });
    renderAt("/invite");
    fireEvent.change(await screen.findByLabelText("Name"), {
      target: { value: "Amma" },
    });
    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "amma@example.com" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Create invite" }));
    expect(await screen.findByText("HIVE-7K2Q-9MXP")).toBeInTheDocument();
    expect(screen.getByText(/Hive emailed amma@example.com the code/)).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Invite sent for Amma" })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /QR code for the Hive invite/ })).toBeInTheDocument();
    // The next person can be invited straight away.
    expect(screen.getByRole("heading", { name: "Invite someone else" })).toBeInTheDocument();
    expect(screen.getByLabelText("Name")).toHaveValue("");
    expect(screen.getByRole("button", { name: "Create invite" })).toBeEnabled();
  });
});

describe("People", () => {
  it("opens a person and suspends them", async () => {
    let body: unknown;
    mockApi({
      "GET /api/v1/admin/people": { body: { items: [amma] } },
      "GET /api/v1/admin/people/p2": { body: detail },
      "PATCH /api/v1/admin/people/p2": (req) => {
        body = "pending";
        void req.json().then((b) => (body = b));
        return {
          body: { ...detail, person: { ...amma, status: "suspended" } },
        };
      },
    });
    renderAt("/people");
    fireEvent.click(await screen.findByText("Amma"));
    expect(await screen.findByText("Amma's iPhone")).toBeInTheDocument();
    expect(screen.getByText(/iPhone or iPad · Hive 0.2.0/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Suspend" }));
    expect(await screen.findByRole("button", { name: "Reinstate" })).toBeInTheDocument();
    expect(body).toEqual({ status: "suspended" });
  });
});

describe("Settings", () => {
  it("fills in Gmail's server and saves the app password", async () => {
    let saved: unknown;
    mockApi({
      "GET /api/v1/admin/settings": { body: settings },
      "PATCH /api/v1/admin/settings": (req) => {
        void req.json().then((b) => (saved = b));
        return {
          body: {
            ...settings,
            email: { ...settings.email, ready: true, passwordSet: true },
          },
        };
      },
    });
    renderAt("/settings");
    fireEvent.change(await screen.findByLabelText("Email address (sign-in)"), {
      target: { value: "arun@gmail.com" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Use Gmail settings" }));
    expect(screen.getByLabelText("Mail server")).toHaveValue("smtp.gmail.com");
    fireEvent.change(screen.getByLabelText("App password"), {
      target: { value: "abcd efgh ijkl mnop" },
    });
    const email = screen.getByRole("heading", { name: "Email" }).closest("form")!;
    fireEvent.click(within(email).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(screen.getByText("Ready")).toBeInTheDocument());
    expect(saved).toEqual({
      email: {
        host: "smtp.gmail.com",
        port: 587,
        security: "starttls",
        username: "arun@gmail.com",
        from: "arun@gmail.com",
        password: "abcdefghijklmnop",
      },
    });
  });
});

describe("Notifications", () => {
  it("saves the APNs key and sends a test", async () => {
    let saved: unknown;
    mockApi({
      "GET /api/v1/admin/settings": { body: settings },
      "PUT /api/v1/admin/push": (req) => {
        void req.json().then((b) => (saved = b));
        return {
          body: {
            apnsReady: true,
            keySet: true,
            topic: "dev.hivemusic.hive",
            sandbox: false,
            teamId: "ABCDE12345",
            keyId: "KEY1234567",
          },
        };
      },
      "POST /api/v1/admin/push/test": { body: { sent: 1 } },
    });
    renderAt("/settings");
    expect(await screen.findByRole("heading", { name: "Notifications" })).toBeInTheDocument();
    expect(screen.getByText(/not set yet/)).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Team ID"), { target: { value: "abcde12345" } });
    fireEvent.change(screen.getByLabelText("Key ID"), { target: { value: "KEY1234567" } });
    fireEvent.change(screen.getByLabelText(/APNs key/), { target: { value: "-----BEGIN PRIVATE KEY-----x" } });
    fireEvent.click(screen.getByRole("button", { name: "Save the key" }));
    await waitFor(() =>
      expect(saved).toEqual({ teamId: "ABCDE12345", keyId: "KEY1234567", privateKey: "-----BEGIN PRIVATE KEY-----x" }),
    );
    fireEvent.click(screen.getByRole("button", { name: "Send a test notification" }));
    expect(await screen.findByText(/Sent to the admins' devices/)).toBeInTheDocument();
  });
});
