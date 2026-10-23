// Commands: the library (spec/command-library.json) and a free-form box. Read entries run on one click; changes show
// their dry run and ask first; root entries ask for the sudo password when sudo wants one; interactive ones open a
// terminal tab. Each entry keeps its own last output (the latest run of its scope). Typed commands are remembered for
// this page only, in memory: a typed command can hold a password or token.
import { useEffect, useMemo, useState } from "react";
import { api } from "../api";
import { useRootAction } from "../components/root";
import { Button, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import type { DockerState, LibraryCommand, Run, Server } from "../types";
import { OutputPanel } from "./DockerPanels";

const history: string[] = []; // module memory: survives switching screens, gone on reload

export function CommandsScreen(props: { server: Server; select?: string }) {
  const app = useApp();
  const [library, setLibrary] = useState<{ groups: string[]; commands: LibraryCommand[] }>();
  const [selected, setSelected] = useState<string | undefined>(props.select);
  const [params, setParams] = useState<Record<string, string>>({});
  const [runs, setRuns] = useState<Record<string, Run>>({});
  const [custom, setCustom] = useState("");
  const [query, setQuery] = useState("");
  const [containers, setContainers] = useState<string[]>([]);
  const [showFull, setShowFull] = useState(false);
  useEffect(() => {
    void api.get<{ groups: string[]; commands: LibraryCommand[] }>("/api/commands").then((l) => {
      setLibrary(l);
      setSelected((s) => s ?? l.commands[0]?.id);
    });
    void api.get<Run[]>(`/api/servers/${props.server.id}/runs`).then((rs) => {
      const latest: Record<string, Run> = {};
      for (const r of rs) if (r.scope.startsWith("command:")) latest[r.scope] = r;
      setRuns(latest);
    });
    void api.get<DockerState>(`/api/servers/${props.server.id}/docker`).then((d) =>
      setContainers(d.stacks.flatMap((s) => s.containers.map((c) => c.name)))).catch(() => undefined);
  }, [props.server.id]);
  useEffect(() => setParams({}), [selected]);
  const onRun = (run: Run) => setRuns((m) => ({ ...m, [run.scope]: run }));
  const action = useRootAction(props.server, onRun, () => app.go(`/servers/${props.server.id}/terminal`));
  const shown = useMemo(() => {
    const q = query.toLowerCase().trim();
    return (library?.commands ?? []).filter((c) => !q || `${c.title} ${c.summary} ${c.group}`.toLowerCase().includes(q));
  }, [library, query]);
  if (!library) return <div className="page"><Spinner /></div>;
  const readOnly = app.safety?.readOnly ?? true;
  const command = library.commands.find((c) => c.id === selected);
  const scope = selected === "custom" ? "command:custom" : `command:${selected}`;
  const run = runs[scope];
  const busy = Object.values(runs).some((r) => r.phase === "running");
  const missing = command?.params.some((p) => !params[p.id]?.trim()) ?? false;
  const runIt = () => command && void action.request(`/api/servers/${props.server.id}/commands/run`, { id: command.id, params });
  const runCustom = () => {
    const text = custom.trim();
    if (!text) return;
    if (!history.includes(text)) history.unshift(text);
    history.splice(20);
    setSelected("custom");
    void action.request(`/api/servers/${props.server.id}/commands/custom`, { text });
  };
  return (
    <div className="page page-wide">
      <header className="page-head">
        <div>
          <h1>Commands</h1>
          <p className="muted">Handy commands for {props.server.name}. Changes show a dry run and ask first.</p>
        </div>
      </header>
      {action.error && <Notice tone="danger">{action.error}</Notice>}
      <div className="commands">
        <aside className="command-list">
          <input type="search" placeholder="Filter commands" value={query} onChange={(e) => setQuery(e.target.value)}
                 aria-label="Filter commands" />
          {library.groups.map((g) => {
            const items = shown.filter((c) => c.group === g);
            if (!items.length) return null;
            return (
              <section key={g}>
                <h3>{g}</h3>
                <ul>
                  {items.map((c) => (
                    <li key={c.id}>
                      <button type="button" className={`command-item${c.id === selected ? " selected" : ""}`}
                              onClick={() => setSelected(c.id)}>
                        <span>{c.title}</span>
                        {c.risk === "mutate" && <span className="badge badge-warn">asks</span>}
                        {runs[`command:${c.id}`]?.phase === "running" && <Spinner />}
                      </button>
                    </li>
                  ))}
                </ul>
              </section>
            );
          })}
        </aside>
        <section className="command-detail">
          {selected === "custom" ? (
            <div className="card"><h3>Typed command</h3><p className="muted">Runs as typed, after you confirm it.</p></div>
          ) : command && (
            <div className="card">
              <div className="card-head">
                <h3>{command.title}</h3>
                <div className="card-actions">
                  {command.root && <span className="badge">sudo</span>}
                  {command.interactive && <span className="badge">terminal tab</span>}
                </div>
              </div>
              <p>{command.summary}</p>
              {command.warning && <Notice tone="warn">{command.warning}</Notice>}
              {command.params.map((p) => (
                <label key={p.id} className="field">
                  <span className="field-label">{p.label}</span>
                  <input list={p.kind === "container" ? "rk-containers" : undefined} value={params[p.id] ?? ""}
                         placeholder={p.placeholder} spellCheck={false}
                         onChange={(e) => setParams({ ...params, [p.id]: e.target.value })} />
                </label>
              ))}
              <datalist id="rk-containers">{containers.map((c) => <option key={c} value={c} />)}</datalist>
              <p className="muted">Runs:</p>
              <pre className="command">{command.readable}</pre>
              {command.readablePreview && <><p className="muted">Dry run first:</p><pre className="command">{command.readablePreview}</pre></>}
              {command.full && (
                <button type="button" className="link" onClick={() => setShowFull(!showFull)}>
                  {showFull ? "Hide" : "Show"} the exact script
                </button>
              )}
              {showFull && command.full && <pre className="command">{command.full}</pre>}
              <div className="form-actions">
                <Button kind="primary" disabled={busy || missing || ((command.risk === "mutate" || command.interactive) && readOnly)}
                        title={readOnly && command.risk === "mutate" ? "Read-only mode is on" : undefined}
                        onClick={runIt}>
                  {command.interactive ? "Open in Terminal" : command.risk === "mutate" ? "Run…" : "Run"}
                </Button>
              </div>
            </div>
          )}
          {run && (
            <section className="stack-panel command-output">
              <OutputPanel key={run.id} run={run} onChanged={(r) => { onRun(r); action.runEnded(r); }}
                           onClose={() => setRuns((m) => { const n = { ...m }; delete n[scope]; return n; })} />
            </section>
          )}
          <div className="card">
            <h3>Run your own</h3>
            <form className="custom-command" onSubmit={(e) => { e.preventDefault(); runCustom(); }}>
              <input value={custom} onChange={(e) => setCustom(e.target.value)} placeholder="journalctl -u nginx -n 50"
                     spellCheck={false} list="rk-history" aria-label="Command" disabled={readOnly} />
              <datalist id="rk-history">{history.map((h) => <option key={h} value={h} />)}</datalist>
              <Button kind="primary" type="submit" disabled={readOnly || busy || !custom.trim()}
                      title={readOnly ? "Read-only mode is on" : undefined}>Run…</Button>
            </form>
            <p className="dim">It can't be checked, so it always asks first. Remembered on this page only, never saved.</p>
          </div>
        </section>
      </div>
      {action.sheets}
    </div>
  );
}
