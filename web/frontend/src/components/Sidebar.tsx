import { useEffect, useRef, useState } from "react";
import { api, ApiError } from "../api";
import { useApp } from "../context";
import { destination } from "../format";
import type { Connection, Safety, Server } from "../types";
import { StatusDot } from "./ui";

function connectionOf(id: string, rows: { id: string; connection: Connection; isStale: boolean }[] | undefined) {
  const row = rows?.find((r) => r.id === id);
  if (!row) return "connecting" as const;
  return row.isStale && row.connection === "connecting" ? ("stale" as const) : row.connection;
}

/** The server menu: filter, pick, reorder (drag or ↑↓), add. Filtering is done by the backend's ServerList. */
function ServerSwitcher(props: { selected?: string; onClose: () => void }) {
  const app = useApp();
  const [query, setQuery] = useState("");
  const [shown, setShown] = useState<Server[]>(app.servers);
  const [dragging, setDragging] = useState<string>();
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => input.current?.focus(), []);
  useEffect(() => {
    let current = true;
    if (!query.trim()) {
      setShown(app.servers);
      return;
    }
    void api.get<Server[]>(`/api/servers?query=${encodeURIComponent(query)}`).then((r) => current && setShown(r));
    return () => {
      current = false;
    };
  }, [query, app.servers]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && props.onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [props]);
  const move = async (id: string, body: { onto?: string; by?: number }) => {
    try {
      await api.post(`/api/servers/${id}/move`, body);
      await app.reloadServers();
    } catch (e) {
      if (!(e instanceof ApiError)) throw e;
    }
  };
  const searching = query.trim() !== "";
  return (
    <div className="switcher-scrim" onMouseDown={(e) => e.target === e.currentTarget && props.onClose()}>
      <div className="switcher" role="dialog" aria-label="Servers">
        <ul className="switcher-list" role="listbox">
          {shown.map((s) => (
            <li key={s.id} role="option" aria-selected={s.id === props.selected}
                className={`switcher-row${s.id === props.selected ? " selected" : ""}${dragging === s.id ? " dragging" : ""}`}
                draggable={!searching}
                onDragStart={() => setDragging(s.id)}
                onDragEnd={() => setDragging(undefined)}
                onDragOver={(e) => e.preventDefault()}
                onDrop={() => dragging && dragging !== s.id && void move(dragging, { onto: s.id })}>
              <button type="button" className="switcher-pick" onClick={() => { app.go(`/servers/${s.id}`); props.onClose(); }}>
                <StatusDot connection={connectionOf(s.id, app.fleet?.servers)} />
                <span className="switcher-name">{s.name}</span>
                <span className="switcher-dest">{destination(s)}</span>
              </button>
              {!searching && (
                <span className="switcher-move">
                  <button type="button" title={`Move ${s.name} up`} onClick={() => void move(s.id, { by: -1 })}>↑</button>
                  <button type="button" title={`Move ${s.name} down`} onClick={() => void move(s.id, { by: 1 })}>↓</button>
                </span>
              )}
            </li>
          ))}
          {shown.length === 0 && <li className="switcher-none">No server matches “{query}”.</li>}
        </ul>
        <div className="switcher-footer">
          <input ref={input} type="search" placeholder="Filter servers" value={query} onChange={(e) => setQuery(e.target.value)}
                 aria-label="Filter servers" />
          <button type="button" className="btn btn-plain btn-small" title="Add a server"
                  onClick={() => { app.go("/settings/servers/new"); props.onClose(); }}>+ Add</button>
        </div>
      </div>
    </div>
  );
}

function ReadOnlySwitch() {
  const app = useApp();
  const safety = app.safety;
  if (!safety) return null;
  const toggle = async () => {
    app.setSafety(await api.put<Safety>("/api/safety", { readOnly: !safety.readOnly }));
  };
  const auto = safety.options.find((o) => o.key === safety.auto);
  return (
    <button type="button" className={`readonly ${safety.readOnly ? "on" : "off"}`} onClick={() => void toggle()}
            role="switch" aria-checked={safety.readOnly}
            title={safety.readOnly ? "Nothing that changes a server can run. Click to allow changes."
                                   : `Changes are allowed. Read-only comes back ${auto?.label.toLowerCase() ?? ""}.`}>
      <span className="readonly-knob" />
      <span>{safety.readOnly ? "Read-only" : "Changes allowed"}</span>
    </button>
  );
}

export function Sidebar(props: { route: string; selected?: string }) {
  const app = useApp();
  const [open, setOpen] = useState(false);
  const server = app.servers.find((s) => s.id === props.selected) ?? app.servers[0];
  const down = app.fleet?.servers.filter((r) => r.connection !== "ok" && r.connection !== "connecting").length ?? 0;
  const nav = (to: string, label: string, active: boolean) => (
    <a href={`#${to}`} className={`nav${active ? " active" : ""}`} aria-current={active ? "page" : undefined}>{label}</a>
  );
  return (
    <aside className="sidebar">
      <div className="brand">
        <img src="/rackoon-icon.svg" alt="" width="22" height="22" />
        <span>Rackoon</span>
        {app.auth.demo && <span className="badge">Demo</span>}
      </div>
      {nav("/dashboard", "Dashboard", props.route.startsWith("/dashboard"))}
      <div className="sidebar-heading">
        <span>Servers</span>
        <span className="muted">{down > 0 ? <span className="down">{down} down</span> : app.servers.length}</span>
      </div>
      {server ? (
        <button type="button" className="server-card" onClick={() => setOpen(true)} aria-haspopup="dialog"
                title="Switch server">
          <StatusDot connection={connectionOf(server.id, app.fleet?.servers)} />
          <span className="server-card-text">
            <span className="server-card-name">{server.name}</span>
            <span className="server-card-dest">{destination(server)}</span>
          </span>
          <span className="chevron">⌄</span>
        </button>
      ) : (
        <a className="nav" href="#/settings/servers/new">+ Add a server</a>
      )}
      {server && nav(`/servers/${server.id}`, "Overview", props.route.startsWith(`/servers/${server.id}`))}
      <div className="sidebar-spacer" />
      {nav("/settings/servers", "Settings", props.route.startsWith("/settings"))}
      <ReadOnlySwitch />
      <div className="signed-in muted">
        {app.auth.user}
        {app.auth.via === "session" && (
          <button type="button" className="link" onClick={() => void app.signOut()}>Sign out</button>
        )}
      </div>
      {open && <ServerSwitcher selected={server?.id} onClose={() => setOpen(false)} />}
    </aside>
  );
}
