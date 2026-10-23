// Search everything on every server (Spotlight-style): two letters or more; ↑↓, Return, Esc. The backend searches what
// it already holds; nothing is fetched for a search.
import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { useApp } from "../context";
import type { SearchItem } from "../types";
import { stackRoute } from "./docker";

interface Section { group: string; title: string; items: SearchItem[] }

export function routeOf(item: SearchItem, selected: string | undefined): string | null {
  const t = item.target;
  switch (t.kind) {
    case "server": return `/servers/${t.server}`;
    case "stack": return stackRoute(t.server, t.id);
    case "service": return `/servers/${t.server}/services/${encodeURIComponent(item.title)}`;
    case "bookmark": return `/servers/${t.server}/bookmarks`;
    case "command": return selected ? `/servers/${selected}/commands/${t.id}` : null;
    case "alert": return `/servers/${t.server}/alerts`;
  }
}

export function SearchPanel(props: { selected?: string; onClose: () => void }) {
  const app = useApp();
  const [query, setQuery] = useState("");
  const [sections, setSections] = useState<Section[]>([]);
  const [expanded, setExpanded] = useState<string>();
  const [cursor, setCursor] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => input.current?.focus(), []);
  useEffect(() => {
    let current = true;
    const q = query.trim();
    if (q.length < 2) {
      setSections([]);
      return;
    }
    const timer = window.setTimeout(() => {
      void api.get<{ sections: Section[] }>(`/api/search?q=${encodeURIComponent(q)}`)
        .then((r) => { if (current) { setSections(r.sections); setCursor(0); } });
    }, 150);
    return () => { current = false; window.clearTimeout(timer); };
  }, [query]);
  const visible = sections.map((s) => ({ ...s, items: expanded === s.group ? s.items : s.items.slice(0, 5) }));
  const flat = visible.flatMap((s) => s.items);
  const open = (item: SearchItem) => {
    if (item.target.kind === "bookmark" && item.link) window.open(item.link, "_blank", "noopener,noreferrer");
    const to = routeOf(item, props.selected);
    if (to) app.go(to);
    props.onClose();
  };
  return (
    <div className="switcher-scrim search-scrim" onMouseDown={(e) => e.target === e.currentTarget && props.onClose()}>
      <div className="search" role="dialog" aria-label="Search">
        <input ref={input} type="search" value={query} placeholder="Search servers, stacks, services, bookmarks, commands, alerts"
               aria-label="Search" onChange={(e) => setQuery(e.target.value)}
               onKeyDown={(e) => {
                 if (e.key === "Escape") props.onClose();
                 if (e.key === "ArrowDown") { e.preventDefault(); setCursor((c) => Math.min(flat.length - 1, c + 1)); }
                 if (e.key === "ArrowUp") { e.preventDefault(); setCursor((c) => Math.max(0, c - 1)); }
                 if (e.key === "Enter" && flat[cursor]) open(flat[cursor]!);
               }} />
        <div className="search-results">
          {query.trim().length >= 2 && sections.length === 0 && <p className="dim">Nothing found.</p>}
          {visible.map((s) => (
            <section key={s.group}>
              <h3>{s.title}</h3>
              <ul>
                {s.items.map((item) => {
                  const i = flat.indexOf(item);
                  return (
                    <li key={item.id}>
                      <button type="button" className={`search-row${i === cursor ? " selected" : ""}`}
                              onMouseEnter={() => setCursor(i)} onClick={() => open(item)}>
                        <span className={`dot dot-${item.tone === "danger" ? "danger" : item.tone === "warn" ? "warn" : item.tone === "ok" ? "ok" : "idle"}`} />
                        <span className="search-text">
                          <strong>{item.title}</strong>
                          <span className="dim">{item.subtitle}{item.serverName && ` · ${item.serverName}`}</span>
                        </span>
                      </button>
                    </li>
                  );
                })}
              </ul>
              {sections.find((x) => x.group === s.group)!.items.length > 5 && expanded !== s.group && (
                <button type="button" className="link" onClick={() => setExpanded(s.group)}>
                  Show all {sections.find((x) => x.group === s.group)!.items.length}
                </button>
              )}
            </section>
          ))}
        </div>
      </div>
    </div>
  );
}
