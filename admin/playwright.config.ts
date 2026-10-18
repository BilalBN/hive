import { defineConfig, devices } from "@playwright/test";

// End-to-end: the real Python server hosting the built panel (run `npm run build` first).
const port = Number(process.env.HIVE_E2E_PORT ?? 18780);
const python = process.env.HIVE_PYTHON ?? "python3";

export default defineConfig({
  testDir: "e2e",
  timeout: 30_000,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    ...devices["Desktop Chrome"],
    launchOptions: process.env.HIVE_CHROMIUM ? { executablePath: process.env.HIVE_CHROMIUM } : {},
  },
  webServer: {
    command: `${python} -m hive serve --host 127.0.0.1 --port ${port}`,
    cwd: "../server",
    url: `http://127.0.0.1:${port}/api/v1/health`,
    reuseExistingServer: false,
    env: {
      HIVE_DATA_DIR: process.env.HIVE_E2E_DATA ?? "../.e2e-data",
      HIVE_HOME_NAME: "E2E home",
      HIVE_ADMIN_DIST: "../admin/dist",
    },
  },
});
