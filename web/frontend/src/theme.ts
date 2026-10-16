// The palette comes from the backend (AppPalette.derive in the Python core, WCAG-clamped). Both resolutions arrive
// at once, so the page follows the browser's light/dark setting by CSS alone.
import type { Appearance, Palette, Role } from "./types";

function vars(p: Palette): string {
  const role = (name: string, r: Role) =>
    `--${name}-mark:${r.mark};--${name}-label:${r.label};--${name}-fill:${r.fill};--${name}-on-fill:${r.onFill};`;
  return [
    `--bg:${p.background};--sidebar:${p.sidebar};--card:${p.card};--selection:${p.selection};--border:${p.border};`,
    `--text:${p.textPrimary};--text-2:${p.textSecondary};--muted:${p.textMuted};--dim:${p.textDim};`,
    `--accent:${p.accent};--accent-text:${p.accentText};--ok:${p.ok};--warn:${p.warn};--danger:${p.danger};--idle:${p.idle};`,
    `--warn-bg:${p.warnBackground};--warn-border:${p.warnBorder};--warn-chip:${p.warnChip};--warn-text:${p.warnText};`,
    role("ok", p.okRole), role("warn", p.warnRole), role("danger", p.dangerRole), role("info", p.info),
    role("tailscale", p.scopeTailscale), role("local", p.scopeLocal), role("public", p.scopePublic),
    p.series.map((r, i) => role(`series${i}`, r)).join(""),
    `color-scheme:${p.isDark ? "dark" : "light"};`,
  ].join("");
}

export function applyAppearance(a: Appearance): void {
  let style = document.getElementById("rackoon-theme");
  if (!style) {
    style = document.createElement("style");
    style.id = "rackoon-theme";
    document.head.appendChild(style);
  }
  style.textContent =
    `:root{${vars(a.dark.palette)}}` + `@media (prefers-color-scheme: light){:root{${vars(a.light.palette)}}}`;
}
