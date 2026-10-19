// Root actions that may need the sudo password: the password sheet, the reboot flow (plain, then with the password
// when sudo wants one) and the banner that follows a reboot until the server is back with a new boot id.
import { useEffect, useState, type ReactNode } from "react";
import { api } from "../api";
import type { PendingAction, RebootState, Server } from "../types";
import { ConfirmSheet } from "./ConfirmSheet";
import { errorText } from "./docker";
import { Button, Modal, Notice, Spinner } from "./ui";
import { useApp } from "../context";

/** Asks for the sudo password. It goes to the backend once, for this one action (or, for Docker, for 15 minutes in
 * memory), and is never shown again. A password manager can fill it. */
export function PasswordSheet(props: {
  server: Server;
  why: string;
  error?: string | null;
  holds?: boolean;
  onSubmit: (password: string) => void;
  onCancel: () => void;
}) {
  const app = useApp();
  const [password, setPassword] = useState("");
  return (
    <Modal title={`sudo password for ${props.server.user ?? "root"}@${props.server.host}`} onClose={props.onCancel}
           footer={<>
             <Button onClick={props.onCancel}>Cancel</Button>
             <Button kind="primary" type="submit" disabled={!password} onClick={() => props.onSubmit(password)}>Continue…</Button>
           </>}>
      <p>{props.why}</p>
      <form onSubmit={(e) => { e.preventDefault(); if (password) props.onSubmit(password); }}>
        <input type="password" autoComplete="current-password" value={password} aria-label="sudo password"
               onChange={(e) => setPassword(e.target.value)} />
      </form>
      <p className="dim">{props.holds
        ? "Rackoon keeps it in memory for 15 minutes (or until you lock, edit or remove the server), never on disk."
        : "It is typed at sudo's own prompt (or handed to sudo -S) for this one action, and not kept."}</p>
      {app.auth.demo && <p className="dim">Demo: the password is <span className="mono">demo</span>.</p>}
      {props.error && <Notice tone="danger">{props.error}</Notice>}
    </Modal>
  );
}

/** Reboot: confirm the plain one; if sudo wants a password, ask for it and confirm the password variant. */
export function useReboot(server: Server, onStarted: () => void): { request: () => void; sheets: ReactNode; error?: string } {
  const [pending, setPending] = useState<PendingAction>();
  const [asking, setAsking] = useState<{ error: string | null }>();
  const [error, setError] = useState<string>();
  const propose = async (password?: string) => {
    setError(undefined);
    try {
      const r = await api.post<{ pending: PendingAction }>(`/api/servers/${server.id}/reboot`, password ? { password } : {});
      setPending(r.pending);
    } catch (e) {
      setError(errorText(e));
    }
  };
  const done = (result: unknown) => {
    setPending(undefined);
    const r = result as { outcome: string; message?: string };
    if (r.outcome === "rebooting") {
      setAsking(undefined);
      onStarted();
    } else if (r.outcome === "noSudo") {
      setAsking({ error: null });
    } else if (r.outcome === "badPassword") {
      setAsking({ error: r.message ?? "The server did not accept that password." });
    } else {
      setAsking(undefined);
      setError(r.message ?? "The reboot did not start.");
    }
  };
  const sheets = (
    <>
      {pending && <ConfirmSheet action={pending} onCancel={() => setPending(undefined)} onDone={done} />}
      {asking && !pending && (
        <PasswordSheet server={server} error={asking.error}
                       why={`${server.user ?? "This user"} needs a password for sudo to reboot ${server.name}.`}
                       onCancel={() => setAsking(undefined)}
                       onSubmit={(pw) => void propose(pw)} />
      )}
    </>
  );
  return { request: () => void propose(), sheets, error };
}

/** While a reboot is under way, and once it is over. */
export function RebootBanner(props: { server: Server; reboot: RebootState | null | undefined; onDismiss: () => void }) {
  const r = props.reboot;
  const [now, setNow] = useState(Date.now() / 1000);
  useEffect(() => {
    if (r?.phase !== "waiting") return;
    const t = window.setInterval(() => setNow(Date.now() / 1000), 1000);
    return () => window.clearInterval(t);
  }, [r?.phase]);
  if (!r) return null;
  const dismiss = <Button onClick={props.onDismiss}>Dismiss</Button>;
  if (r.phase === "waiting") {
    return (
      <Notice tone="info" title={`Rebooting ${props.server.name}…`}>
        <p><Spinner /> Waiting for it to come back with a new boot id ({Math.max(0, Math.round(now - r.started))} s).</p>
      </Notice>
    );
  }
  if (r.phase === "back") {
    return <Notice tone="ok" title={`${props.server.name} is back`} actions={dismiss}>
      <p>It answered with a new boot id after {Math.round(r.elapsed ?? 0)} s.</p></Notice>;
  }
  return <Notice tone="warn" title={`${props.server.name} has not come back`} actions={dismiss}>
    <p>Ten minutes passed without a new boot id. Check the server's console.</p></Notice>;
}
