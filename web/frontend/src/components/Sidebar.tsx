import { useEffect, useRef, useState } from "react";
import { api, ApiError } from "../api";
import { useApp } from "../context";
import { destination } from "../format";
import { usePoll } from "../hooks";
import type { AlertSummary, Connection, Safety, Server } from "../types";
import { SearchPanel } from "./SearchPanel";
import { StatusDot } from "./ui";

function connectionOf(id: string, rows: { id: string; connection: Connection; isStale: boolean }[] | undefined) {
  const row = rows?.find((r) => r.id === id);
  if (!row) return "connecting" as const;
  return row.isStale && row.connection === "connecting" ? ("stale" as const) : row.connection;
}

/** Unraid has no apt, so the Updates screen is hidden for it (like the Mac). */
function isUnraid(id: string, rows: { id: string; overview: { os: { id: string } } | null }[] | undefined): boolean {
  return rows?.find((r) => r.id === id)?.overview?.os.id === "unraid-os";
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
  const [searching, setSearching] = useState(false);
  const { data: summary } = usePoll(() => api.get<AlertSummary>("/api/alerts/summary"), 20_000, []);
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      const typing = e.target instanceof HTMLElement && e.target.closest("input, textarea, [contenteditable], .xterm");
      if (e.key === "/" && !typing) { e.preventDefault(); setSearching(true); }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); setSearching(true); }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, []);
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
      <button type="button" className="search-box" onClick={() => setSearching(true)} title="Search everything (/)">
        Search…
      </button>
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
      {server && nav(`/servers/${server.id}`, "Overview", props.route === `/servers/${server.id}`)}
      {server && nav(`/servers/${server.id}/terminal`, "Terminal", props.route.startsWith(`/servers/${server.id}/terminal`))}
      {server && !isUnraid(server.id, app.fleet?.servers) && nav(`/servers/${server.id}/updates`, "Updates",
                                                                  props.route.startsWith(`/servers/${server.id}/updates`))}
      {server && nav(`/servers/${server.id}/docker`, "Docker", props.route.startsWith(`/servers/${server.id}/docker`))}
      {server && nav(`/servers/${server.id}/bookmarks`, "Bookmarks", props.route.startsWith(`/servers/${server.id}/bookmarks`))}
      {server && nav(`/servers/${server.id}/services`, "Services", props.route.startsWith(`/servers/${server.id}/services`))}
      {server && nav(`/servers/${server.id}/commands`, "Commands", props.route.startsWith(`/servers/${server.id}/commands`))}
      {server && nav(`/servers/${server.id}/files`, "Files", props.route.startsWith(`/servers/${server.id}/files`))}
      {server && (
        <a href={`#/servers/${server.id}/alerts`} className={`nav${props.route.startsWith(`/servers/${server.id}/alerts`) ? " active" : ""}`}>
          Alerts {(summary?.servers[server.id]?.unseen ?? 0) > 0 && (
            <span className={`badge ${summary?.servers[server.id]?.worst === "critical" ? "badge-danger" : "badge-warn"}`}>
              {summary?.servers[server.id]?.unseen}</span>)}
        </a>
      )}
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
      {searching && <SearchPanel selected={server?.id} onClose={() => setSearching(false)} />}
    </aside>
  );
}
