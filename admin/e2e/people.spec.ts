import { expect, test } from "@playwright/test";

// The whole way in, against the real server: an invite made in Hive Admin, a
// phone proving its email with the code shown on Requests (no email set up
// here), and the invited person let in at once.
test("an invited person joins with the code passed on from Requests", async ({ page, request }) => {
  const email = `e2e-${Date.now()}@example.com`;

  await page.goto("/admin/invite");
  await page.getByLabel("Name").fill("E2E cousin");
  await page.getByLabel("Email").fill(email);
  await page.getByRole("button", { name: "Create invite" }).click();
  const code = (await page.locator(".invite__code").textContent())!.trim();
  expect(code.length).toBeGreaterThan(5);
  await expect(page.getByRole("img", { name: /QR code for the Hive invite/ })).toBeVisible();

  const invite = await request.post("/api/v1/auth/invites/resolve", { data: { code } });
  expect(invite.ok()).toBe(true);
  expect((await invite.json()).valid).toBe(true);

  const started = await request.post("/api/v1/auth/email/start", {
    data: { email, inviteCode: code, deviceName: "E2E Pixel", platform: "android" },
  });
  expect(started.ok()).toBe(true);
  const { verificationId, emailSent } = await started.json();
  expect(emailSent).toBe(false);

  // Email isn't set up, so the code waits on Requests for the admin to pass on.
  await page.goto("/admin/requests");
  const row = page.locator(".row", { hasText: email }).filter({ has: page.locator(".code-chip") });
  const emailCode = (await row.locator(".code-chip").textContent())!.trim();
  expect(emailCode).toMatch(/^\d{6}$/);

  const verified = await request.post("/api/v1/auth/email/verify", { data: { verificationId, code: emailCode } });
  expect(verified.ok()).toBe(true);
  expect((await verified.json()).status).toBe("approved");

  await page.reload();
  const decided = page.getByRole("heading", { name: "Recently decided" }).locator("..");
  await expect(decided.getByText(email)).toBeVisible();
  await expect(decided.getByText(/Approved \(invited\)/)).toBeVisible();
});
