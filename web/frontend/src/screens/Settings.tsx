import { useEffect, useState, type FormEvent } from "react";
import { api, ApiError, setCsrf } from "../api";
import { HostKeyDialog } from "../components/HostKeyDialog";
import { Button, Card, CopyButton, Field, Modal, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import { destination } from "../format";
import type { Appearance, CheckResult, KeyInfo, Safety, Server, SSHConfigHost } from "../types";

const message = (e: unknown) => (e instanceof ApiError ? e.message : String(e));

function useKeys(): [KeyInfo[] | undefined, () => Promise<void>] {
  const [keys, setKeys] = useState<KeyInfo[]>();
  const load = async () => setKeys(await api.get<KeyInfo[]>("/api/keys"));
  useEffect(() => void load(), []);
  return [keys, load];
}

// --- servers ----------------------------------------------------------------------------------------------------

function ServerForm(props: { server?: Server; onSaved: (s: Server) => void; onCancel: () => void }) {
  const [keys] = useKeys();
  const s = props.server;
  const [name, setName] = useState(s?.name ?? "");
  const [host, setHost] = useState(s?.host ?? "");
  const [user, setUser] = useState(s?.user ?? "");
  const [port, setPort] = useState(s?.port ? String(s.port) : "");
  const [keyId, setKeyId] = useState(s?.keyId ?? "");
  const [error, setError] = useState<string>();
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const body = { name: name || host, host, user: user || null, port: port ? Number(port) : null, keyId: keyId || null };
    if (port && !/^\d+$/.test(port)) return setError("The port must be a number from 1 to 65535.");
    try {
      props.onSaved(s ? await api.put<Server>(`/api/servers/${s.id}`, body) : await api.post<Server>("/api/servers", body));
    } catch (err) {
      setError(message(err));
    }
  };
  return (
    <form className="form" onSubmit={(e) => void submit(e)}>
      <Field label="Name"><input value={name} onChange={(e) => setName(e.target.value)} placeholder={host || "homelab"} /></Field>
      <Field label="Host" hint="A hostname, an IP address or a Tailscale name.">
        <input value={host} onChange={(e) => setHost(e.target.value)} required autoCapitalize="off" spellCheck={false} />
      </Field>
      <div className="form-row">
        <Field label="User" hint="Blank means root."><input value={user} onChange={(e) => setUser(e.target.value)} autoCapitalize="off" spellCheck={false} /></Field>
        <Field label="Port" hint="Blank means 22."><input value={port} onChange={(e) => setPort(e.target.value)} inputMode="numeric" /></Field>
      </div>
      <Field label="Sign in with" hint={keyId ? "The key's public half must be in the server's ~/.ssh/authorized_keys." : "Tailscale SSH: no key, the tailnet identifies Rackoon's host."}>
        <select value={keyId} onChange={(e) => setKeyId(e.target.value)}>
          <option value="">Tailscale SSH (no key)</option>
          {keys?.map((k) => <option key={k.id} value={k.id}>{k.name} ({k.keyType})</option>)}
        </select>
      </Field>
      {error && <Notice tone="danger">{error}</Notice>}
      <div className="form-actions">
        <Button onClick={props.onCancel}>Cancel</Button>
        <Button kind="primary" type="submit">{s ? "Save" : "Add Server"}</Button>
      </div>
    </form>
  );
}

