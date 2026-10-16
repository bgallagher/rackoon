import { Heartbeat, Sparkline } from "../components/charts";
import { Card, Empty, Meter, StatusDot } from "../components/ui";
import { useApp } from "../context";
import { ago, bytes, fraction, percent } from "../format";
import { useNow } from "../hooks";
import type { FleetRow } from "../types";

function statusText(row: FleetRow, now: number): string {
  switch (row.connection) {
    case "ok":
      return `Answering · ${ago(row.updatedAt, now)}`;
    case "connecting":
      return row.isStale ? `Last seen ${ago(row.updatedAt, now)}` : "Connecting…";
    case "hostKeyUnknown":
      return "Host key not trusted yet";
    case "hostKeyChanged":
      return "Host key changed: blocked";
    case "authFailed":
      return "Login refused";
    default:
      return "Not answering";
  }
}

function Totals() {
  const { fleet } = useApp();
  if (!fleet) return null;
  const t = fleet.totals;
  const items: [string, string, string?][] = [
    ["Servers online", `${t.online} of ${t.servers}`],
    ["CPU", percent(t.cpuPercent), "weighted by cores"],
    ["Memory", t.memoryTotal ? `${bytes(t.memoryUsed)} of ${bytes(t.memoryTotal)}` : "—"],
    ["Disk", t.diskTotal ? `${bytes(t.diskUsed)} of ${bytes(t.diskTotal)}` : "—"],
    ["Updates", `${t.updates}${t.securityUpdates ? ` (${t.securityUpdates} security)` : ""}`],
    ["Reboot required", String(t.rebootRequired)],
    ["Unhealthy containers", String(t.unhealthyContainers)],
  ];
  return (
    <div className="totals">
      {items.map(([k, v, hint]) => (
        <div key={k} className="total" title={hint}>
          <span className="total-label">{k}</span>
          <span className="total-value">{v}</span>
        </div>
      ))}
    </div>
  );
}

export function DashboardScreen() {
  const app = useApp();
  const now = useNow();
  const rows = app.fleet?.servers ?? [];
  if (app.servers.length === 0) {
    return (
      <div className="page">
        <Empty title="No servers yet">
          <p>Add one by address, or import your ~/.ssh/config.</p>
          <a className="btn btn-primary" href="#/settings/servers/new">Add a Server</a>
        </Empty>
      </div>
    );
  }
  return (
    <div className="page">
      <header className="page-head"><h1>Dashboard</h1></header>
      <Totals />
      <Card title="Health">
        <div className="health-wrap">
        <table className="health">
          <thead>
            <tr><th>Server</th><th>Last hour</th><th>Uptime</th><th>CPU</th><th>Memory</th><th>Fullest disk</th></tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>
                  <a href={`#/servers/${r.id}`} className="health-name">
                    <StatusDot connection={r.connection} title={statusText(r, now)} /> {r.name}
                  </a>
                  <div className="dim">{statusText(r, now)}</div>
                </td>
                <td><Heartbeat samples={r.history} /></td>
                <td>{fraction(r.uptimeFraction)}</td>
                <td><Sparkline label={`${r.name} CPU`} values={r.history.map((h) => h.cpuPercent)} /></td>
                <td><Sparkline label={`${r.name} memory`} tone="series1"
                               values={r.history.map((h) => (h.memoryFraction === undefined ? undefined : h.memoryFraction * 100))} /></td>
                <td>{r.derived?.fullestDisk ? `${r.derived.fullestDisk.mount} ${r.derived.fullestDisk.usePercent}%` : "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
        </div>
      </Card>
      <div className="server-tiles">
        {rows.map((r) => {
          const o = r.overview;
          return (
            <a key={r.id} className="server-tile" href={`#/servers/${r.id}`}>
              <div className="server-tile-head">
                <StatusDot connection={r.connection} />
                <strong>{r.name}</strong>
                {r.attentionCount > 0 && (
                  <span className={`badge ${r.redCount ? "badge-danger" : "badge-warn"}`}>{r.attentionCount}</span>
                )}
              </div>
              <div className="dim">{o ? o.os.prettyName : r.host}</div>
              {o && (
                <dl className="tile-meters">
                  <div><dt>CPU</dt><dd><Meter value={r.cpuPercent == null ? null : r.cpuPercent / 100} label="CPU" />{percent(r.cpuPercent)}</dd></div>
                  <div><dt>RAM</dt><dd><Meter value={r.derived?.memoryUsedFraction} label="Memory" />{fraction(r.derived?.memoryUsedFraction)}</dd></div>
                  <div><dt>Disk</dt><dd><Meter value={(r.derived?.fullestDisk?.usePercent ?? 0) / 100} label="Disk" />{r.derived?.fullestDisk?.usePercent ?? "—"}%</dd></div>
                </dl>
              )}
              {o && (
                <div className="tile-foot dim">
                  {o.tailscaleIP ?? o.ipAddress ?? ""}
                  {o.pendingUpdates > 0 && <span className="badge badge-warn">{o.pendingUpdates} updates</span>}
                  {o.rebootRequired && <span className="badge badge-warn">Reboot</span>}
                </div>
              )}
            </a>
          );
        })}
      </div>
    </div>
  );
}
