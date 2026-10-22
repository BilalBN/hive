import { expect, test } from "@playwright/test";

// M4 against the real server: a backup made from Hive Admin is listed with
// what's in it.
test("back up now from Hive Admin", async ({ page }) => {
  await page.goto("/admin/backups");
  await expect(page.getByRole("heading", { name: "Backups", level: 1 })).toBeVisible();
  const before = await page.locator(".row").count();
  await page.getByRole("button", { name: "Back up now" }).click();
  await expect(page.locator(".row")).toHaveCount(before + 1);
  await expect(page.locator(".row").first()).toContainText("Made by hand");
});
