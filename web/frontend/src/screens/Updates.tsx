// Updates: what apt already knows (read when the page opens and after each action; Refresh Lists asks the
// repositories), Install All / Install Security Updates streamed into Output, the sudo password when sudo wants one,
// and Reboot… when the server's own reboot-required flag is set.
import { useEffect, useState } from "react";
import { api } from "../api";
import { errorText, outputSize } from "../components/docker";
import { ConfirmSheet } from "../components/ConfirmSheet";
import { PasswordSheet, RebootBanner, useReboot } from "../components/root";
import { Button, Card, Empty, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import { ago } from "../format";
import { useNow } from "../hooks";
import type { PendingAction, Run, Server, UpdatesState } from "../types";
import { OutputPanel } from "./DockerPanels";

type Action = "refresh" | "upgradeAll" | "security";

export function UpdatesScreen(props: { server: Server }) {
  const app = useApp();
  const now = useNow();
  const base = `/api/servers/${props.server.id}`;
  const [state, setState] = useState<UpdatesState>();
  const [error, setError] = useState<string>();
  const [reading, setReading] = useState(false);
  const [run, setRun] = useState<Run | null>(null);
  const [pending, setPending] = useState<PendingAction>();
  const [asking, setAsking] = useState<{ action: Action; error: string | null }>();
  const [last, setLast] = useState<Action>();
  const read = async () => {
    setReading(true);
    try {
      const s = await api.get<UpdatesState>(`${base}/updates`);
      setState(s);
      setError(undefined);
      if (s.run && !run) setRun(s.run);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setReading(false);
    }
  };
  useEffect(() => {
    void read();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.server.id]);
  const reboot = useReboot(props.server, () => void read());
  const propose = async (action: Action, password?: string) => {
    setError(undefined);
    setLast(action);
    try {
      const r = await api.post<{ pending: PendingAction }>(`${base}/updates/action`,
        { action, ...outputSize, ...(password ? { password } : {}) });
      setPending(r.pending);
    } catch (e) {
      setError(errorText(e));
    }
  };
  const runChanged = (r: Run) => {
    setRun(r);
    if (r.phase === "running") return;
    void read();
    void app.reloadFleet();
    if (r.needsPassword && last) {
      setAsking({ action: last, error: r.sudo === "rejected" ? "The server did not accept that password." : null });
    }
  };
  if (!state) return <div className="page">{error ? <Notice tone="danger">{error}</Notice> : <Spinner />}</div>;
  const readOnly = app.safety?.readOnly ?? true;
  const busy = run?.phase === "running";
  const blocked = readOnly ? "Read-only mode is on" : busy ? "An action is running" : null;
  return (
    <div className="page">
      <header className="page-head">
        <div>
          <h1>Updates</h1>
          <p className="muted">{state.subtitle ?? state.error ?? "Reading…"}
            {state.refreshedText && <> · package lists refreshed {state.refreshedText}</>}
            {state.updatedAt && <> · read {ago(state.updatedAt, now)}</>}</p>
        </div>
        <Button disabled={reading} onClick={() => void read()}>{reading ? "Reading…" : "Read Again"}</Button>
      </header>
      {error && <Notice tone="danger">{error}</Notice>}
      {reboot.error && <Notice tone="danger">{reboot.error}</Notice>}
      <RebootBanner server={props.server} reboot={state.reboot}
                    onDismiss={() => void api.post(`${base}/reboot/dismiss`).then(read)} />
      {state.status === "notInstalled" && <Empty title="apt is not installed on this server" />}
      {state.status === "failed" && <Notice tone="danger" title="The update list couldn't be read"><p className="raw">{state.error}</p></Notice>}
      {state.rebootRequired && state.reboot?.phase !== "waiting" && (
        <Notice tone="warn" title="A reboot is required to finish applying updates"
                actions={<Button disabled={readOnly} title={readOnly ? "Read-only mode is on" : undefined}
                                 onClick={reboot.request}>Reboot…</Button>}>
          <p>The server set its own reboot-required flag after an update (a kernel, libc or systemd package).</p>
        </Notice>
      )}
      {state.staleness && <Notice tone="info">{state.staleness}</Notice>}
      {state.status === "ready" && (
        <div className="card-actions">
          <Button disabled={!!blocked} title={blocked ?? undefined} onClick={() => void propose("refresh")}>Refresh Lists…</Button>
          <Button disabled={!!blocked || state.packages.length === 0} title={blocked ?? undefined}
                  onClick={() => void propose("upgradeAll")}>Install All…</Button>
          <Button kind="primary" disabled={!!blocked || !!state.securityHint}
                  title={blocked ?? state.securityHint ?? undefined} onClick={() => void propose("security")}>
            Install Security Updates…
          </Button>
        </div>
      )}
      {run && (
        <section className="stack-panel updates-output">
          <OutputPanel run={run} onChanged={runChanged} onClose={() => setRun(null)} />
        </section>
      )}
      {state.status === "ready" && state.packages.length > 0 && (
        <Card title={`${state.packages.length} pending`}>
          <div className="health-wrap">
            <table className="health">
              <thead><tr><th>Package</th><th>New version</th><th>Installed</th><th>From</th></tr></thead>
              <tbody>
                {state.packages.map((p) => (
                  <tr key={`${p.name}:${p.architecture}`}>
                    <td><strong>{p.name}</strong> {p.isSecurity && <span className="badge badge-danger">security</span>}</td>
                    <td className="mono">{p.newVersion}</td>
                    <td className="mono dim">{p.oldVersion ?? "—"}</td>
                    <td className="dim">{p.suite}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}
      {state.held.length > 0 && (
        <Card title="Held"><p className="muted">apt leaves these alone: {state.held.join(", ")}</p></Card>
      )}
      {pending && (
        <ConfirmSheet action={pending} onCancel={() => setPending(undefined)}
                      onDone={(result) => {
                        setPending(undefined);
                        setAsking(undefined);
                        const r = result as { run?: Run };
                        if (r.run) setRun(r.run);
                      }} />
      )}
      {asking && !pending && (
        <PasswordSheet server={props.server} error={asking.error}
                       why={`sudo on ${props.server.name} wants ${props.server.user ?? "this user"}'s password for apt.`}
                       onCancel={() => setAsking(undefined)} onSubmit={(pw) => void propose(asking.action, pw)} />
      )}
      {reboot.sheets}
    </div>
  );
}
