import { expect, test } from "@playwright/test";

import { wav } from "./wav";

test("Overview shows the key for the apps", async ({ page }) => {
  await page.goto("/admin/");
  await expect(page.getByRole("heading", { name: "Key for the apps" })).toBeVisible();
  await expect(page.locator(".key__value")).toHaveText(/^hive-dev-[a-z0-9]{4}(-[a-z0-9]{4}){3}$/);
});

test("Library shows the music folders", async ({ page }) => {
  await page.goto("/admin/library");
  await expect(page.getByRole("heading", { name: "Library" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Music folders" })).toBeVisible();
  await expect(page.locator(".row__title").first()).toHaveText(/music$/);
  await expect(page.getByRole("button", { name: /Scan now|Scanning/ })).toBeVisible();
});

test("an uploaded song is scanned into the library", async ({ page, request }) => {
  const before = (await (await request.get("/api/v1/admin/library/imports")).json()).tracks as number;
  await page.goto("/admin/upload");
  await expect(page.getByRole("heading", { name: "Upload music" })).toBeVisible();
  const name = `E2E tone ${Date.now()}.wav`;
  await page.getByTestId("choose-files").setInputFiles({ name, mimeType: "audio/wav", buffer: wav() });
  await expect(page.getByText("Uploaded · scanning")).toBeVisible({ timeout: 15_000 });

  await expect
    .poll(async () => (await (await request.get("/api/v1/admin/library/imports")).json()).tracks, { timeout: 20_000 })
    .toBe(before + 1);
  await page.goto("/admin/library");
  await expect(page.locator(".card").filter({ hasText: "Songs" })).toContainText(String(before + 1));
});
