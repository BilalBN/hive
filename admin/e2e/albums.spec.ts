import { expect, test } from "@playwright/test";

import { wav } from "./wav";

// An 8×8 PNG, so the cover upload has a real image to store.
const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGM8EaXBgA0wYRUdtBIABvMBWmhZsysAAAAASUVORK5CYII=",
  "base64",
);

test("an album can be corrected and given a cover", async ({ page, request }) => {
  // An album of its own, uploaded the way the family would.
  const name = `Album test ${Date.now()}.wav`;
  await page.goto("/admin/upload");
  await page.getByTestId("choose-files").setInputFiles({ name, mimeType: "audio/wav", buffer: wav() });
  // Loose files uploaded without tags land in the "Uploads" album.
  await expect
    .poll(
      async () => {
        const body = await (await request.get("/api/v1/admin/library/albums?q=Uploads")).json();
        return body.items.reduce((n: number, i: { album: { trackCount: number } }) => n + i.album.trackCount, 0);
      },
      { timeout: 30_000 },
    )
    .toBeGreaterThan(0);
  await page.goto("/admin/library");
  await expect(page.getByRole("heading", { name: /Album details from the internet/ })).toBeVisible();
  await expect(page.getByRole("switch")).not.toBeChecked();

  await page.goto("/admin/albums");
  await expect(page.getByRole("heading", { name: "Albums" })).toBeVisible();
  await page.getByPlaceholder(/Album, artist/).fill("Uploads");
  await page.locator(".row__link").filter({ hasText: "Uploads" }).first().click();
  await expect(page.getByRole("heading", { name: "Details" })).toBeVisible();

  await page.getByLabel("Language").selectOption("ml");
  await page.getByRole("button", { name: "Save changes" }).click();
  await expect(page.getByText("Set by you").first()).toBeVisible();
  await expect(page.locator(".page__summary")).toContainText("Malayalam");

  await page.locator('input[type="file"]').setInputFiles({ name: "cover.png", mimeType: "image/png", buffer: PNG });
  await expect(page.getByRole("button", { name: "Use the files' cover" })).toBeVisible();

  await page.getByRole("button", { name: /Undo/ }).first().click();
  await expect(page.getByText("Set by you")).toHaveCount(0);

  // One song's details, corrected and put back.
  await page
    .getByRole("button", { name: /^Edit / })
    .first()
    .click();
  await page.getByLabel("Song title").fill("Corrected in e2e");
  await page.getByRole("button", { name: "Save song" }).click();
  await expect(page.getByText("Corrected", { exact: true })).toBeVisible();
  await expect(page.locator(".row__title").filter({ hasText: "Corrected in e2e" })).toBeVisible();
  await page.getByRole("button", { name: "Edit Corrected in e2e" }).click();
  await page.getByRole("button", { name: "Undo song title" }).click();
  await expect(page.getByText("Corrected", { exact: true })).toHaveCount(0);
});
