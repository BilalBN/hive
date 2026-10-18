import { expect, test } from "@playwright/test";

/** A short, unique WAV file: Hive reads WAV, and no FFmpeg is needed to make one. */
function wav(seconds = 1, rate = 44100): Buffer {
  const freq = 220 + Math.floor(Math.random() * 600);
  const n = seconds * rate;
  const buf = Buffer.alloc(44 + n * 2);
  buf.write("RIFF", 0);
  buf.writeUInt32LE(36 + n * 2, 4);
  buf.write("WAVE", 8);
  buf.write("fmt ", 12);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20); // PCM
  buf.writeUInt16LE(1, 22); // mono
  buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * 2, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write("data", 36);
  buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) {
    const v = Math.sin((2 * Math.PI * freq * i) / rate) * 0.3 + (Math.random() - 0.5) * 0.01;
    buf.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  return buf;
}

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
