import { expect, test } from "@playwright/test";

// M3 against the real server: a song asked for from Search shows on Requests
// and can be marked added; Recognition shows the fingerprint coverage.
test("a song asked for shows on Requests and is marked added", async ({ page, request }) => {
  const key = (await (await request.get("/api/v1/admin/development-key")).json()).key as string;
  const title = `E2E song ${Date.now()}`;
  const asked = await request.post("/api/v1/listen/requests", {
    headers: { Authorization: `Bearer ${key}` },
    data: { source: "search", title, artist: "E2E band", note: "From a wedding" },
  });
  expect(asked.ok()).toBe(true);

  await page.goto("/admin/requests");
  const songs = page.getByRole("region", { name: "Songs people asked for" });
  const row = songs.locator(".row", { hasText: title });
  await expect(row).toContainText("from Search");
  await row.getByRole("button", { name: "Added" }).click();
  await expect(row.getByRole("button", { name: "Undo" })).toBeVisible();
  await expect(row).toContainText("added");
});

test("Recognition shows how many songs Listen can recognise", async ({ page }) => {
  await page.goto("/admin/recognition");
  await expect(page.getByRole("heading", { name: "Songs Listen can recognise" })).toBeVisible();
  await expect(page.getByRole("progressbar", { name: "Songs fingerprinted" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Start over" })).toBeVisible();
});
