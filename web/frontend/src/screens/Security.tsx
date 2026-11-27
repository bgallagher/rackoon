// Security (docs/security-plan.md): a verdict with the disclaimer under it, what to fix, what other networks can reach,
// the opt-in vulnerability lookup, what is worth knowing, what could not be checked and the passed checks folded away.
// Advice only: nothing here changes the server. Check Deeper runs the same read-only checks as root, only when asked.
import { useState } from "react";
import { api, ApiError } from "../api";
import { PasswordSheet } from "../components/root";
import { Button, Notice, Spinner } from "../components/ui";
import { ago } from "../format";
import { useNow, usePoll } from "../hooks";
import type { SecurityFinding, SecurityPort, SecurityState, Server, VulnerabilityFinding } from "../types";

const SHOWN_AS_PORTS = new Set(["exposure.listening", "exposure.sensitive_port", "exposure.docker_bypass"]);
const ORDER: Record<string, number> = { critical: 0, warning: 1, info: 2, unknown: 3, pass: 4 };
const ICON: Record<string, string> = { critical: "✕", warning: "!", info: "i", unknown: "?", pass: "✓" };
const TONE: Record<string, string> = { critical: "danger", warning: "warn", info: "idle", unknown: "idle", pass: "ok" };
const SCOPE: Record<string, string> = { all: "Every interface", public: "Public address", lan: "Local network",
  tailscale: "Tailscale only", loopback: "This server only" };
const FLAG_WHY: Record<string, string> = {
  "past ufw": "Docker writes its own firewall rules ahead of ufw's, so this port is open even if ufw denies it.",
  "database or cache": "Databases and caches are often reachable without a password. Bind it to 127.0.0.1.",
  "no TLS": "Docker's API without TLS: anyone who reaches it controls the server as root.",
};
const STATUS_TITLE: Record<string, string> = { fix_waiting: "Fix waiting in the updates",
  fix_released: "Fixed upstream: refresh the package lists", no_fix: "No fix released yet" };

function sorted(list: SecurityFinding[]): SecurityFinding[] {
  return [...list].sort((a, b) => (ORDER[a.severity] ?? 9) - (ORDER[b.severity] ?? 9) || a.id.localeCompare(b.id));
}

