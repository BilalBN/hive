import { expect, test } from "@playwright/test";

test("the server hosts Hive Admin and it shows home online", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveURL(/\/admin\/$/);
  await expect(page.getByRole("heading", { name: "Overview" })).toBeVisible();
  await expect(page.getByText("Home is running.")).toBeVisible();
  await expect(page.getByText("E2E home online")).toBeVisible();
});

test("client-side pages load directly and say when they arrive", async ({ page }) => {
  await page.goto("/admin/devices");
  await expect(page.getByRole("heading", { name: "Devices" })).toBeVisible();
  await expect(page.getByText("Arrives in M2")).toBeVisible();
  await page.getByRole("link", { name: "Overview" }).click();
  await expect(page).toHaveURL(/\/admin\/$/);
});

test("theme toggle switches between system, dark and light", async ({ page }) => {
  await page.goto("/admin/");
  const toggle = page.getByRole("button", { name: /theme/i });
  await toggle.click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await toggle.click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  await toggle.click();
  await expect(page.locator("html")).not.toHaveAttribute("data-theme", /.+/);
});

test("fonts and icons come from the server, never a CDN", async ({ page, baseURL }) => {
  const home = new URL(baseURL!).host;
  const requests: string[] = [];
  page.on("request", (r) => requests.push(r.url()));
  await page.goto("/admin/");
  await expect(page.getByText("Home is running.")).toBeVisible();
  await page.evaluate(() => document.fonts.ready);
  const external = requests.filter((u) => !u.startsWith("data:") && new URL(u).host !== home);
  expect(requests.some((u) => /inter-latin-\d+-normal.*\.woff2$/.test(u))).toBe(true);
  expect(external).toEqual([]);
});
