// Add a container: a form (or a pasted compose file) on the left; on the right, what the files will be and the
// server's checks of exactly that draft. The backend builds the files and decides whether Create may be pressed.
import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { errorText, stackRoute, useAction } from "../components/docker";
import { Button, Card, Field, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import type { ActionResult, CheckRow, Server } from "../types";

interface Row { [k: string]: string }
interface Draft {
  target: "new" | "existing";
  stackName: string;
  folder: string;
  existingName: string | null;
  paste: boolean;
  pasteCompose: string;
  pasteEnv: string;
  spec: { name: string; image: string; ports: Row[]; volumes: Row[]; env: Row[]; restart: string };
}
interface Evaluation {
  rows: CheckRow[];
  blocked: string | null;
  missingVariables: string[];
  compose: string;
  env: string;
  directory: string | null;
  checking: boolean;
}
interface Defaults { defaultParent: string; stacks: { id: string; name: string; workingDir: string | null }[]; restartPolicies: string[] }

const EMPTY: Draft = {
  target: "new", stackName: "", folder: "/opt/stacks", existingName: null, paste: false, pasteCompose: "", pasteEnv: "",
  spec: { name: "", image: "", ports: [], volumes: [], env: [], restart: "unless-stopped" },
};

function Rows(props: { title: string; rows: Row[]; keys: [string, string]; placeholders: [string, string];
  onChange: (rows: Row[]) => void }) {
  const [a, b] = props.keys;
  return (
    <fieldset className="rowset">
      <legend>{props.title}</legend>
      {props.rows.map((r, i) => (
        <div key={i} className="rowset-row">
          <input value={r[a] ?? ""} placeholder={props.placeholders[0]} aria-label={`${props.title} ${a}`}
                 onChange={(e) => props.onChange(props.rows.map((x, j) => j === i ? { ...x, [a]: e.target.value } : x))} />
          <span className="muted">{props.title === "Environment" ? "=" : "→"}</span>
          <input value={r[b] ?? ""} placeholder={props.placeholders[1]} aria-label={`${props.title} ${b}`}
                 onChange={(e) => props.onChange(props.rows.map((x, j) => j === i ? { ...x, [b]: e.target.value } : x))} />
          <button type="button" className="icon-btn" aria-label="Remove row"
                  onClick={() => props.onChange(props.rows.filter((_, j) => j !== i))}>×</button>
        </div>
      ))}
      <button type="button" className="link" onClick={() => props.onChange([...props.rows, { [a]: "", [b]: "" }])}>
        + Add
      </button>
    </fieldset>
  );
}

function Checks(props: { rows: CheckRow[] }) {
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

export function AddContainerScreen(props: { server: Server }) {
  const app = useApp();
  const base = `/api/servers/${props.server.id}/docker`;
  const [defaults, setDefaults] = useState<Defaults>();
  const [draft, setDraft] = useState<Draft>(EMPTY);
  const [result, setResult] = useState<{ key: string; e: Evaluation }>();
  const [error, setError] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const [tick, setTick] = useState(0);
  const key = JSON.stringify(draft);
  const latest = useRef(key);
  latest.current = key;
  useEffect(() => {
    void api.get<Defaults>(`${base}/add`).then((d) => {
      setDefaults(d);
      setDraft((x) => ({ ...x, folder: d.defaultParent }));
    }).catch((e) => setError(errorText(e)));
  }, [base]);
  // Checks run 600 ms after the last change, and again every 1.5 s while one is still running (the image lookup).
  useEffect(() => {
    if (!defaults) return;
    const sent = key;
    const timer = window.setTimeout(() => {
      void api.post<Evaluation>(`${base}/add/evaluate`, JSON.parse(sent))
        .then((e) => {
          if (latest.current !== sent) return;
          setResult({ key: sent, e });
          setError(undefined);
          if (e.checking) window.setTimeout(() => setTick((t) => t + 1), 1500);
        })
        .catch((e) => latest.current === sent && setError(errorText(e)));
    }, 600);
    return () => window.clearTimeout(timer);
  }, [key, base, defaults, tick]);
  const action = useAction((r: ActionResult) => {
    if ((r.outcome === "created" || r.outcome === "saved") && r.stackId) app.go(stackRoute(props.server.id, r.stackId));
    else setNotice(r.message ?? "Nothing was written.");
  });
  const readOnly = app.safety?.readOnly ?? true;
  const ev = result?.key === key ? result.e : undefined;
  const set = (patch: Partial<Draft>) => setDraft((d) => ({ ...d, ...patch }));
  const spec = (patch: Partial<Draft["spec"]>) => setDraft((d) => ({ ...d, spec: { ...d.spec, ...patch } }));
  const dirty = draft.spec.name || draft.spec.image || draft.stackName || draft.pasteCompose;
  const leave = () => {
    if (dirty && !window.confirm("Leave without adding the container?")) return;
    app.go(`/servers/${props.server.id}/docker`);
  };
  const deploy = (start: boolean) => void action.request(`${base}/add/deploy`, { draft, start });
  if (!defaults) return <div className="page">{error ? <Notice tone="danger">{error}</Notice> : <Spinner />}</div>;
  const blocked = readOnly ? "Read-only mode is on" : ev ? ev.blocked : `Checking on ${props.server.name}…`;
  return (
    <div className="page page-wide">
      <nav className="breadcrumb">
        <button type="button" className="link" onClick={leave}>Docker</button> <span className="muted">›</span> Add Container
      </nav>
      <header className="page-head"><h1>Add a container</h1></header>
      {error && <Notice tone="danger">{error}</Notice>}
      {notice && <Notice tone="warn">{notice}</Notice>}
      {action.error && <Notice tone="danger">{action.error}</Notice>}
      <div className="add-body">
        <Card title="Where">
          <div className="segmented" role="group">
            <button type="button" className={draft.target === "new" ? "on" : ""} onClick={() => set({ target: "new" })}>New stack</button>
            <button type="button" className={draft.target === "existing" ? "on" : ""}
                    disabled={defaults.stacks.length === 0}
                    onClick={() => set({ target: "existing", paste: false, existingName: draft.existingName ?? defaults.stacks[0]?.id ?? null })}>
              Existing stack
            </button>
          </div>
          {draft.target === "new" ? (
            <div className="form-row">
              <Field label="Stack name" hint="Lowercase letters, digits, - and _">
                <input value={draft.stackName} onChange={(e) => set({ stackName: e.target.value })} spellCheck={false} />
              </Field>
              <Field label="In folder"><input value={draft.folder} onChange={(e) => set({ folder: e.target.value })} spellCheck={false} /></Field>
            </div>
          ) : (
            <Field label="Stack">
              <select value={draft.existingName ?? ""} onChange={(e) => set({ existingName: e.target.value })}>
                {defaults.stacks.map((s) => <option key={s.id} value={s.id}>{s.name} ({s.workingDir})</option>)}
              </select>
            </Field>
          )}
          {draft.target === "new" && (
            <label className="check">
              <input type="checkbox" checked={draft.paste} onChange={(e) => set({ paste: e.target.checked })} />
              <span>Paste a compose file instead of filling in the form</span>
            </label>
          )}
          {draft.paste ? (
            <>
              <Field label="compose.yaml">
                <textarea className="mono" rows={14} value={draft.pasteCompose} spellCheck={false}
                          onChange={(e) => set({ pasteCompose: e.target.value })} />
              </Field>
              <Field label=".env" hint="Optional. Written readable by its owner only.">
                <textarea className="mono" rows={4} value={draft.pasteEnv} spellCheck={false}
                          onChange={(e) => set({ pasteEnv: e.target.value })} />
              </Field>
              {ev && ev.missingVariables.length > 0 && (
                <Notice tone="warn" actions={<Button small onClick={() => set({
                  pasteEnv: draft.pasteEnv + (draft.pasteEnv && !draft.pasteEnv.endsWith("\n") ? "\n" : "") +
                    ev.missingVariables.map((v) => `${v}=\n`).join(""),
                })}>Add to .env</Button>}>
                  Not set: {ev.missingVariables.join(", ")}
                </Notice>
              )}
            </>
          ) : (
            <>
              <div className="form-row">
                <Field label="Container name"><input value={draft.spec.name} onChange={(e) => spec({ name: e.target.value })} spellCheck={false} /></Field>
                <Field label="Restart">
                  <select value={draft.spec.restart} onChange={(e) => spec({ restart: e.target.value })}>
                    {defaults.restartPolicies.map((p) => <option key={p}>{p}</option>)}
                  </select>
                </Field>
              </div>
              <Field label="Image"><input value={draft.spec.image} placeholder="louislam/uptime-kuma:1" spellCheck={false}
                                          onChange={(e) => spec({ image: e.target.value })} /></Field>
              <Rows title="Ports" rows={draft.spec.ports} keys={["host", "container"]} placeholders={["8080", "80"]}
                    onChange={(ports) => spec({ ports })} />
              <Rows title="Volumes" rows={draft.spec.volumes} keys={["source", "target"]} placeholders={["./data", "/data"]}
                    onChange={(volumes) => spec({ volumes })} />
              <Rows title="Environment" rows={draft.spec.env} keys={["key", "value"]} placeholders={["TZ", "Europe/Dublin"]}
                    onChange={(env) => spec({ env })} />
            </>
          )}
        </Card>
        <div className="add-side">
          <Card title="Checks">
            {ev ? <Checks rows={ev.rows} /> : <Spinner />}
            {ev?.checking && <p className="dim"><Spinner /> Still checking…</p>}
          </Card>
          <Card title={ev?.directory ? `${ev.directory}/compose.yaml` : "compose.yaml"}>
            <pre className="command">{ev?.compose ?? ""}</pre>
            {ev?.env && <><h3 className="spaced">.env</h3><pre className="command">{ev.env}</pre></>}
          </Card>
          <div className="form-actions">
            <span className="dim">{blocked ?? ""}</span>
            <Button disabled={!!blocked || action.asking} onClick={() => deploy(false)}>
              {draft.target === "new" ? "Create Only…" : "Save Only…"}
            </Button>
            <Button kind="primary" disabled={!!blocked || action.asking} onClick={() => deploy(true)}>
              {draft.target === "new" ? "Create and Start…" : "Add and Start…"}
            </Button>
          </div>
        </div>
      </div>
      {action.sheet}
    </div>
  );
}
