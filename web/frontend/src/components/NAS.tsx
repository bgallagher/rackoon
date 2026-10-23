// An Unraid server's Overview: the array, parity, every disk, pools, flash, temperatures and fans, the last parity
// checks and the shares. Read every 12 s while it shows, from what Unraid already wrote (no drive spins up).
import { api } from "../api";
import { bytes, duration, percent } from "../format";
import { usePoll } from "../hooks";
import { Card, Meter, Notice, Spinner } from "./ui";

interface Fs { totalBytes: number; usedBytes: number; freeBytes: number; usePercent?: number; type: string }
interface Disk { name: string; title: string; model: string; statusText: string; temperature: number | null;
  temperatureLevel: string; spunDown: boolean; errors: number; emptySlot: boolean; filesystem: Fs | null;
  fillLevel: string | null; sizeBytes: number; rotational: boolean }
interface NAS {
  version: string; cpuModel: string; condition: { title: string; level: string };
  array: { totalBytes: number; usedBytes: number; freeBytes: number; state: string };
  operation: { label: string; fraction: number; remainingSeconds: number | null; bytesPerSecond: number | null } | null;
  parity: Disk[]; data: Disk[]; flash: Disk | null;
  pools: { name: string; title: string; kind: string | null; health: string | null; filesystem: Fs | null; devices: Disk[] }[];
  cpuTemperature: number | null; cpuLevel: string | null; sensors: { name: string; celsius: number }[];
  fans: { label: string; value: number }[];
  parityChecks: { finished: string; durationSeconds: number; errors: number; label: string; completed: boolean }[];
  shares: { name: string; comment: string; freeBytes: number; placement: string }[];
}

const tone = (level: string | null) => (level === "critical" ? "danger" : level === "warning" ? "warn" : "ok");

function DiskRow(props: { d: Disk }) {
  const d = props.d;
  const fs = d.filesystem;
  return (
    <tr>
      <td><strong>{d.title}</strong><div className="dim">{d.model}</div></td>
      <td><span className={`dot dot-${d.statusText === "healthy" ? "ok" : "danger"}`} /> {d.statusText}{d.errors > 0 && <span className="badge badge-warn">{d.errors} errors</span>}</td>
      <td className={`level-${tone(d.temperatureLevel)}`}>{d.spunDown ? "spun down" : d.temperature != null ? `${d.temperature} °C` : "—"}</td>
      <td>{fs ? <><Meter value={fs.totalBytes ? fs.usedBytes / fs.totalBytes : 0} label={`${d.title} used`} />
        <span className="dim">{bytes(fs.usedBytes)} of {bytes(fs.totalBytes)}</span></> : bytes(d.sizeBytes)}</td>
    </tr>
  );
}

export function NASOverview(props: { serverId: string }) {
  const { data, error } = usePoll(() => api.get<{ status: string; error: string | null; nas: NAS | null }>(
    `/api/servers/${props.serverId}/nas`), 12_000, [props.serverId]);
  if (!data) return error ? <Notice tone="danger">{error}</Notice> : <Spinner />;
  if (!data.nas) return <Notice tone="danger" title="The NAS couldn't be read"><p className="raw">{data.error}</p></Notice>;
  const n = data.nas;
  const used = n.array.totalBytes ? n.array.usedBytes / n.array.totalBytes : 0;
  return (
    <>
      <div className="tiles">
        <Card title="Array">
          <div className={`big level-${tone(n.condition.level)}`}>{n.condition.title}</div>
          <Meter value={used} label="Array used" />
          <p className="muted">{bytes(n.array.usedBytes)} of {bytes(n.array.totalBytes)} · {bytes(n.array.freeBytes)} free</p>
        </Card>
        {n.cpuTemperature != null && (
          <Card title="CPU">
            <div className={`big level-${tone(n.cpuLevel)}`}>{Math.round(n.cpuTemperature)} °C</div>
            <p className="muted">{n.cpuModel}</p>
          </Card>
        )}
        {n.pools.map((p) => (
          <Card key={p.name} title={p.title}>
            <div className="big">{p.filesystem ? percent(p.filesystem.totalBytes ? p.filesystem.usedBytes / p.filesystem.totalBytes * 100 : 0) : "—"}</div>
            {p.filesystem && <Meter value={p.filesystem.totalBytes ? p.filesystem.usedBytes / p.filesystem.totalBytes : 0} label={`${p.title} used`} />}
            <p className="muted">{p.kind}{p.health && ` · ${p.health}`}</p>
          </Card>
        ))}
      </div>
      {n.operation && (
        <Notice tone="info" title={`${n.operation.label}: ${percent(n.operation.fraction * 100)}`}>
          <Meter value={n.operation.fraction} label={n.operation.label} />
          <p>{n.operation.bytesPerSecond ? `${bytes(n.operation.bytesPerSecond)}/s` : "paused"}
            {n.operation.remainingSeconds != null && ` · about ${duration(n.operation.remainingSeconds)} left`}</p>
        </Notice>
      )}
      <Card title="Disks">
        <div className="health-wrap">
          <table className="health">
            <thead><tr><th>Disk</th><th>Status</th><th>Temp</th><th>Used</th></tr></thead>
            <tbody>
              {[...n.parity, ...n.data, ...n.pools.flatMap((p) => p.devices), ...(n.flash ? [n.flash] : [])].map((d) => <DiskRow key={d.name} d={d} />)}
            </tbody>
          </table>
        </div>
      </Card>
      <div className="columns">
        {(n.sensors.length > 0 || n.fans.length > 0) && (
          <Card title="Temperatures and fans">
            <dl className="facts">
              {n.sensors.map((s) => <div key={s.name}><dt>{s.name}</dt><dd>{Math.round(s.celsius)} °C</dd></div>)}
              {n.fans.map((f) => <div key={f.label}><dt>{f.label || "Fan"}</dt><dd>{Math.round(f.value)} RPM</dd></div>)}
            </dl>
          </Card>
        )}
        {n.parityChecks.length > 0 && (
          <Card title="Parity checks">
            <ul className="rows">
              {n.parityChecks.slice(0, 5).map((p) => (
                <li key={p.finished} className="row"><div><strong>{p.label}</strong><div className="dim">{p.finished} · {duration(p.durationSeconds)}</div></div>
                  <span className={p.completed ? (p.errors ? "badge badge-warn" : "badge") : "badge badge-danger"}>
                    {p.completed ? `${p.errors} errors` : "cancelled"}</span></li>
              ))}
            </ul>
          </Card>
        )}
      </div>
      {n.shares.length > 0 && (
        <Card title="Shares">
          <ul className="rows">
            {n.shares.map((s) => (
              <li key={s.name} className="row"><div><strong>{s.name}</strong><div className="dim">{s.comment || s.placement}</div></div>
                <span className="dim">{bytes(s.freeBytes)} free · {s.placement}</span></li>
            ))}
          </ul>
        </Card>
      )}
      <p className="dim">Unraid {n.version}. Share sizes are not read: Unraid only works them out on request.</p>
    </>
  );
}
