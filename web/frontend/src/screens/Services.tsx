// Services: what runs outside Docker (systemd units, your own user units, processes started by hand), from one
// read-only scan, at most every 25 s while this page shows. OS plumbing is hidden by default; failed or crash-looping
// ones always show. Actions run like Commands entries (status first, then the sheet; sudo asks when it must).
import { useEffect, useMemo, useState } from "react";
import { api } from "../api";
import { Menu, type MenuItem } from "../components/docker";
import { useRootAction } from "../components/root";
import { Button, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import { ago, bytes, duration } from "../format";
import { useNow, usePoll } from "../hooks";
import type { Run, Server, Service, ServicesState } from "../types";
import { OutputPanel } from "./DockerPanels";

const TITLES: Record<string, string> = { start: "Start…", stop: "Stop…", restart: "Restart…", status: "Status",
  logs: "Recent Logs" };

function tone(s: Service): string {
  if (s.isProblem) return "danger";
  if (s.status === "running") return "ok";
  if (s.status === "starting" || s.status === "stopping") return "warn";
  return "idle";
}

export function ServicesScreen(props: { server: Server; focus?: string }) {
  const app = useApp();
  const now = useNow();
  const base = `/api/servers/${props.server.id}`;
  const { data, error, reload } = usePoll(() => api.get<ServicesState>(`${base}/services`), 25_000, [props.server.id]);
  const [query, setQuery] = useState(props.focus ?? "");
  const [showHidden, setShowHidden] = useState(false);
  const [run, setRun] = useState<Run | null>(null);
  const action = useRootAction(props.server, (r) => setRun(r), () => app.go(`${base.replace("/api", "")}/terminal`));
  useEffect(() => setQuery(props.focus ?? ""), [props.focus]);
  const shown = useMemo(() => {
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    return (data?.services ?? []).filter((s) => (showHidden || s.visible || s.isProblem) && words.every((w) =>
      [s.name, s.unit ?? "", s.product ?? "", s.detail, s.path ?? "", ...s.ports.map((p) => String(p.port))]
        .join(" ").toLowerCase().includes(w)));
  }, [data, query, showHidden]);
  if (!data) return <div className="page">{error ? <Notice tone="danger">{error}</Notice> : <Spinner />}</div>;
  const readOnly = app.safety?.readOnly ?? true;
  const hidden = data.services.filter((s) => !s.visible).length;
  const setVisible = async (s: Service, visible: boolean | null, everywhere = false) => {
    await api.put("/api/services/visibility", { serverId: props.server.id, serviceId: s.id, visible, everywhere });
    await reload();
  };
  const act = (s: Service, a: string) => void action.request(`${base}/services/action`, { serviceId: s.id, action: a });
  return (
    <div className="page">
      <header className="page-head">
        <div>
          <h1>Services</h1>
          <p className="muted">What runs on {props.server.name} outside Docker · scanned {ago(data.updatedAt, now)}
            {data.isRoot === false && " · ports of other users' processes show without a process name"}</p>
        </div>
        <Button onClick={() => void api.get(`${base}/services?refresh=true`).then(reload)}>Scan Again</Button>
      </header>
      {data.error && <Notice tone="danger" title="The scan failed"><p className="raw">{data.error}</p></Notice>}
      {action.error && <Notice tone="danger">{action.error}</Notice>}
      {data.hasSystemd === false && <Notice tone="info">This server has no systemd, so only listening processes show.</Notice>}
      <div className="filters">
        <input type="search" placeholder="Search services, units, ports" value={query} onChange={(e) => setQuery(e.target.value)}
               aria-label="Search services" />
        <label className="toggle">
          <input type="checkbox" checked={showHidden} onChange={(e) => setShowHidden(e.target.checked)} />
          Show {hidden} hidden
        </label>
      </div>
      {run && (
        <section className="stack-panel command-output">
          <OutputPanel key={run.id} run={run} onChanged={(r) => { setRun(r); action.runEnded(r); if (r.phase !== "running") void reload(); }}
                       onClose={() => setRun(null)} />
        </section>
      )}
      <ul className="service-list">
        {shown.map((s) => {
          const items: (MenuItem | null)[] = [
            ...s.actions.map((a): MenuItem => ({
              label: TITLES[a] ?? a, onClick: () => act(s, a),
              disabled: ["start", "stop", "restart"].includes(a) && readOnly, reason: "Read-only mode is on",
            })),
            s.canFollow ? { label: "Follow Logs in Terminal", onClick: () => void api.post(`${base}/services/follow`, { serviceId: s.id })
              .then(() => app.go(`/servers/${props.server.id}/terminal`)), disabled: readOnly, reason: "Read-only mode is on" } : null,
            null,
            s.visible
              ? { label: "Hide on this server", onClick: () => void setVisible(s, false) }
              : { label: "Show on this server", onClick: () => void setVisible(s, true) },
            { label: s.visible ? "Hide on every server" : "Show on every server", onClick: () => void setVisible(s, !s.visible, true) },
            s.chosen ? { label: "Back to the default", onClick: () => void setVisible(s, null, true) } : null,
          ];
          return (
            <li key={s.id} className={`service-row${s.visible ? "" : " hidden"}`}>
              <span className={`dot dot-${tone(s)}`} title={s.status} />
              <div className="service-text">
                <strong>{s.name}</strong>
                <span className="dim">
                  {s.kind === "process" ? "Started by hand" : s.kind === "user" ? "Your service" : "System service"}
                  {" · "}{s.status === "restarting" ? `crash loop (${s.restarts} restarts)` : s.status}
                  {s.unit && <> · <span className="mono">{s.unit}</span></>}
                  {s.activeSeconds != null && s.status === "running" && <> · up {duration(s.activeSeconds)}</>}
                  {s.memoryBytes != null && <> · {bytes(s.memoryBytes)}</>}
                </span>
                {s.detail && <span className="dim">{s.detail}</span>}
              </div>
              <div className="service-ports">
                {s.ports.map((p) => {
                  const link = s.links.find((l) => l.endsWith(`:${p.port}`));
                  return link ? <a key={`${p.address}:${p.port}`} className="badge" href={link} target="_blank" rel="noreferrer noopener">:{p.port}</a>
                              : <span key={`${p.address}:${p.port}`} className="badge" title={p.address}>:{p.port}</span>;
                })}
              </div>
              {items.some((i) => i) && <Menu small label="⋯" title={`Actions for ${s.name}`} items={items} />}
            </li>
          );
        })}
      </ul>
      {shown.length === 0 && <p className="dim">Nothing matches.</p>}
      {action.sheets}
    </div>
  );
}
