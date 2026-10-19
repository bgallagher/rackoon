// Alerts: everything that needs you, per server or across every server, with a week of history. Seen alerts stop
// counting, muted ones never count or notify. Delivery (Web Push to this browser, ntfy, a webhook) is set up below.
import { useState } from "react";
import { api } from "../api";
import { errorText, stackRoute } from "../components/docker";
import { Button, Card, Empty, Field, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import { ago } from "../format";
import { useNow, usePoll } from "../hooks";
import type { Alert, AlertsState, NotificationSettings } from "../types";

export function fixRoute(a: Alert): string {
  const s = `/servers/${a.serverId}`;
  const t = a.fix?.target;
  switch (a.fix?.screen) {
    case "docker": return t ? stackRoute(a.serverId, t) : `${s}/docker`;
    case "services": return `${s}/services${t ? `/${encodeURIComponent(t)}` : ""}`;
    case "updates": return `${s}/updates`;
    case "bookmarks": return `${s}/bookmarks`;
    default: return s;
  }
}

function Row(props: { a: Alert; now: number; fleet: boolean; onChanged: () => void }) {
  const { a } = props;
  const act = async (path: string, body: unknown) => {
    await api.post(`/api/alerts/${encodeURIComponent(a.id)}/${path}`, body);
    props.onChanged();
  };
  const tone = a.severity === "critical" ? "danger" : a.severity === "warning" ? "warn" : "idle";
  return (
    <li className={`alert-row${a.acknowledged ? " seen" : ""}`}>
      <span className={`dot dot-${a.resolvedAt ? "ok" : tone}`} />
      <div className="alert-text">
        <a href={`#${fixRoute(a)}`}><strong>{a.title}</strong></a>
        <span className="dim">{props.fleet && <>{a.serverName} · </>}{a.detail}</span>
        <span className="dim">{a.resolvedAt ? `resolved ${ago(a.resolvedAt, props.now)}` :
          `since ${ago(a.firstSeen, props.now)}`}{a.lastSeen !== a.firstSeen && !a.resolvedAt && ` · seen ${ago(a.lastSeen, props.now)}`}</span>
      </div>
      {!a.resolvedAt && (
        <div className="row-actions">
          {!a.muted && <Button small onClick={() => void act("seen", { seen: !a.acknowledged })}>{a.acknowledged ? "Unsee" : "Seen"}</Button>}
          <Button small kind="quiet" onClick={() => void act("mute", { on: !a.muted })}>{a.muted ? "Unmute" : "Mute"}</Button>
        </div>
      )}
    </li>
  );
}

export function AlertsView(props: { serverId?: string; title?: string }) {
  const now = useNow();
  const q = props.serverId ? `?server=${props.serverId}` : "";
  const { data, error, reload } = usePoll(() => api.get<AlertsState>(`/api/alerts${q}`), 15_000, [props.serverId]);
  const [checking, setChecking] = useState(false);
  if (!data) return error ? <Notice tone="danger">{error}</Notice> : <Spinner />;
  const fleet = !props.serverId;
  const check = async () => {
    setChecking(true);
    try {
      await api.post("/api/alerts/check", { serverId: props.serverId ?? null });
      await reload();
    } finally {
      setChecking(false);
    }
  };
  return (
    <>
      <div className="card-actions">
        <span className="muted">{data.unseen} unseen · last checked {ago(data.lastSweep, now)}</span>
        <Button disabled={checking || data.sweeping} onClick={() => void check()}>{checking ? "Checking…" : "Check Now"}</Button>
        {data.unseen > 0 && <Button onClick={() => void api.post("/api/alerts/seen-all", { serverId: props.serverId ?? null }).then(reload)}>Mark All Seen</Button>}
      </div>
      {data.notifications.lastError && <Notice tone="warn" title="The last notification didn't go out">{data.notifications.lastError}</Notice>}
      {data.active.length === 0 ? <Empty title="Nothing needs you right now" /> : (
        <Card title="Active">
          <ul className="alerts">{data.active.map((a) => <Row key={a.id} a={a} now={now} fleet={fleet} onChanged={() => void reload()} />)}</ul>
        </Card>
      )}
      {data.muted.length > 0 && (
        <Card title="Muted">
          <ul className="alerts">{data.muted.map((a) => <Row key={a.id} a={a} now={now} fleet={fleet} onChanged={() => void reload()} />)}</ul>
        </Card>
      )}
      {data.history.length > 0 && (
        <Card title="Resolved (last 7 days)" actions={
          <Button small onClick={() => void api.post("/api/alerts/clear-history", { serverId: props.serverId ?? null }).then(reload)}>Clear</Button>}>
          <ul className="alerts">{data.history.map((a) => <Row key={a.id} a={a} now={now} fleet={fleet} onChanged={() => void reload()} />)}</ul>
        </Card>
      )}
    </>
  );
}

export function AlertsScreen(props: { serverId: string }) {
  const app = useApp();
  const server = app.servers.find((s) => s.id === props.serverId);
  return (
    <div className="page">
      <header className="page-head"><div><h1>Alerts</h1><p className="muted">{server?.name}: everything that needs you.
        Notifications are set up in <a href="#/settings/notifications">Settings</a>.</p></div></header>
      <AlertsView serverId={props.serverId} />
    </div>
  );
}

function b64ToBytes(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

/** Web Push for this browser: a service worker shows the notifications even when no Rackoon tab is open. */
async function enablePush(): Promise<string | null> {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) return "This browser can't receive push notifications.";
  if (!window.isSecureContext) return "Push notifications need Rackoon over HTTPS (or on localhost).";
  const permission = await Notification.requestPermission();
  if (permission !== "granted") return "Notifications are blocked for this site in the browser's settings.";
  const reg = await navigator.serviceWorker.register("/sw.js");
  await navigator.serviceWorker.ready;
  const { publicKey } = await api.get<{ publicKey: string }>("/api/notifications/push/key");
  const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(publicKey) });
  await api.post("/api/notifications/push/subscribe", sub.toJSON());
  return null;
}

