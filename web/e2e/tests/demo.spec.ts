// The web app end to end, in demo mode: made-up servers, nothing is sent anywhere. Each test drives the UI the way a
// person would and checks what the page shows; the rules themselves are tested in the backend's own suites.
import { expect, test, type Page } from "@playwright/test";

const LAB = "/#/servers/demo-homelab";

async function allowChanges(page: Page): Promise<void> {
  const sw = page.getByRole("switch");
  await expect(sw).toBeVisible();
  if ((await sw.getAttribute("aria-checked")) === "true") {
    await sw.click();
    await expect(sw).toHaveAttribute("aria-checked", "false");
  }
}

async function runCommand(page: Page, title: string | RegExp): Promise<void> {
  const sheet = page.getByRole("dialog", { name: title });
  await expect(sheet).toBeVisible();
  await sheet.getByRole("button", { name: "Run Command" }).click();
  await expect(sheet).toBeHidden();
}

test.beforeEach(async ({ page }) => {
  await page.goto("/#/dashboard");
  await allowChanges(page);
});

test("the dashboard shows the fleet and every page", async ({ page }) => {
  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible();
  await expect(page.locator(".health-name").filter({ hasText: "homelab" })).toBeVisible();
  await page.goto("/#/dashboard/docker");
  await expect(page.locator(".stack-mini").filter({ hasText: "jellyfin" })).toBeVisible();
  await page.goto("/#/dashboard/bookmarks");
  await expect(page.getByText("Immich").first()).toBeVisible();
});

test("an overview with its attention strip, and a refused login explained", async ({ page }) => {
  await page.goto(LAB);
  await expect(page.getByRole("heading", { name: "homelab" })).toBeVisible();
  await expect(page.getByLabel("Needs attention")).toContainText("Reboot required");
  await expect(page.getByLabel("Needs attention")).toContainText("promtail is unhealthy");
  await page.goto("/#/servers/demo-backup");
  await expect(page.getByText("Edit Connection…")).toBeVisible();
});

test("Docker: a stack's logs, Update through the sheet into Output", async ({ page }) => {
  await page.goto(`${LAB}/docker`);
  await page.locator(".stack-tile-main").filter({ hasText: "grafana" }).click();
  await expect(page.getByRole("heading", { name: "grafana" })).toBeVisible();
  await expect(page.locator(".logs-list")).toContainText("ready to accept connections");
  await page.getByRole("button", { name: "Stack Actions ▾" }).click();
  await page.getByRole("menuitem", { name: /^Update…/ }).click();
  await runCommand(page, "Update grafana?");
  await expect(page.locator(".output-title")).toHaveText("docker compose up: done");
});

test("the compose editor checks on the server and saves against the sha", async ({ page }) => {
  await page.goto(`${LAB}/docker/stack/uptime-kuma`);
  await page.getByRole("tab", { name: "compose.yaml" }).click();
  const editor = page.getByLabel("compose.yaml", { exact: true });
  await expect(editor).toHaveValue(/uptime-kuma/);
  await editor.fill(`${await editor.inputValue()}# tuned by e2e\n`);
  await expect(page.locator(".checklist")).toContainText("docker compose config");
  await page.getByRole("button", { name: "Save…" }).click();
  await runCommand(page, "Save compose.yaml?");
  await expect(page.getByText(/Saved compose\.yaml/)).toBeVisible();
});

test("a terminal tab runs the demo shell", async ({ page }) => {
  await page.goto(`${LAB}/terminal`);
  const open = page.getByRole("button", { name: "Open a Shell" });
  const term = page.locator(".xterm");
  await expect(open.or(term)).toBeVisible();
  if (await open.isVisible()) await open.click();
  await expect(term).toBeVisible();
  await term.click();
  await page.keyboard.type("whoami\n");
  await expect(page.locator(".xterm-rows")).toContainText("ubuntu");
});

test("apt asks for the sudo password and runs with it", async ({ page }) => {
  await page.goto(`${LAB}/updates`);
  await expect(page.getByText(/updates? available|up to date/)).toBeVisible();
  await page.getByRole("button", { name: "Refresh Lists…" }).click();
  await runCommand(page, "Refresh package lists?");
  const sheet = page.getByRole("dialog", { name: /sudo password for/ });
  await expect(sheet).toBeVisible();
  await sheet.getByLabel("sudo password").fill("demo");
  await sheet.getByRole("button", { name: "Continue…" }).click();
  await runCommand(page, "Refresh package lists?");
  await expect(page.locator(".output-title")).toContainText("done");
  await expect(page.locator(".xterm-rows")).toContainText("Reading package lists... Done");
});

test("files: upload through the sheet", async ({ page }) => {
  await page.goto(`${LAB}/files`);
  await expect(page.getByText("notes")).toBeVisible();
  const name = `hello-${Date.now()}.txt`;
  await page.locator('input[type="file"]').setInputFiles({ name, mimeType: "text/plain",
    buffer: Buffer.from("hello from e2e\n") });
  await runCommand(page, `Upload ${name}?`);
  await expect(page.locator(".transfers")).toContainText("uploaded");
  await expect(page.locator(".files").getByText(name)).toBeVisible();
});

test("search finds a failed service and opens it", async ({ page }) => {
  await page.goto(`${LAB}/services`);
  await expect(page.getByText("backup-sync").first()).toBeVisible();
  await page.goto("/#/dashboard");
  await page.keyboard.press("/");
  const box = page.getByRole("dialog", { name: "Search" }).getByRole("searchbox");
  await box.fill("backup-sync");
  await expect(page.locator(".search-row").first()).toContainText("backup-sync");
  await page.keyboard.press("Enter");
  await expect(page.getByRole("heading", { name: "Services" })).toBeVisible();
});

test("alerts list what needs you", async ({ page }) => {
  await page.goto(LAB);
  await page.goto(`${LAB}/alerts`);
  await page.getByRole("button", { name: "Check Now" }).click();
  await expect(page.locator(".alerts")).toContainText("backup-sync failed");
});

test("Read-only blocks changes until it is turned off", async ({ page }) => {
  const sw = page.getByRole("switch");
  await sw.click();
  await expect(sw).toHaveAttribute("aria-checked", "true");
  await page.goto(`${LAB}/docker/stack/grafana`);
  await expect(page.getByText("Read-only", { exact: true }).last()).toBeVisible();
  await page.getByRole("button", { name: "Stack Actions ▾" }).click();
  await expect(page.getByRole("menuitem", { name: /^Update…/ })).toBeDisabled();
});

test("a theme changes the whole page", async ({ page }) => {
  const before = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  await page.goto("/#/settings/appearance");
  const dracula = page.getByRole("button", { name: /Dracula/ }).first();
  const pick = (await dracula.getAttribute("class"))?.includes("selected") ? page.getByRole("button", { name: /Nord/ }).first() : dracula;
  await pick.click();
  await expect.poll(() => page.evaluate(() => getComputedStyle(document.body).backgroundColor)).not.toBe(before);
});

test("phone width: no sideways scrolling", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  for (const path of ["/#/dashboard", LAB, `${LAB}/docker`, `${LAB}/updates`, `${LAB}/files`]) {
    await page.goto(path);
    await page.waitForLoadState("networkidle");
    const wide = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(wide, path).toBeLessThanOrEqual(1);
  }
});