export function SecurityScreen(props: { server: Server }) {
  const now = useNow();
  const base = `/api/servers/${props.server.id}`;
  const { data, error, setData } = usePoll(() => api.get<SecurityState>(`${base}/security`), 60_000, [props.server.id]);
  const [busy, setBusy] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [asking, setAsking] = useState<{ error: string | null } | null>(null);
  const [showPassed, setShowPassed] = useState(false);
  const [showLocal, setShowLocal] = useState(false);

  const call = async (label: string, load: () => Promise<SecurityState>) => {
    setBusy(label);
    setProblem(null);
    try {
      setData(await load());
    } catch (e) {
      setProblem(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };
  const checkNow = () => call("check", async () => {
    const page = await api.get<SecurityState>(`${base}/security?refresh=true`);
    return page.vulnerabilities.enabled ? api.post<SecurityState>(`${base}/security/vulnerabilities`) : page;
  });
  const deeper = async (password?: string) => {
    setBusy("deeper");
    try {
      setData(await api.post<SecurityState>(`${base}/security/deeper`, password ? { password } : {}));
      setAsking(null);
    } catch (e) {
      if (e instanceof ApiError && e.code === "needsPassword") setAsking({ error: null });
      else if (e instanceof ApiError && e.code === "badPassword") setAsking({ error: e.message });
      else { setAsking(null); setProblem(e instanceof Error ? e.message : String(e)); }
    } finally {
      setBusy(null);
    }
  };
  const setLookup = (serverId: string | null, enabled: boolean) => call("lookup", async () => {
    await api.put("/api/security/vulnerabilities", { serverId, enabled });
    return enabled ? api.post<SecurityState>(`${base}/security/vulnerabilities`) : api.get<SecurityState>(`${base}/security`);
  });

  if (!data) return <div className="page">{error ? <Notice tone="danger">{error}</Notice> : <Spinner />}</div>;
  const findings = data.findings.filter((f) => !SHOWN_AS_PORTS.has(f.check));
  const toFix = sorted(findings.filter((f) => f.severity === "critical" || f.severity === "warning"));
  const open = data.ports.filter((p) => p.scope === "all" || p.scope === "public");
  const local = data.ports.filter((p) => !(p.scope === "all" || p.scope === "public"));
  const flagged = open.filter((p) => p.flags.some((f) => f !== "no TLS")).length;
  const parts = [toFix.length ? `${toFix.length} thing${toFix.length === 1 ? "" : "s"} to fix` : null,
    flagged ? `${flagged} open port${flagged === 1 ? "" : "s"} to look at` : null].filter(Boolean);
  const tone = parts.length === 0 ? "ok" : toFix.some((f) => f.severity === "critical") ? "danger" : "warn";
  const info = sorted(findings.filter((f) => f.severity === "info"));
  const unknown = sorted(findings.filter((f) => f.severity === "unknown"));
  const passed = sorted(findings.filter((f) => f.severity === "pass"));
  return (
    <div className="page security-page">
      <header className="page-head">
        <div>
          <h1>Security</h1>
          <p className="muted">{data.updatedAt ? `Checked ${ago(data.updatedAt, now)}${data.deep ? " with sudo" : ""}` : "Not checked yet"}</p>
        </div>
        <div className="row-gap">
          {data.isRoot === false && (
            <Button onClick={() => void deeper()} disabled={busy !== null}
                    title="Run the same read-only checks as root: sshd's settings in use, every container and /etc/shadow. Nothing on the server is changed.">
              {busy === "deeper" ? "Checking…" : "Check Deeper with sudo…"}</Button>
          )}
          <Button onClick={() => void checkNow()} disabled={busy !== null}>{busy === "check" ? "Checking…" : "Check Now"}</Button>
        </div>
      </header>
      {data.error && <Notice tone="danger" title="The check failed"><p className="raw">{data.error}</p></Notice>}
      {problem && <Notice tone="danger">{problem}</Notice>}
      {data.status === "ready" && (
        <>
          <Notice tone={tone as "ok" | "warn" | "danger"} title={parts.length ? parts.join(", ") : "Nothing obvious to fix"}>
            <p className="dim">{data.disclaimer}</p>
          </Notice>
          {toFix.length > 0 && <FindingSection title="To fix" list={toFix} />}
          {data.ports.length > 0 && (
            <section className="security-section">
              <h2>Reachable from other networks <span className="dim">{open.length}</span></h2>
              <p className="dim">{open.length ? "Listening on every interface: any network the server is on can connect, unless a firewall stops it." : "Nothing listens on every interface."}</p>
              <ul className="security-list">
                {open.map((p) => <PortRow key={p.id} port={p} />)}
                {local.length > 0 && (
                  <li><button className="link" onClick={() => setShowLocal(!showLocal)}>
                    {showLocal ? "Hide" : "Show"} {local.length} more only this server, the local network or Tailscale can reach</button></li>
                )}
                {showLocal && local.map((p) => <PortRow key={p.id} port={p} />)}
              </ul>
            </section>
          )}
          <Vulnerabilities state={data} busy={busy} onLookup={setLookup}
                           onAgain={() => void call("lookup", () => api.post<SecurityState>(`${base}/security/vulnerabilities`))}
                           updatesHref={`#/servers/${props.server.id}/updates`} />
          {info.length > 0 && <FindingSection title="Worth knowing" list={info} />}
          {unknown.length > 0 && (
            <FindingSection title="Could not check" list={unknown}
                            note={`Rackoon reads as ${data.isRoot ? "root" : `${data.user ?? "the ssh user"}, without sudo`}; these need more access, so they are not counted as passed.`} />
          )}
          {passed.length > 0 && (
            <section className="security-section">
              <button className="link" onClick={() => setShowPassed(!showPassed)}>✓ {passed.length} checks passed · {showPassed ? "Hide" : "Show"}</button>
              {showPassed && <ul className="security-passed">{passed.map((f) => (
                <li key={f.id} title={f.evidence ?? ""}><strong>{f.title}</strong><span className="dim">{f.summary}</span></li>))}</ul>}
            </section>
          )}
        </>
      )}
      {data.status === "loading" && <Spinner />}
      {asking && (
        <PasswordSheet server={props.server} error={asking.error}
                       why="Run the Security checks as root once, so sshd's settings in use, every container and /etc/shadow can be read. Nothing on the server is changed."
                       onSubmit={(pw) => void deeper(pw)} onCancel={() => setAsking(null)} />
      )}
    </div>
  );
}

function FindingSection(props: { title: string; list: SecurityFinding[]; note?: string }) {
  return (
    <section className="security-section">
      <h2>{props.title} <span className="dim">{props.list.length}</span></h2>
      {props.note && <p className="dim">{props.note}</p>}
      <ul className="security-list">{props.list.map((f) => <FindingRow key={f.id} finding={f} />)}</ul>
    </section>
  );
}

function FindingRow(props: { finding: SecurityFinding }) {
  const f = props.finding;
  return (
    <li>
      <details className="security-row">
        <summary>
          <span className={`sev sev-${TONE[f.severity]}`} aria-label={f.severity}>{ICON[f.severity]}</span>
          <span title={f.title}>{f.summary}</span>
        </summary>
        <dl className="security-detail">
          <dt>Why it matters</dt><dd>{f.why}</dd>
          <dt>What you can do</dt><dd>{f.advice}</dd>
          {f.evidence && <><dt>What Rackoon read</dt><dd className="mono">{f.evidence}</dd></>}
        </dl>
      </details>
    </li>
  );
}

function PortRow(props: { port: SecurityPort }) {
  const p = props.port;
  const what = [p.service, p.containers.length ? `Docker: ${p.containers.join(", ")}` : null].filter(Boolean).join(" · ") || "Unknown service";
  return (
    <li className="security-port">
      <span className="mono">{p.port}/{p.proto}</span>
      <span><span>{what}</span><span className="dim">{SCOPE[p.scope]} · {p.addresses.join(", ")}</span></span>
      <span>{p.flags.map((f) => <span key={f} className="badge badge-warn" title={FLAG_WHY[f] ?? ""}>{f}</span>)}</span>
    </li>
  );
}

function Vulnerabilities(props: { state: SecurityState; busy: string | null; updatesHref: string;
  onLookup: (serverId: string | null, enabled: boolean) => void; onAgain: () => void }) {
  const v = props.state.vulnerabilities;
  const id = props.state.serverId;
  const [all, setAll] = useState<Set<string>>(new Set());
  return (
    <section className="security-section">
      <h2>Known vulnerabilities {v.enabled && v.findings && <span className="dim">{v.findings.length}</span>}</h2>
      {!v.enabled ? (
        <div className="card">
          <p><strong>Look up known vulnerabilities (CVEs) in this server's installed packages.</strong></p>
          <p className="dim">{v.privacyNote}</p>
          <div className="row-gap">
            <Button onClick={() => props.onLookup(id, true)} disabled={props.busy !== null}>Turn On for This Server</Button>
            <Button onClick={() => props.onLookup(null, true)} disabled={props.busy !== null}>Turn On for All Servers</Button>
          </div>
        </div>
      ) : (
        <div className="card">
          {!v.supported ? <p className="dim">The lookup supports Debian and Ubuntu releases; this server is neither (or has no release number).</p>
            : v.error ? <Notice tone="warn">Could not look up vulnerabilities: {v.error}</Notice>
            : v.findings === null ? (props.busy === "lookup" || v.running ? <p className="dim"><Spinner /> Asking OSV.dev…</p>
              : <Button onClick={props.onAgain}>Look Up Now</Button>)
            : (
              <>
                <p><strong>{v.findings.length === 0 ? "OSV.dev knows no vulnerabilities in these package versions." : summary(v.findings)}</strong></p>
                <p className="dim">{v.limits}</p>
                {(["fix_waiting", "fix_released", "no_fix"] as const).map((status) => {
                  const group = v.findings!.filter((f) => f.status === status);
                  if (!group.length) return null;
                  const shown = all.has(status) ? group : group.slice(0, 12);
                  return (
                    <div key={status} className="vuln-group">
                      <h3>{STATUS_TITLE[status]} {status === "fix_waiting" && <a href={props.updatesHref}>Updates →</a>}</h3>
                      <ul className="security-list">{shown.map((f) => <VulnRow key={`${f.package}|${f.id}`} f={f} />)}</ul>
                      {group.length > shown.length && <button className="link" onClick={() => setAll(new Set([...all, status]))}>Show all {group.length}</button>}
                    </div>
                  );
                })}
              </>
            )}
          <div className="row-gap">
            {v.findings !== null && <Button small onClick={props.onAgain} disabled={props.busy !== null}>Look Up Again</Button>}
            {v.thisServer && <Button small kind="quiet" onClick={() => props.onLookup(id, false)}>Turn Off for This Server</Button>}
            {v.all && <Button small kind="quiet" onClick={() => props.onLookup(null, false)}>Turn Off for All Servers</Button>}
          </div>
        </div>
      )}
    </section>
  );
}

function summary(list: VulnerabilityFinding[]): string {
  const n = (s: string) => list.filter((f) => f.status === s).length;
  return [n("fix_waiting") ? `${n("fix_waiting")} fixed by the waiting updates` : null,
    n("fix_released") ? `${n("fix_released")} fixed upstream, not in the package lists yet` : null,
    n("no_fix") ? `${n("no_fix")} with no fix released` : null].filter(Boolean).join(" · ");
}

function VulnRow(props: { f: VulnerabilityFinding }) {
  const f = props.f;
  const tone = ["critical", "high"].includes(f.severity) ? "badge-danger" : f.severity === "medium" ? "badge-warn" : "";
  return (
    <li>
      <details className="security-row">
        <summary>
          <span className={`badge ${tone}`}>{f.severity}</span>
          <span className="mono">{f.id}</span> <strong>{f.package}</strong>
          <span className="dim mono">{f.installed}{f.fixed ? ` → ${f.fixed}` : ""}</span>
        </summary>
        <div className="security-detail">
          {f.summary && <p>{f.summary}</p>}
          {f.aliases.length > 0 && <p className="dim">Also known as {f.aliases.join(", ")}</p>}
          <p className="dim">Installed from source package {f.package}: {f.binaries.join(", ")}</p>
          <a href={`https://osv.dev/vulnerability/${encodeURIComponent(f.id)}`} target="_blank" rel="noreferrer noopener">Open on osv.dev</a>
        </div>
      </details>
    </li>
  );
}
