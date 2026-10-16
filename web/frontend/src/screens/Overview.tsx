import { useState } from "react";
import { api } from "../api";
import { HostKeyDialog } from "../components/HostKeyDialog";
import { Button, Card, CopyButton, Empty, Meter, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import { ago, bytes, duration, percent, serverClock } from "../format";
import { useNow, usePoll } from "../hooks";
import type { AttentionItem, Server, ServerState } from "../types";

function AttentionStrip(props: { items: AttentionItem[] }) {
  if (props.items.length === 0) return null;
  const red = props.items.some((i) => i.red);
  return (
    <section className={`attention ${red ? "attention-red" : "attention-amber"}`} aria-label="Needs attention">
      <header>
        <strong>{props.items.length === 1 ? "1 thing needs attention" : `${props.items.length} things need attention`}</strong>
      </header>
      <ul>
        {props.items.map((i) => (
          <li key={i.id}>
            <span className={`dot dot-${i.red ? "danger" : "warn"}`} aria-hidden="true" />
            <span>{i.short}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

function ConnectionProblem(props: { server: Server; state: ServerState; onRetry: () => void; onTrust: () => void }) {
  const { state } = props;
  const keyIssue = state.connection === "hostKeyUnknown" || state.connection === "hostKeyChanged";
  return (
    <Notice
      tone={state.connection === "hostKeyUnknown" ? "info" : "danger"}
      title={state.failure?.headline ?? "The last check failed."}
      actions={
        <>
          {keyIssue && <Button kind="primary" onClick={props.onTrust}>{state.connection === "hostKeyUnknown" ? "Check Host Key…" : "Show Fingerprints"}</Button>}
          <a className="btn btn-plain" href={`#/settings/servers/${props.server.id}`}>Edit Connection…</a>
          <Button onClick={props.onRetry}>Try Again</Button>
        </>
      }
    >
      {state.failure && <p>{state.failure.advice}</p>}
      <p className="raw">{state.error}</p>
    </Notice>
  );
}

function SystemInfo(props: { state: ServerState; now: number }) {
  const o = props.state.overview!;
  const polled = props.state.updatedAt ?? props.now;
  const rows: [string, React.ReactNode][] = [
    ["Model", props.state.derived?.modelName || "—"],
    ["Operating system", o.os.prettyName],
    ["Kernel", o.kernel || "—"],
    ["Server time", <>{serverClock(o.serverTime, o.utcOffsetSeconds, polled, props.now)} {o.timeZoneName}</>],
    ["IP address", o.ipAddress ? <span className="copyable">{o.ipAddress} <CopyButton text={o.ipAddress} label="IP address" /></span> : "—"],
  ];
  if (o.tailscaleIP) {
    rows.push(["Tailscale IP", <span className="copyable">{o.tailscaleIP} <CopyButton text={o.tailscaleIP} label="Tailscale IP" /></span>]);
  }
  rows.push(["Machine ID", <code>{o.machineID || "—"}</code>], ["Boot ID", <code>{o.bootID || "—"}</code>]);
  return (
    <Card title="System">
      <dl className="facts">
        {rows.map(([k, v]) => (
          <div key={k}><dt>{k}</dt><dd>{v}</dd></div>
        ))}
      </dl>
    </Card>
  );
}

export function OverviewScreen(props: { server: Server }) {
  const app = useApp();
  const now = useNow();
  const [trusting, setTrusting] = useState(false);
  const { data: state, reload } = usePoll(
    () => api.get<ServerState>(`/api/servers/${props.server.id}/state?watch=1`), 5000, [props.server.id]);
  const refresh = async () => {
    await api.post(`/api/servers/${props.server.id}/refresh`);
    await reload();
    await app.reloadFleet();
  };
  if (!state) return <div className="page"><Spinner /></div>;
  const o = state.overview;
  const polledAt = state.updatedAt ?? now;
  return (
    <div className="page">
      <header className="page-head">
        <div>
          <h1>{props.server.name}</h1>
          <p className="muted">
            {o ? `${o.os.prettyName} · ${o.hostname}` : props.server.host}
            {" · "}
            {state.isStale ? <span className="stale">Cached reading from {ago(state.updatedAt, now)}</span>
                           : state.updatedAt ? `Updated ${ago(state.updatedAt, now)}`
                           : state.error ? "Has not answered yet" : "Connecting…"}
          </p>
        </div>
        <Button onClick={() => void refresh()}>Refresh</Button>
      </header>

      {state.error && (
        <ConnectionProblem server={props.server} state={state} onRetry={() => void refresh()} onTrust={() => setTrusting(true)} />
      )}
      {o && <AttentionStrip items={state.attention} />}

      {!o && !state.error && <Empty title="Connecting…"><Spinner /></Empty>}
      {o && (
        <>
          <div className="tiles">
            <Card title="CPU">
              <div className="big">{percent(state.cpuPercent)}</div>
              <Meter value={state.cpuPercent == null ? null : state.cpuPercent / 100} label="CPU" />
              <p className="muted">{o.cores} cores · load {o.load1.toFixed(2)} / {o.load5.toFixed(2)} / {o.load15.toFixed(2)}</p>
            </Card>
            <Card title="Memory">
              <div className="big">{percent((state.derived?.memoryUsedFraction ?? 0) * 100)}</div>
              <Meter value={state.derived?.memoryUsedFraction} label="Memory" />
              <p className="muted">{bytes(state.derived?.memoryUsedBytes ?? 0)} of {bytes(o.memory.totalBytes)}</p>
            </Card>
            <Card title="Uptime">
              <div className="big">{duration(o.uptimeSeconds + (state.isStale ? 0 : now - polledAt))}</div>
              <p className="muted">{o.pendingUpdates === 0 ? "No pending updates" :
                `${o.pendingUpdates} update${o.pendingUpdates === 1 ? "" : "s"} pending, ${o.securityUpdates} security`}</p>
            </Card>
          </div>
          <div className="columns">
            <Card title="Disks">
              <ul className="disks">
                {o.disks.map((d) => (
                  <li key={d.mount}>
                    <div className="disk-line">
                      <span className="disk-mount">{d.mount}</span>
                      <span className="muted">{bytes(d.usedBytes)} of {bytes(d.totalBytes)} · {d.usePercent}%</span>
                    </div>
                    <Meter value={d.usePercent / 100} label={`${d.mount} used`} />
                    <span className="dim">{d.filesystem}</span>
                  </li>
                ))}
              </ul>
            </Card>
            <SystemInfo state={state} now={now} />
          </div>
        </>
      )}
      {trusting && (
        <HostKeyDialog server={props.server} onClose={(trusted) => {
          setTrusting(false);
          if (trusted) void refresh();
        }} />
      )}
    </div>
  );
}