function ImportConfig(props: { onClose: () => void }) {
  const app = useApp();
  const [hosts, setHosts] = useState<SSHConfigHost[]>();
  const [error, setError] = useState<string>();
  const [chosen, setChosen] = useState<string[]>([]);
  const [notes, setNotes] = useState<string[]>();
  useEffect(() => {
    api.get<{ hosts: SSHConfigHost[] }>("/api/ssh-config").then((r) => setHosts(r.hosts), (e: unknown) => setError(message(e)));
  }, []);
  const run = async () => {
    try {
      const r = await api.post<{ added: Server[]; notes: string[] }>("/api/ssh-config/import", { aliases: chosen, importKeys: true });
      setNotes([`${r.added.length} server${r.added.length === 1 ? "" : "s"} added.`, ...r.notes]);
      await app.reloadServers();
    } catch (e) {
      setError(message(e));
    }
  };
  return (
    <Modal title="Import from ssh_config" onClose={props.onClose} wide
           footer={notes ? <Button kind="primary" onClick={props.onClose}>Done</Button> : (
             <><Button onClick={props.onClose}>Cancel</Button>
               <Button kind="primary" disabled={chosen.length === 0} onClick={() => void run()}>Import {chosen.length || ""}</Button></>)}>
      {error && <Notice tone="info" title="No ssh_config to read">{error} Mount your ~/.ssh read-only and set RACKOON_SSH_CONFIG to its config file.</Notice>}
      {!hosts && !error && <Spinner />}
      {notes && <ul className="notes">{notes.map((n) => <li key={n}>{n}</li>)}</ul>}
      {hosts && !notes && (
        <ul className="pick-list">
          {hosts.map((h) => (
            <li key={h.alias}>
              <label>
                <input type="checkbox" disabled={!h.supported || h.alreadyAdded} checked={chosen.includes(h.alias)}
                       onChange={(e) => setChosen(e.target.checked ? [...chosen, h.alias] : chosen.filter((a) => a !== h.alias))} />
                <strong>{h.alias}</strong>
                <span className="muted">{destination({ user: h.user ?? undefined, host: h.hostName ?? h.alias, port: h.port ?? undefined })}</span>
                {h.keyFile && <span className="badge">key {h.keyFile}</span>}
                {h.alreadyAdded && <span className="badge">added</span>}
              </label>
              {h.note && <div className="dim">{h.note}</div>}
            </li>
          ))}
        </ul>
      )}
    </Modal>
  );
}

function ServersTab(props: { sub?: string }) {
  const app = useApp();
  const [importing, setImporting] = useState(false);
  const [checking, setChecking] = useState<{ server: Server; result?: CheckResult }>();
  const [trusting, setTrusting] = useState<Server>();
  const [removing, setRemoving] = useState<Server>();
  const editing = props.sub === "new" ? "new" : app.servers.find((s) => s.id === props.sub);
  if (editing) {
    return (
      <Card title={editing === "new" ? "Add a server" : `Edit ${editing.name}`}>
        <ServerForm server={editing === "new" ? undefined : editing} onCancel={() => app.go("/settings/servers")}
                    onSaved={async (s) => {
                      await app.reloadServers();
                      app.go(`/servers/${s.id}`);
                    }} />
      </Card>
    );
  }
  const check = async (server: Server) => {
    setChecking({ server });
    const result = await api.post<CheckResult>(`/api/servers/${server.id}/check`);
    setChecking({ server, result });
  };
  return (
    <>
      <Card title="Servers" actions={<>
        <Button onClick={() => setImporting(true)}>Import from ssh_config…</Button>
        <a className="btn btn-primary" href="#/settings/servers/new">Add Server</a></>}>
        <ul className="rows">
          {app.servers.map((s) => (
            <li key={s.id} className="row">
              <div><strong>{s.name}</strong> <span className="muted">{destination(s)}</span>
                <div className="dim">{s.keyId ? "Signs in with a key" : "Tailscale SSH"}{s.sshConfigAlias ? ` · from ssh_config (${s.sshConfigAlias})` : ""}</div>
              </div>
              <div className="row-actions">
                <Button small onClick={() => void check(s)}>Check</Button>
                <Button small onClick={() => setTrusting(s)}>Host Key…</Button>
                <a className="btn btn-plain btn-small" href={`#/settings/servers/${s.id}`}>Edit…</a>
                <Button small kind="quiet" onClick={() => setRemoving(s)}>Remove…</Button>
              </div>
            </li>
          ))}
          {app.servers.length === 0 && <li className="muted">No servers yet.</li>}
        </ul>
      </Card>
      {importing && <ImportConfig onClose={() => setImporting(false)} />}
      {trusting && <HostKeyDialog server={trusting} onClose={() => setTrusting(undefined)} />}
      {checking && (
        <Modal title={`Check ${checking.server.name}`} onClose={() => setChecking(undefined)}
               footer={<Button kind="primary" onClick={() => setChecking(undefined)}>Close</Button>}>
          {!checking.result ? <Spinner /> : (
            <Notice tone={checking.result.status === "ok" ? "ok" : checking.result.status === "hostKeyUnknown" ? "info" : "danger"}
                    title={checking.result.status === "ok" ? "Connected and signed in." : checking.result.message}>
              {checking.result.hostKey && <p>Host key: <code>{checking.result.hostKey.fingerprint}</code></p>}
              {checking.result.status === "hostKeyUnknown" && <p>Use Host Key… to compare and trust it.</p>}
            </Notice>
          )}
        </Modal>
      )}
      {removing && (
        <Modal title={`Remove ${removing.name}?`} onClose={() => setRemoving(undefined)}
               footer={<><Button onClick={() => setRemoving(undefined)}>Cancel</Button>
                 <Button kind="danger" onClick={async () => {
                   await api.del(`/api/servers/${removing.id}`);
                   setRemoving(undefined);
                   await app.reloadServers();
                 }}>Remove</Button></>}>
          <p>Rackoon forgets this server and its cached reading. Nothing on the server changes, and its trusted host key stays.</p>
        </Modal>
      )}
    </>
  );
}

