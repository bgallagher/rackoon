// End-to-end tests of the web app in demo mode (nothing is sent anywhere). By default they start the backend from
// this checkout (it serves web/frontend/dist, so build the UI first); set RACKOON_E2E_URL to test a running copy
// instead, such as the Docker image in CI.
import { defineConfig, devices } from "@playwright/test";

const external = process.env.RACKOON_E2E_URL;
const port = 8095;

export default defineConfig({
  testDir: "./tests",
  timeout: 60_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1, // one demo backend holds state (installed updates, uploaded files) shared by the tests
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["list"], ["junit", { outputFile: "results/junit.xml" }]] : "list",
  use: {
    baseURL: external ?? `http://127.0.0.1:${port}`,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"], viewport: { width: 1360, height: 900 } } }],
  webServer: external ? undefined : {
    command: `cd ../backend && RACKOON_DEMO=1 RACKOON_STATIC=../frontend/dist RACKOON_PORT=${port} RACKOON_HOST=127.0.0.1 uv run python -m rackoon.app`,
    url: `http://127.0.0.1:${port}/api/health`,
    reuseExistingServer: false,
    timeout: 60_000,
  },
});
