// The Docker section: the overview grid of stacks, and a stack's page (one Stack Actions menu, the container list,
// and the Logs / Output / file tabs). Polled every few seconds while showing; the backend polls docker only then.
import { useEffect, useMemo, useState } from "react";
import { api } from "../api";
import { BookmarkSheet, DeleteSheet, DockerProblem, useDockerSudo, errorText, LetterTile, Menu, SiteIcon, stackRoute, useAction, type MenuItem } from "../components/docker";
import { Button, Card, Empty, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import { ago, bytes, fraction, percent } from "../format";
import { useNow, usePoll } from "../hooks";
import type { ActionResult, Container, DockerState, Run, Server, Stack, StackPage } from "../types";
import { EditorPanel, LogsPanel, OutputPanel, type Draft } from "./DockerPanels";

function usage(c: Container): string {
  if (!c.isRunning) return c.state;
  if (c.cpuPercent == null || c.memoryUsedBytes == null) return "—";
  return `${Math.round(c.cpuPercent)}% · ${bytes(c.memoryUsedBytes)}`;
}

function StackTile(props: { server: Server; stack: Stack; onBookmark: () => void }) {
  const s = props.stack;
  const icon = s.containers.find((c) => c.bookmark)?.bookmark?.href ?? s.link;
  const tone = { ok: "ok", warning: "warn", danger: "danger", idle: "idle" }[s.severity];
  return (
    <div className="stack-tile">
      <a className="stack-tile-main" href={`#${stackRoute(props.server.id, s.id)}`}>
        <div className="stack-tile-head">
          <SiteIcon href={icon} letter={s.letter} hue={s.hue} size={38} />
          <div className="stack-tile-name">
            <strong>{s.name}</strong>
            <span className="dim">{s.kind}</span>
          </div>
        </div>
        <div className="stack-tile-status">
          <span className={`dot dot-${tone}`} />
          <span>{s.statusText || `${s.running} of ${s.total} running`}</span>
          {s.busy && <span className="badge">Working…</span>}
          {s.removing && <span className="badge badge-danger">Deleting…</span>}
        </div>
        <div className="dim stack-tile-images">{s.images.join(", ") || "No containers yet"}</div>
        <div className="stack-tile-foot dim">
          <span>{s.cpuPercent == null ? "—" : `${s.cpuPercent.toFixed(1)}%`} CPU</span>
          <span>{bytes(s.memoryBytes)}</span>
        </div>
      </a>
      <div className="stack-tile-actions">
        {s.link && <a className="btn btn-plain btn-small" href={s.link} target="_blank" rel="noreferrer noopener"
                      title={`Open ${s.link}`}>:{s.mainWebPort}</a>}
        {!s.isStandalone && (
          <button type="button" className={`icon-btn${s.hasBookmark ? " on" : ""}`} onClick={props.onBookmark}
                  title={s.hasBookmark ? "Edit bookmark" : "Add a bookmark"} aria-label="Bookmark">
            {s.hasBookmark ? "★" : "☆"}
          </button>
        )}
      </div>
    </div>
  );
}

const CHIPS: [string, string][] = [["all", "All"], ["running", "Running"], ["attention", "Needs attention"], ["stopped", "Stopped"]];

export function DockerScreen(props: { server: Server }) {
  const app = useApp();
  const now = useNow();
  const base = `/api/servers/${props.server.id}/docker`;
  const { data, error, reload } = usePoll(() => api.get<DockerState>(`${base}?watch=true`), 5000, [props.server.id]);
  const sudo = useDockerSudo(props.server, data, reload);
  const [query, setQuery] = useState("");
  const [chip, setChip] = useState("all");
  const [bookmarking, setBookmarking] = useState<Stack>();
  const action = useAction(() => void reload());
  const shown = useMemo(() => {
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    return (data?.stacks ?? []).filter((s) => (chip === "all" || s.health === chip) && words.every((w) =>
      [s.name, s.workingDir ?? "", ...s.containers.flatMap((c) => [c.name, c.service ?? "", c.image])]
        .join(" ").toLowerCase().includes(w)));
  }, [data, query, chip]);
  if (!data) return <div className="page">{error ? <Notice tone="danger">{error}</Notice> : <Spinner />}</div>;
  const readOnly = app.safety?.readOnly ?? true;
  const t = data.totals;
  return (
    <div className="page">
      <header className="page-head">
        <div>
          <h1>Docker</h1>
          {sudo.chip}
          <p className="muted">{data.summary ?? "Reading Docker…"} · updated {ago(data.updatedAt, now)}</p>
        </div>
        <div className="card-actions">
          <Button onClick={() => void api.post(`${base}/refresh`).then(reload)}>Refresh</Button>
          <a className={`btn btn-primary${readOnly ? " disabled" : ""}`} aria-disabled={readOnly}
             title={readOnly ? "Read-only mode is on" : undefined}
             href={readOnly ? undefined : `#/servers/${props.server.id}/docker/add`}>Add Container</a>
        </div>
      </header>
      <DockerProblem state={data} server={props.server} onUnlock={sudo.unlock} />
      {action.error && <Notice tone="danger">{action.error}</Notice>}
      {t && (
        <div className="totals">
          <div className="total"><span className="total-label">Containers</span><span className="total-value">{t.running} of {t.containers} running</span></div>
          <div className="total"><span className="total-label">Unhealthy</span><span className="total-value">{t.unhealthy}</span></div>
          <div className="total" title="Container CPU as a share of the whole server"><span className="total-label">CPU</span><span className="total-value">{percent(t.cpuPercentOfHost, 1)}</span></div>
          <div className="total"><span className="total-label">Memory</span><span className="total-value">{bytes(t.memoryBytes)} {t.memoryFractionOfHost != null ? `(${fraction(t.memoryFractionOfHost)})` : ""}</span></div>
          {t.dataDisk && <div className="total" title="The disk holding /var/lib/docker"><span className="total-label">Docker disk {t.dataDisk.mount}</span><span className="total-value">{t.dataDisk.usePercent}% used</span></div>}
        </div>
      )}
      {data.stacks.length > 0 && (
        <div className="filters">
          <input type="search" placeholder="Search stacks, folders, containers, images" value={query}
                 onChange={(e) => setQuery(e.target.value)} aria-label="Search stacks" />
          <div className="chips" role="group" aria-label="Show">
            {CHIPS.map(([key, label]) => (
              <button key={key} type="button" className={`chip${chip === key ? " on" : ""}`} aria-pressed={chip === key}
                      onClick={() => setChip(key)}>{label}</button>
            ))}
          </div>
        </div>
      )}
      {data.status === "ready" && data.stacks.length === 0 && <Empty title="No containers on this server yet" />}
      <div className="stack-grid">
        {shown.map((s) => <StackTile key={s.id} server={props.server} stack={s} onBookmark={() => setBookmarking(s)} />)}
      </div>
      {bookmarking && (() => {
        const services = bookmarking.containers.filter((c) => c.service).map((c) => ({
          stackId: bookmarking.id, stackName: bookmarking.name, service: c.service!,
        }));
        const existing = bookmarking.containers.find((c) => c.bookmark);
        return (
          <BookmarkSheet title={existing ? `Bookmark for ${bookmarking.name}` : `Bookmark ${bookmarking.name}`}
                         initial={existing?.bookmark} services={services} readOnly={readOnly}
                         fixed={existing?.service ? { stackId: bookmarking.id, service: existing.service } : undefined}
                         onCancel={() => setBookmarking(undefined)}
                         onSubmit={(target, bookmark, apply) => {
                           setBookmarking(undefined);
                           void action.request(`${base}/bookmark`, { ...target, bookmark, apply });
                         }} />
        );
      })()}
      {action.sheet}
      {sudo.sheet}
    </div>
  );
}

// --- a stack's page -------------------------------------------------------------------------------------------------

type Tab = "logs" | "output" | string; // or a file path

export function StackScreen(props: { server: Server; stackId: string }) {
  const app = useApp();
  const base = `/api/servers/${props.server.id}/docker`;
  const { data, error, reload } = usePoll(
    () => api.get<StackPage>(`${base}/stack?id=${encodeURIComponent(props.stackId)}`), 4000, [props.server.id, props.stackId]);
  const [tab, setTab] = useState<Tab>("logs");
  const [run, setRun] = useState<Run | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [deleting, setDeleting] = useState(false);
  const [deleteAfter, setDeleteAfter] = useState(false);
  const [notice, setNotice] = useState<string>();
  const showRun = (r: Run) => {
    setRun(r);
    setTab("output");
    void reload();
  };
  const action = useAction((r: ActionResult) => {
    if (r.run) showRun(r.run);
    else void reload();
  });
  // The stack's last output is shown again when the page opens while it is still running.
  useEffect(() => {
    if (data?.run && !run) {
      setRun(data.run);
      if (data.run.phase === "running") setTab("output");
    }
  }, [data, run]);
  const unsaved = Object.values(drafts).some((d) => d.text !== d.original);
  useEffect(() => {
    if (!unsaved) return;
    const warn = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [unsaved]);
  // A successful delete leaves this page for the overview.
  useEffect(() => {
    if (deleteAfter && run && run.phase === "succeeded") app.go(`/servers/${props.server.id}/docker`);
  }, [deleteAfter, run, app, props.server.id]);
  if (!data) {
    return (
      <div className="page">
        {error ? <Notice tone="danger" actions={<a className="btn" href={`#/servers/${props.server.id}/docker`}>Back to Docker</a>}>{error}</Notice> : <Spinner />}
      </div>
    );
  }
  const s = data.stack;
  const readOnly = app.safety?.readOnly ?? true;
  const blocked = s.blocked ?? null;
  const containers = s.containers;
  const logsOf = containers.filter((c) => selected.length === 0 ? true : selected.includes(c.id));
  const icon = containers.find((c) => c.bookmark)?.bookmark?.href ?? s.link;
  const stackAction = (a: string, service?: string) => void action.request(`${base}/stack-action`, { stackId: s.id, action: a, service });
  const containerAction = (c: Container, a: "start" | "stop" | "restart") =>
    void action.request(`${base}/container-action`, { containerId: c.id, action: a });
  const openShell = async (c: Container) => {
    try {
      await api.post(`${base}/shell`, { containerId: c.id, cols: 100, rows: 30 });
      app.go(`/servers/${props.server.id}/terminal`);
    } catch (e) {
      setNotice(errorText(e));
    }
  };
  const back = () => {
    if (unsaved && !window.confirm("Leave without saving your changes?")) return;
    app.go(`/servers/${props.server.id}/docker`);
  };
  const compose = s.composeBlocked ?? null;
  const items: (MenuItem | null)[] = s.isStandalone ? [
    { label: "Pull Latest Image…", detail: "Download a newer copy of its image; the container keeps running the one it has.",
      onClick: () => void action.request(`${base}/pull-image`, { stackId: s.id }), disabled: !!blocked || !s.pullable,
      reason: blocked ?? (s.pullable ? null : "It runs an image that can't be pulled by name") },
    !containers[0] ? null : containers[0].isRunning
      ? { label: "Restart Container…", detail: "Restart it in place.", onClick: () => containerAction(containers[0]!, "restart"), disabled: !!blocked, reason: blocked }
      : { label: "Start Container", detail: "Start it again.", onClick: () => containerAction(containers[0]!, "start"), disabled: !!blocked, reason: blocked },
    { label: "Update", onClick: () => undefined, disabled: true, reason: compose },
    { label: "Rebuild", onClick: () => undefined, disabled: true, reason: compose },
    { label: "Recreate", onClick: () => undefined, disabled: true, reason: compose },
    null,
    { label: "Delete Container…", detail: "Stop and remove it.", danger: true, onClick: () => setDeleting(true), disabled: !!blocked, reason: blocked },
  ] : [
    { label: "Update…", detail: "Recreate what changed and start what is stopped.", onClick: () => stackAction("up"), disabled: !!blocked, reason: blocked },
    { label: "Pull Latest Images…", detail: "Download newer images; nothing restarts.", onClick: () => stackAction("pull"), disabled: !!blocked, reason: blocked },
    { label: "Rebuild…", detail: "Build images from the stack's Dockerfiles, then update.", onClick: () => stackAction("rebuild"), disabled: !!blocked, reason: blocked },
    { label: "Restart All…", detail: "Restart every container in place.", onClick: () => stackAction("restart"), disabled: !!blocked, reason: blocked },
    { label: "Recreate…", detail: "Stop and recreate every container.", danger: true, onClick: () => stackAction("recreate"), disabled: !!blocked, reason: blocked },
    null,
    { label: "Delete Stack…", detail: "docker compose down, optionally its volumes and folder.", danger: true, onClick: () => setDeleting(true), disabled: !!blocked, reason: blocked },
  ];
  const files = s.files ?? [];
  return (
    <div className="page page-wide">
      <nav className="breadcrumb">
        <button type="button" className="link" onClick={back}>Docker</button> <span className="muted">›</span> {s.name}
      </nav>
      <header className="page-head">
        <div className="stack-head">
          <SiteIcon href={icon} letter={s.letter} hue={s.hue} size={52} />
          <div>
            <h1>{s.name}</h1>
            <p className="muted">
              {s.kind} · {s.statusText || `${s.running} of ${s.total} running`}
              {s.workingDir && <> · <span className="mono">{s.workingDir}</span></>}
              {s.link && <> · <a href={s.link} target="_blank" rel="noreferrer noopener">{s.link}</a></>}
            </p>
          </div>
        </div>
        <div className="card-actions">
          {readOnly && <span className="badge">Read-only</span>}
          <Menu label="Stack Actions ▾" items={items} />
        </div>
      </header>
      {notice && <Notice tone="danger">{notice}</Notice>}
      {action.error && <Notice tone="danger">{action.error}</Notice>}
      {s.notStarted && !s.removing && <Notice tone="info">Not started yet: Update starts it.</Notice>}
      <div className="stack-body">
        <Card title="Containers" className="stack-containers">
          {containers.length === 0 && <p className="dim">No containers.</p>}
          <ul className="container-list">
            {containers.map((c) => {
              const on = selected.includes(c.id);
              const rowBlocked = readOnly ? "Read-only mode is on" : blocked;
              return (
                <li key={c.id} className={`container-row${on ? " selected" : ""}`}>
                  <button type="button" className="container-pick" aria-pressed={on}
                          title="Show this container's logs (click others to add them)"
                          onClick={() => {
                            setSelected(on ? selected.filter((x) => x !== c.id) : [...selected, c.id]);
                            setTab("logs");
                          }}>
                    <LetterTile letter={c.letter} hue={c.hue} size={30} />
                    <span className="container-text">
                      <span className="container-name">
                        <span className={`dot dot-${c.isUnhealthy ? "danger" : c.isRunning ? "ok" : "idle"}`} />
                        {c.service ?? c.name}
                      </span>
                      <span className="dim">{c.imageName}{c.imageTag ? `:${c.imageTag}` : ""} · {usage(c)}</span>
                      <span className="dim">{c.status}</span>
                    </span>
                  </button>
                  <Button small disabled={readOnly || !c.isRunning} title={readOnly ? "Read-only mode is on" : "Open a shell in this container"}
                          onClick={() => void openShell(c)}>Shell</Button>
                  <Menu small label="⋯" title={`More for ${c.name}`} items={[
                    { label: "Show Logs", onClick: () => { setSelected([c.id]); setTab("logs"); } },
                    { label: "Open Shell", onClick: () => void openShell(c), disabled: readOnly || !c.isRunning,
                      reason: readOnly ? "Read-only mode is on" : "It isn't running" },
                    { label: "Copy Name", onClick: () => void navigator.clipboard?.writeText(c.name) },
                    null,
                    c.isRunning
                      ? { label: "Restart…", onClick: () => containerAction(c, "restart"), disabled: !!rowBlocked, reason: rowBlocked }
                      : { label: "Start", onClick: () => containerAction(c, "start"), disabled: !!rowBlocked, reason: rowBlocked },
                    { label: "Stop…", danger: true, onClick: () => containerAction(c, "stop"), disabled: !!rowBlocked || !c.isRunning,
                      reason: rowBlocked ?? "It isn't running" },
                    c.canRebuild ? { label: "Rebuild from Dockerfile…", onClick: () => stackAction("rebuild", c.service),
                      disabled: !!blocked, reason: blocked } : null,
                  ]} />
                </li>
              );
            })}
          </ul>
        </Card>
        <section className="stack-panel">
          <div className="tabs" role="tablist">
            <button type="button" role="tab" aria-selected={tab === "logs"} className={`tab${tab === "logs" ? " active" : ""}`}
                    onClick={() => setTab("logs")}>Logs</button>
            {run && (
              <button type="button" role="tab" aria-selected={tab === "output"} className={`tab${tab === "output" ? " active" : ""}`}
                      onClick={() => setTab("output")}>Output{run.phase === "running" ? " ●" : ""}</button>
            )}
            {files.map((f) => (
              <button key={f.path} type="button" role="tab" aria-selected={tab === f.path}
                      className={`tab${tab === f.path ? " active" : ""}`} title={f.path} onClick={() => setTab(f.path)}>
                {f.name}{drafts[f.path] && drafts[f.path]!.text !== drafts[f.path]!.original ? " •" : ""}
              </button>
            ))}
          </div>
          <div className="panel-body">
            {tab === "logs" && (logsOf.length
              ? <LogsPanel serverId={props.server.id} containers={logsOf} />
              : <p className="dim panel-pad">No containers to follow.</p>)}
            {tab === "output" && run && (
              <OutputPanel run={run} onChanged={(r) => { setRun(r); if (r.phase !== "running") void reload(); }}
                           onClose={() => { setRun(null); setTab("logs"); }} />
            )}
            {files.some((f) => f.path === tab) && (
              <EditorPanel key={tab} serverId={props.server.id} stack={s} path={tab} draft={drafts[tab]}
                           onDraft={(d) => setDrafts((m) => ({ ...m, [tab]: d }))} onRun={showRun} />
            )}
          </div>
        </section>
      </div>
      {deleting && (
        <DeleteSheet stack={s} onCancel={() => setDeleting(false)}
                     onContinue={(removeVolumes, deleteFolder) => {
                       setDeleting(false);
                       setDeleteAfter(true);
                       void action.request(`${base}/delete`, { stackId: s.id, removeVolumes, deleteFolder });
                     }} />
      )}
      {action.sheet}
    </div>
  );
}