// --- keys -------------------------------------------------------------------------------------------------------

function KeysTab() {
  const [keys, reload] = useKeys();
  const [error, setError] = useState<string>();
  const [name, setName] = useState("");
  const [importing, setImporting] = useState(false);
  const [pem, setPem] = useState("");
  const [passphrase, setPassphrase] = useState("");
  const generate = async () => {
    try {
      await api.post("/api/keys/generate", { name: name || "rackoon" });
      setName("");
      await reload();
    } catch (e) {
      setError(message(e));
    }
  };
  const doImport = async () => {
    try {
      await api.post("/api/keys/import", { name: name || "imported", privateKey: pem, passphrase: passphrase || null });
      setImporting(false);
      setPem("");
      setPassphrase("");
      await reload();
    } catch (e) {
      setError(message(e));
    }
  };
  return (
    <Card title="SSH keys" actions={<>
      <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Key name" aria-label="Key name" />
      <Button onClick={() => void generate()}>Generate Ed25519</Button>
      <Button onClick={() => setImporting(true)}>Import…</Button></>}>
      <p className="muted">Keys live in Rackoon's data folder. Only the public half is ever shown: put it in a server's ~/.ssh/authorized_keys.</p>
      {error && <Notice tone="danger">{error}</Notice>}
      <ul className="rows">
        {keys?.map((k) => (
          <li key={k.id} className="row">
            <div>
              <strong>{k.name}</strong> <span className="muted">{k.keyType} · {k.source}</span>
              <div className="dim"><code>{k.fingerprint}</code></div>
              <pre className="pubkey">{k.publicKey}</pre>
            </div>
            <div className="row-actions">
              <CopyButton text={k.publicKey} label="public key" />
              <Button small kind="quiet" onClick={async () => {
                try {
                  await api.del(`/api/keys/${k.id}`);
                  await reload();
                } catch (e) {
                  setError(message(e));
                }
              }}>Delete</Button>
            </div>
          </li>
        ))}
        {keys?.length === 0 && <li className="muted">No keys yet. Servers without a key sign in with Tailscale SSH.</li>}
      </ul>
      {importing && (
        <Modal title="Import a private key" onClose={() => setImporting(false)} wide
               footer={<><Button onClick={() => setImporting(false)}>Cancel</Button><Button kind="primary" onClick={() => void doImport()}>Import</Button></>}>
          <Field label="Private key" hint="The file without .pub. An encrypted key needs its passphrase once; it is not kept.">
            <textarea rows={8} value={pem} onChange={(e) => setPem(e.target.value)} spellCheck={false} className="mono" />
          </Field>
          <Field label="Passphrase"><input type="password" value={passphrase} onChange={(e) => setPassphrase(e.target.value)} autoComplete="off" /></Field>
        </Modal>
      )}
    </Card>
  );
}

// --- account, appearance, safety --------------------------------------------------------------------------------

