// Presentation only: how numbers the backend sends are written on screen.

export function bytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return "—";
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let value = n;
  let i = 0;
  while (value >= 1000 && i < units.length - 1) {
    value /= 1000;
    i++;
  }
  return `${value >= 100 || i === 0 ? Math.round(value) : value.toFixed(1)} ${units[i]}`;
}

export function percent(value: number | null | undefined, digits = 0): string {
  return value === null || value === undefined || !Number.isFinite(value) ? "—" : `${value.toFixed(digits)}%`;
}

export function fraction(value: number | null | undefined): string {
  return value === null || value === undefined ? "—" : percent(value * 100);
}

export function duration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const days = Math.floor(s / 86400);
  const hours = Math.floor((s % 86400) / 3600);
  const minutes = Math.floor((s % 3600) / 60);
  if (days > 0) return `${days} day${days === 1 ? "" : "s"}, ${hours} h`;
  if (hours > 0) return `${hours} h ${minutes} min`;
  if (minutes > 0) return `${minutes} min`;
  return `${s} s`;
}

export function ago(unixSeconds: number | null | undefined, now: number): string {
  if (!unixSeconds) return "never";
  const d = Math.max(0, now - unixSeconds);
  if (d < 5) return "just now";
  if (d < 60) return `${Math.floor(d)} s ago`;
  if (d < 3600) return `${Math.floor(d / 60)} min ago`;
  if (d < 86400) return `${Math.floor(d / 3600)} h ago`;
  return new Date(unixSeconds * 1000).toLocaleString();
}

/** The server's own wall clock: its time at the poll plus what has passed since, in its UTC offset. */
export function serverClock(serverTime: number, offsetSeconds: number, polledAt: number, now: number): string {
  const t = new Date((serverTime + (now - polledAt) + offsetSeconds) * 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${t.getUTCFullYear()}-${pad(t.getUTCMonth() + 1)}-${pad(t.getUTCDate())} ${pad(t.getUTCHours())}:${pad(t.getUTCMinutes())}:${pad(t.getUTCSeconds())}`;
}

export function destination(s: { user?: string; host: string; port?: number }): string {
  return `${s.user ? `${s.user}@` : ""}${s.host}${s.port && s.port !== 22 ? `:${s.port}` : ""}`;
}