async function disablePush(): Promise<void> {
  const reg = await navigator.serviceWorker?.getRegistration("/sw.js");
  const sub = await reg?.pushManager.getSubscription();
  if (sub) {
    await api.post("/api/notifications/push/unsubscribe", { endpoint: sub.endpoint });
    await sub.unsubscribe();
  }
}

export function NotificationsSettings() {
  const { data, reload } = usePoll(() => api.get<NotificationSettings>("/api/notifications"), 60_000, []);
  const [form, setForm] = useState<Record<string, string>>({});
  const [message, setMessage] = useState<{ tone: "ok" | "danger"; text: string }>();
  if (!data) return <Spinner />;
  const value = (k: keyof NotificationSettings) => form[k] ?? String(data[k] ?? "");
  const save = async (patch: Record<string, unknown>) => {
    try {
      await api.put("/api/notifications", patch);
      setForm({});
      await reload();
      setMessage({ tone: "ok", text: "Saved." });
    } catch (e) {
      setMessage({ tone: "danger", text: errorText(e) });
    }
  };
  const test = async () => {
    const r = await api.post<{ ok: boolean; problems: string[] }>("/api/notifications/test");
    setMessage(r.ok ? { tone: "ok", text: "Sent. Check each place it should arrive." } : { tone: "danger", text: r.problems.join("; ") });
  };
  return (
    <div className="form">
      <label className="check">
        <input type="checkbox" checked={data.enabled} onChange={(e) => void save({ enabled: e.target.checked })} />
        <span>Send notifications for new warnings and critical alerts (never for what is already wrong when a server is
          first checked, never for muted ones)</span>
      </label>
      <Card title="This browser">
        <p className="muted">{data.pushSubscriptions} browser{data.pushSubscriptions === 1 ? "" : "s"} subscribed to Web Push.</p>
        <div className="form-actions">
          <Button onClick={() => void disablePush().then(reload)}>Turn Off Here</Button>
          <Button kind="primary" onClick={() => void enablePush().then((p) => { if (p) setMessage({ tone: "danger", text: p }); return reload(); })}>
            Notify This Browser</Button>
        </div>
      </Card>
      <Card title="ntfy">
        <Field label="Topic address" hint="https://ntfy.sh/your-secret-topic, or your own ntfy server">
          <input value={value("ntfyUrl")} onChange={(e) => setForm({ ...form, ntfyUrl: e.target.value })} spellCheck={false} />
        </Field>
        <Field label="Access token" hint={data.hasNtfyToken ? "A token is saved. Type a new one to replace it." : "Only for protected topics"}>
          <input type="password" value={form.ntfyToken ?? ""} onChange={(e) => setForm({ ...form, ntfyToken: e.target.value })} autoComplete="off" />
        </Field>
      </Card>
      <Card title="Webhook">
        <Field label="Address" hint="Each alert is POSTed as JSON">
          <input value={value("webhookUrl")} onChange={(e) => setForm({ ...form, webhookUrl: e.target.value })} spellCheck={false} />
        </Field>
        <Field label="Signing secret" hint={data.hasWebhookSecret ? "A secret is saved: requests carry X-Rackoon-Signature: sha256=…" : "Optional: adds an HMAC-SHA256 signature header"}>
          <input type="password" value={form.webhookSecret ?? ""} onChange={(e) => setForm({ ...form, webhookSecret: e.target.value })} autoComplete="off" />
        </Field>
      </Card>
      <Field label="Rackoon's address" hint="Optional: where links in ntfy and webhook messages point">
        <input value={value("publicUrl")} onChange={(e) => setForm({ ...form, publicUrl: e.target.value })} spellCheck={false}
               placeholder="https://rackoon.your-tailnet.ts.net" />
      </Field>
      {message && <Notice tone={message.tone}>{message.text}</Notice>}
      <div className="form-actions">
        <Button onClick={() => void test()}>Send a Test</Button>
        <Button kind="primary" disabled={Object.keys(form).length === 0} onClick={() => void save(form)}>Save</Button>
      </div>
    </div>
  );
}