function AccountTab() {
  const app = useApp();
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [note, setNote] = useState<{ tone: "ok" | "danger"; text: string }>();
  const [totp, setTotp] = useState<{ secret: string; uri: string }>();
  const [code, setCode] = useState("");
  if (app.auth.via !== "session") {
    return <Card title="Account"><p className="muted">{app.auth.demo ? "The demo has no account." : `Signed in by your proxy as ${app.auth.user}.`}</p></Card>;
  }
  return (
    <>
      <Card title="Password">
        {app.auth.passwordManaged ? <p className="muted">Set by RACKOON_ADMIN_PASSWORD_FILE; change it there.</p> : (
          <form className="form" onSubmit={async (e) => {
            e.preventDefault();
            try {
              const r = await api.post<{ csrf: string }>("/api/auth/password", { current, new: next });
              setCsrf(r.csrf);
              setNote({ tone: "ok", text: "Password changed. Other browsers were signed out." });
              setCurrent("");
              setNext("");
            } catch (err) {
              setNote({ tone: "danger", text: message(err) });
            }
          }}>
            <Field label="Current password"><input type="password" value={current} onChange={(e) => setCurrent(e.target.value)} autoComplete="current-password" /></Field>
            <Field label="New password" hint="At least 12 characters."><input type="password" value={next} onChange={(e) => setNext(e.target.value)} autoComplete="new-password" /></Field>
            <div className="form-actions"><Button kind="primary" type="submit">Change Password</Button></div>
          </form>
        )}
        {note && <Notice tone={note.tone}>{note.text}</Notice>}
      </Card>
      <Card title="Two-step sign-in (TOTP)">
        {app.auth.totpEnabled ? <p>On. Signing in asks for a code from your authenticator app.</p> : totp ? (
          <form className="form" onSubmit={async (e) => {
            e.preventDefault();
            try {
              await api.post("/api/auth/totp/enable", { code });
              setNote({ tone: "ok", text: "Two-step sign-in is on." });
              setTotp(undefined);
              window.location.reload();
            } catch (err) {
              setNote({ tone: "danger", text: message(err) });
            }
          }}>
            <p>Add this secret to your authenticator app (or open the link on a phone that has one), then enter the code it shows.</p>
            <pre className="command">{totp.secret}</pre>
            <p><a href={totp.uri}>Open in authenticator</a></p>
            <Field label="Code"><input value={code} onChange={(e) => setCode(e.target.value)} inputMode="numeric" autoComplete="one-time-code" /></Field>
            <div className="form-actions"><Button kind="primary" type="submit">Turn On</Button></div>
          </form>
        ) : (
          <Button onClick={async () => setTotp(await api.post("/api/auth/totp/setup"))}>Set Up…</Button>
        )}
      </Card>
    </>
  );
}

function AppearanceTab() {
  const app = useApp();
  const a = app.appearance;
  if (!a) return <Spinner />;
  const choose = async (selection: string) => app.setAppearance(await api.put<Appearance>("/api/appearance", { selection }));
  const options = [{ id: "automatic", name: "Automatic", family: "Rackoon", appearance: "dark" as const }, ...a.themes];
  return (
    <Card title="Theme">
      <p className="muted">Automatic follows your browser's light or dark setting. Every theme's colours are adjusted to stay readable.</p>
      <div className="themes">
        {options.map((t) => (
          <button key={t.id} type="button" className={`theme-choice${a.selection === t.id ? " selected" : ""}`}
                  aria-pressed={a.selection === t.id} onClick={() => void choose(t.id)}>
            {t.name}
            <span className="dim">{t.id === "automatic" ? "Rackoon Dark / Light" : t.appearance}</span>
          </button>
        ))}
      </div>
    </Card>
  );
}

function SafetyTab() {
  const app = useApp();
  const s = app.safety;
  if (!s) return <Spinner />;
  return (
    <Card title="Read-only">
      <p>While Read-only is on, nothing that changes a server can run. Every change shows the exact command first, either way.</p>
      <Field label="Turn Read-only back on">
        <select value={s.auto} onChange={async (e) => app.setSafety(await api.put<Safety>("/api/safety", { auto: e.target.value }))}>
          {s.options.map((o) => <option key={o.key} value={o.key}>{o.label}</option>)}
        </select>
      </Field>
    </Card>
  );
}

const TABS: [string, string][] = [["servers", "Servers"], ["keys", "Keys"], ["account", "Account"], ["appearance", "Appearance"], ["safety", "Safety"]];

export function SettingsScreen(props: { tab: string; sub?: string }) {
  return (
    <div className="page">
      <header className="page-head"><h1>Settings</h1></header>
      <nav className="tabs" aria-label="Settings">
        {TABS.map(([id, label]) => (
          <a key={id} href={`#/settings/${id}`} className={`tab${props.tab === id ? " active" : ""}`}
             aria-current={props.tab === id ? "page" : undefined}>{label}</a>
        ))}
      </nav>
      {props.tab === "servers" && <ServersTab sub={props.sub} />}
      {props.tab === "keys" && <KeysTab />}
      {props.tab === "account" && <AccountTab />}
      {props.tab === "appearance" && <AppearanceTab />}
      {props.tab === "safety" && <SafetyTab />}
    </div>
  );
}
