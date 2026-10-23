import { api } from "../api";
import { Heartbeat, Sparkline } from "../components/charts";
import { SiteIcon, stackRoute } from "../components/docker";
import { Card, Empty, Meter, Notice, Spinner, StatusDot } from "../components/ui";
import { useApp } from "../context";
import { ago, bytes, fraction, percent } from "../format";
import { useNow, usePoll } from "../hooks";
import type { FleetDocker, FleetRow } from "../types";
import { AlertsView } from "./Alerts";
import { BookmarkRow, groupsOf } from "./Bookmarks";

const PAGES: [string, string][] = [["health", "Health"], ["servers", "Servers"], ["docker", "Docker"], ["bookmarks", "Bookmarks"],
  ["alerts", "Alerts"]];

/** Every answering server's Docker (the backend skips unanswering and untrusted ones), polled while this page shows. */
function useFleetDocker() {
  return usePoll(() => api.get<FleetDocker>("/api/fleet/docker?watch=true"), 8000, []);
}

function DockerPage() {
  const { data, error } = useFleetDocker();
  if (!data) return error ? <Notice tone="danger">{error}</Notice> : <Spinner />;
  if (data.servers.length === 0) return <Empty title="No server is answering right now" />;
  const all = data.servers.flatMap((s) => s.stacks.flatMap((st) => st.containers));
  return (
    <>
      <div className="totals">
        <div className="total"><span className="total-label">Containers</span><span className="total-value">{all.filter((c) => c.isRunning).length} of {all.length} running</span></div>
        <div className="total"><span className="total-label">Unhealthy</span><span className="total-value">{all.filter((c) => c.isUnhealthy).length}</span></div>
      </div>
      {data.servers.map((srv) => (
        <Card key={srv.server.id} title={srv.server.name} actions={
          <span className="dim">{srv.summary ?? srv.error ?? ""}{srv.totals ? ` · CPU ${percent(srv.totals.cpuPercentOfHost, 1)} · ${bytes(srv.totals.memoryBytes)}` : ""}
            {srv.totals?.dataDisk ? ` · ${srv.totals.dataDisk.mount} ${srv.totals.dataDisk.usePercent}%` : ""}</span>}>
          <div className="stack-grid compact">
            {srv.stacks.map((st) => (
              <a key={st.id} className="stack-mini" href={`#${stackRoute(srv.server.id, st.id)}`}>
                <SiteIcon href={st.containers.find((c) => c.bookmark)?.bookmark?.href ?? st.link} letter={st.letter} hue={st.hue} size={28} />
                <span className="stack-mini-text">
                  <strong>{st.name}</strong>
                  <span className="dim">{st.statusText || `${st.running}/${st.total} running`} · {bytes(st.memoryBytes)}</span>
                </span>
                <span className={`dot dot-${{ ok: "ok", warning: "warn", danger: "danger", idle: "idle" }[st.severity]}`} />
              </a>
            ))}
          </div>
        </Card>
      ))}
    </>
  );
}

function BookmarksPage() {
  const { data, error } = useFleetDocker();
  if (!data) return error ? <Notice tone="danger">{error}</Notice> : <Spinner />;
  const withMarks = data.servers.filter((s) => s.bookmarks.length > 0);
  if (withMarks.length === 0) return <Empty title="No bookmarks on any answering server" />;
  return (
    <>
      {withMarks.map((srv) => (
        <Card key={srv.server.id} title={srv.server.name}
              actions={<a href={`#/servers/${srv.server.id}/bookmarks`}>Edit bookmarks</a>}>
          <div className="bookmark-columns">
            {groupsOf(srv.bookmarks).map(([group, list]) => (
              <div key={group}>
                <h3>{group}</h3>
                <ul className="bookmarks">{list.map((item) => <BookmarkRow key={item.containerId} item={item} />)}</ul>
              </div>
            ))}
          </div>
        </Card>
      ))}
    </>
  );
}

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

export function DashboardScreen(props: { page?: string }) {
  const page = PAGES.some(([k]) => k === props.page) ? props.page! : "health";
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
      <nav className="tabs" aria-label="Dashboard pages">
        {PAGES.map(([key, label]) => (
          <a key={key} href={`#/dashboard/${key}`} className={`tab${page === key ? " active" : ""}`}
             aria-current={page === key ? "page" : undefined}>{label}</a>
        ))}
      </nav>
      {page === "docker" && <DockerPage />}
      {page === "bookmarks" && <BookmarksPage />}
      {page === "alerts" && <AlertsView />}
      {(page === "health" || page === "servers") && <Totals />}
      {page === "health" && <Card title="Health">
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
      </Card>}
      {page === "servers" && <div className="server-tiles">
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
      </div>}
    </div>
  );
}
