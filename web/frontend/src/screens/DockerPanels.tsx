// The stack page's right-hand panel: live Output of an action (read-only xterm.js), merged container Logs, and the
// compose/.env editor. The backend decides everything (the check, the checklist, whether Save may be pressed); the
// page sends the exact text and shows the verdict for that text only.
import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { api } from "../api";
import { errorText, outputSize, useAction } from "../components/docker";
import { Button, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import type { ActionResult, CheckRow, Container, EditorFile, Run, Stack, Verdict } from "../types";
import { xtermTheme } from "../xterm";

function socketURL(path: string): string {
  const proto = window.location.protocol === "https:" ? "wss" : "ws";
  return `${proto}://${window.location.host}${path}`;
}

// --- Output ---------------------------------------------------------------------------------------------------------

export function OutputPanel(props: { run: Run; onChanged: (run: Run) => void; onClose: () => void }) {
  const app = useApp();
  const host = useRef<HTMLDivElement>(null);
  const [run, setRun] = useState(props.run);
  const onChanged = useRef(props.onChanged);
  onChanged.current = props.onChanged;
  useEffect(() => setRun(props.run), [props.run]);
  useEffect(() => {
    const term = new Terminal({
      fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace', fontSize: 12.5, disableStdin: true,
      scrollback: 20_000, theme: xtermTheme(app.appearance), convertEol: false, cursorBlink: false,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(host.current!);
    const measure = () => {
      try {
        fit.fit();
        outputSize.cols = term.cols;
        outputSize.rows = term.rows;
      } catch {
        // not laid out yet
      }
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(host.current!);
    const socket = new WebSocket(socketURL(`/api/runs/${props.run.id}/ws`));
    socket.binaryType = "arraybuffer";
    socket.onmessage = (e: MessageEvent<ArrayBuffer | string>) => {
      if (typeof e.data === "string") {
        const state = JSON.parse(e.data) as Run & { type: string };
        setRun(state);
        onChanged.current(state);
      } else {
        term.write(new Uint8Array(e.data));
      }
    };
    return () => {
      observer.disconnect();
      socket.close();
      term.dispose();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.run.id]);
  const cancel = () => void api.post(`/api/runs/${run.id}/cancel`).catch(() => undefined);
  const close = async () => {
    await api.del(`/api/runs/${run.id}`).catch(() => undefined);
    props.onClose();
  };
  const tone = run.phase === "succeeded" ? "ok" : run.phase === "running" ? "info" : "danger";
  return (
    <div className="output">
      <div className={`output-head output-${tone}`}>
        {run.phase === "running" && <Spinner />}
        <span className="output-title">
          {run.phase === "running" ? run.working : run.phase === "succeeded" ? `${run.title}: done` : run.message}
        </span>
        <span className="mono dim">{run.title}</span>
        {run.phase === "running"
          ? <Button small onClick={cancel}>Cancel</Button>
          : <Button small onClick={() => void close()}>Close</Button>}
      </div>
      <div className="output-frame"><div ref={host} className="output-surface" /></div>
    </div>
  );
}

// --- Logs -----------------------------------------------------------------------------------------------------------

interface Entry { id: number; source: string; time: string | null; level: string | null; message: string }

const MAX_ENTRIES = 2000;

/** Follows the chosen containers' logs, merged. Closing the panel closes the socket, which stops each remote
 * `docker logs -f` with Ctrl-C. Follows the end while it is in view; scrolled up, new lines are counted instead. */
export function LogsPanel(props: { serverId: string; containers: Container[] }) {
  const [entries, setEntries] = useState<Entry[]>([]);
  const [live, setLive] = useState(false);
  const [error, setError] = useState<string>();
  const [unseen, setUnseen] = useState(0);
  const [filter, setFilter] = useState("");
  const list = useRef<HTMLDivElement>(null);
  const atEnd = useRef(true);
  const ids = props.containers.map((c) => c.id).join(",");
  const many = props.containers.length > 1;
  useEffect(() => {
    setEntries([]);
    setUnseen(0);
    setError(undefined);
    if (!ids) return;
    const socket = new WebSocket(socketURL(`/api/servers/${props.serverId}/docker/logs/ws?ids=${ids}`));
    socket.onmessage = (e: MessageEvent<string>) => {
      const frame = JSON.parse(e.data) as { type: string; live?: boolean; entries?: Entry[]; message?: string; source?: string };
      if (frame.type === "state") setLive(!!frame.live);
      if (frame.type === "error") setError(`${frame.source}: ${frame.message}`);
      if (frame.type === "lines" && frame.entries) {
        const added = frame.entries;
        setEntries((old) => {
          const next = old.concat(added);
          return next.length > MAX_ENTRIES ? next.slice(next.length - MAX_ENTRIES) : next;
        });
        if (!atEnd.current) setUnseen((n) => n + added.length);
      }
    };
    socket.onclose = () => setLive(false);
    return () => socket.close();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ids, props.serverId]);
  useLayoutEffect(() => {
    if (atEnd.current && list.current) list.current.scrollTop = list.current.scrollHeight;
  }, [entries]);
  const onScroll = () => {
    const el = list.current;
    if (!el) return;
    atEnd.current = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
    if (atEnd.current) setUnseen(0);
  };
  const toEnd = () => {
    atEnd.current = true;
    setUnseen(0);
    if (list.current) list.current.scrollTop = list.current.scrollHeight;
  };
  const shown = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return q ? entries.filter((e) => e.message.toLowerCase().includes(q) || e.source.toLowerCase().includes(q)) : entries;
  }, [entries, filter]);
  return (
    <div className="logs">
      <div className="logs-head">
        <span className={`dot dot-${live ? "ok" : "idle"}`} title={live ? "Following" : "Not following"} />
        <span className="dim">{live ? "Following" : "Stopped"} · {props.containers.map((c) => c.service ?? c.name).join(", ")}</span>
        <span className="sheet-footer-spacer" />
        <input type="search" placeholder="Filter lines" value={filter} onChange={(e) => setFilter(e.target.value)}
               aria-label="Filter log lines" />
      </div>
      {error && <Notice tone="danger">{error}</Notice>}
      <div className="logs-list" ref={list} onScroll={onScroll} role="log" aria-live="off">
        {shown.length === 0 && <div className="dim logs-empty">{live ? "Waiting for lines…" : "No lines."}</div>}
        {shown.map((e) => (
          <div key={e.id} className={`log-line${e.level ? ` log-${e.level}` : ""}`}>
            {e.time && <span className="log-time">{e.time.replace("T", " ").replace(/\.\d+Z?$/, "")}</span>}
            {e.level && <span className="log-level">{e.level}</span>}
            {many && <span className="log-source">{e.source}</span>}
            <span className="log-message">{e.message}</span>
          </div>
        ))}
      </div>
      {unseen > 0 && <button type="button" className="jump" onClick={toEnd}>{unseen} new ↓</button>}
    </div>
  );
}

// --- Editor ---------------------------------------------------------------------------------------------------------

function Checklist(props: { rows: CheckRow[] }) {
  if (props.rows.length === 0) return null;
  const icon = { pass: "✓", fail: "✕", warn: "!", skipped: "–", running: "…" };
  return (
    <ul className="checklist">
      {props.rows.map((r) => (
        <li key={r.id} className={`check-${r.state}`}>
          <span className="check-icon" aria-label={r.state}>{icon[r.state]}</span>
          <span><strong>{r.title}</strong>{r.detail && <span className="dim"> {r.detail}</span>}</span>
        </li>
      ))}
    </ul>
  );
}

/** A plain text area with a line-number gutter that marks changed lines and the lines the server's check failed on. */
function CodeArea(props: { text: string; onChange: (t: string) => void; changed: number[]; errors: number[];
  readOnly: boolean; label: string }) {
  const gutter = useRef<HTMLDivElement>(null);
  const lines = props.text.split("\n").length;
  const changed = new Set(props.changed);
  const errors = new Set(props.errors);
  return (
    <div className="code">
      <div className="code-gutter" ref={gutter} aria-hidden="true">
        {Array.from({ length: lines }, (_, i) => (
          <div key={i} className={errors.has(i + 1) ? "line-error" : changed.has(i + 1) ? "line-changed" : undefined}>{i + 1}</div>
        ))}
      </div>
      <textarea value={props.text} spellCheck={false} autoCapitalize="off" autoCorrect="off" readOnly={props.readOnly}
                aria-label={props.label} wrap="off"
                onScroll={(e) => gutter.current && (gutter.current.scrollTop = e.currentTarget.scrollTop)}
                onKeyDown={(e) => {
                  if (e.key === "Tab" && !e.shiftKey) { // two spaces, like the Mac's editor
                    e.preventDefault();
                    const el = e.currentTarget;
                    const { selectionStart: a, selectionEnd: b } = el;
                    props.onChange(props.text.slice(0, a) + "  " + props.text.slice(b));
                    requestAnimationFrame(() => el.setSelectionRange(a + 2, a + 2));
                  }
                }}
                onChange={(e) => props.onChange(e.target.value)} />
    </div>
  );
}

export interface Draft { file: EditorFile; original: string; sha: string | null; text: string }

/** One file's editor. The draft lives in the stack page, so switching tabs keeps what was typed. */
export function EditorPanel(props: {
  serverId: string;
  stack: Stack;
  path: string;
  draft: Draft | undefined;
  onDraft: (d: Draft) => void;
  onRun: (run: Run) => void;
}) {
  const app = useApp();
  const readOnly = app.safety?.readOnly ?? true;
  const [loadError, setLoadError] = useState<string>();
  const [verdict, setVerdict] = useState<{ text: string; v: Verdict }>();
  const [checking, setChecking] = useState(false);
  const [notice, setNotice] = useState<{ tone: "warn" | "danger" | "ok"; text: string; reload?: boolean }>();
  const base = `/api/servers/${props.serverId}/docker`;
  const d = props.draft;
  const load = async () => {
    setLoadError(undefined);
    setNotice(undefined);
    try {
      const f = await api.post<EditorFile>(`${base}/files/read`, { stackId: props.stack.id, path: props.path });
      if (f.status === "tooLarge") {
        setLoadError(`${f.name} is larger than 64 KiB, so it can't be edited here.`);
        return;
      }
      props.onDraft({ file: f, original: f.content ?? "", sha: f.sha, text: f.content ?? "" });
    } catch (e) {
      setLoadError(errorText(e));
    }
  };
  useEffect(() => {
    if (!d) void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.path]);
  // A quick verdict at once (no server round trip), then the server's check of exactly this text after a pause.
  useEffect(() => {
    if (!d) return;
    let current = true;
    const ask = (checkServer: boolean) => api.post<Verdict>(`${base}/files/check`, {
      stackId: props.stack.id, path: props.path, original: d.original, text: d.text, checkServer,
    }).then((v) => current && (checkServer || !verdict || verdict.text !== d.text) && setVerdict({ text: d.text, v }))
      .catch((e) => current && setNotice({ tone: "danger", text: errorText(e) }));
    void ask(false);
    if (d.text === d.original) return;
    setChecking(true);
    const timer = window.setTimeout(() => void ask(true).finally(() => current && setChecking(false)), 600);
    return () => {
      current = false;
      window.clearTimeout(timer);
      setChecking(false);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [d?.text, d?.original, readOnly]);
  const action = useAction((r: ActionResult) => {
    if (!d) return;
    if (r.outcome === "saved") {
      props.onDraft({ ...d, original: d.text, sha: r.sha ?? d.sha });
      setNotice({ tone: "ok", text: `Saved ${d.file.name}. The previous version is kept as ${d.file.name}.rackoon.bak.` });
      if (r.run) props.onRun(r.run);
    } else if (r.outcome === "changed") {
      setNotice({ tone: "warn", text: r.message ?? "The file changed on the server.", reload: true });
    } else if (r.outcome === "invalid") {
      setNotice({ tone: "danger", text: `${r.message ?? "The server refused it."} ${r.issues?.map((i) => i.message).join(" ") ?? ""}` });
    }
  });
  if (loadError) return <div className="panel-pad"><Notice tone="danger" actions={<Button onClick={() => void load()}>Try Again</Button>}>{loadError}</Notice></div>;
  if (!d) return <div className="panel-pad"><Spinner /></div>;
  const v = verdict && verdict.text === d.text ? verdict.v : undefined;
  const dirty = d.text !== d.original;
  const save = (redeploy: boolean) => void action.request(`${base}/files/save`, {
    stackId: props.stack.id, path: props.path, original: d.file.status === "file" ? d.original : null, sha: d.sha,
    text: d.text, redeploy,
  });
  return (
    <div className="editor">
      {d.file.status === "missing" && <Notice tone="info">{d.file.name} doesn't exist yet. Saving creates it (readable
        only by its owner).</Notice>}
      {notice && (
        <Notice tone={notice.tone} actions={notice.reload ? <>
          <Button onClick={() => void load()}>Reload from Server</Button>
          <Button onClick={() => setNotice(undefined)}>Keep Editing</Button>
        </> : undefined}>{notice.text}</Notice>
      )}
      {action.error && <Notice tone="danger">{action.error}</Notice>}
      <CodeArea text={d.text} onChange={(text) => props.onDraft({ ...d, text })} changed={v?.changedLines ?? []}
                errors={v?.errorLines ?? []} readOnly={readOnly} label={d.file.name} />
      <div className="editor-foot">
        <div className="editor-checks">
          {dirty ? <Checklist rows={v?.rows ?? []} /> : <span className="dim">No changes.</span>}
          {checking && <span className="dim"><Spinner /> Checking on the server…</span>}
        </div>
        <div className="editor-buttons">
          <span className="dim">{v?.blocked && dirty ? v.blocked : dirty && v ? `${v.changeCount} changed line${v.changeCount === 1 ? "" : "s"}` : ""}</span>
          <Button disabled={!dirty} onClick={() => props.onDraft({ ...d, text: d.original })}>Revert</Button>
          <Button disabled={!v?.canSave || action.asking} onClick={() => save(false)}>Save…</Button>
          <Button kind="primary" disabled={!v?.canSave || action.asking || !!props.stack.blocked}
                  title={props.stack.blocked ?? undefined} onClick={() => save(true)}>Save and Redeploy…</Button>
        </div>
      </div>
      {action.sheet}
    </div>
  );
}
