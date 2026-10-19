// Pieces the Docker screens share: app tiles, site icons, a menu, the action flow (propose -> confirm sheet -> result)
// and the bookmark and delete sheets. Every rule comes from the backend; these only lay it out.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { api, ApiError } from "../api";
import type { ActionResult, Bookmark, DockerState, PendingAction, Server, Stack } from "../types";
import { ConfirmSheet } from "./ConfirmSheet";
import { PasswordSheet } from "./root";
import { Button, Empty, Field, Modal, Notice } from "./ui";

/** The size the Output view last measured, so a run's progress is drawn for the view that shows it. */
export const outputSize = { cols: 120, rows: 32 };

export function errorText(e: unknown): string {
  return e instanceof ApiError ? e.message : e instanceof Error ? e.message : String(e);
}

export function LetterTile(props: { letter: string; hue: number; size?: number }) {
  const size = props.size ?? 36;
  return (
    <span className="letter-tile" aria-hidden="true"
          style={{ width: size, height: size, fontSize: size * 0.48, background: `hsl(${props.hue} 42% 42%)` }}>
      {props.letter}
    </span>
  );
}

/** A site's icon (fetched and cached by the backend, only for addresses Docker reported), else the letter tile. */
export function SiteIcon(props: { href: string | null | undefined; letter: string; hue: number; size?: number }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [props.href]);
  if (!props.href || failed) return <LetterTile letter={props.letter} hue={props.hue} size={props.size} />;
  const size = props.size ?? 36;
  return (
    <img className="site-icon" src={`/api/favicons?href=${encodeURIComponent(props.href)}`} alt="" width={size}
         height={size} loading="lazy" onError={() => setFailed(true)} />
  );
}

export interface MenuItem {
  label: string;
  detail?: string;
  onClick: () => void;
  disabled?: boolean;
  reason?: string | null;
  danger?: boolean;
}

/** A button that opens a list of actions, each with a one-line explanation (nothing that changes a server is one
 * click away). Esc or a click outside closes it. */
export function Menu(props: { label: ReactNode; items: (MenuItem | null)[]; title?: string; small?: boolean;
  align?: "left" | "right" }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => !ref.current?.contains(e.target as Node) && setOpen(false);
    const key = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("mousedown", close);
    window.addEventListener("keydown", key);
    return () => {
      window.removeEventListener("mousedown", close);
      window.removeEventListener("keydown", key);
    };
  }, [open]);
  return (
    <div className="menu" ref={ref}>
      <button type="button" className={`btn btn-plain${props.small ? " btn-small" : ""}`} aria-haspopup="menu"
              aria-expanded={open} title={props.title} onClick={() => setOpen(!open)}>
        {props.label}
      </button>
      {open && (
        <ul className={`menu-list menu-${props.align ?? "right"}`} role="menu">
          {props.items.map((item, i) => item === null ? <li key={i} className="menu-sep" role="separator" /> : (
            <li key={item.label} role="none">
              <button type="button" role="menuitem" className={item.danger ? "danger" : undefined}
                      disabled={item.disabled} title={item.disabled ? item.reason ?? undefined : undefined}
                      onClick={() => {
                        setOpen(false);
                        item.onClick();
                      }}>
                <span className="menu-label">{item.label}</span>
                {(item.disabled ? item.reason : item.detail) && (
                  <span className="menu-detail">{item.disabled ? item.reason : item.detail}</span>
                )}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** Propose a change, show the backend's sheet, hand back what the confirmed action came to. */
export function useAction(onResult: (r: ActionResult) => void): {
  request: (path: string, body?: Record<string, unknown>) => Promise<void>;
  sheet: ReactNode;
  error: string | undefined;
  setError: (e: string | undefined) => void;
  asking: boolean;
} {
  const [pending, setPending] = useState<PendingAction>();
  const [error, setError] = useState<string>();
  const [asking, setAsking] = useState(false);
  const request = async (path: string, body: Record<string, unknown> = {}) => {
    setError(undefined);
    setAsking(true);
    try {
      const r = await api.post<{ pending?: PendingAction } & ActionResult>(path, { ...outputSize, ...body });
      if (r.pending) setPending(r.pending);
      else onResult(r);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setAsking(false);
    }
  };
  const sheet = pending ? (
    <ConfirmSheet action={pending} onCancel={() => setPending(undefined)}
                  onDone={(result) => {
                    setPending(undefined);
                    onResult((result ?? {}) as ActionResult);
                  }} />
  ) : null;
  return { request, sheet, error, setError, asking };
}

/** What to delete with a stack: its named volumes (off) and its folder (on when allowed). The confirm sheet that
 * follows shows the exact command and asks for the stack's name whenever data goes too. */
export function DeleteSheet(props: { stack: Stack; onContinue: (removeVolumes: boolean, deleteFolder: boolean) => void;
  onCancel: () => void }) {
  const s = props.stack;
  const [volumes, setVolumes] = useState(false);
  const [folder, setFolder] = useState(!s.isStandalone && !s.folderProblem);
  return (
    <Modal title={`Delete ${s.name}?`} onClose={props.onCancel}
           footer={<>
             <Button onClick={props.onCancel}>Cancel</Button>
             <Button kind="danger" onClick={() => props.onContinue(volumes, folder)}>Continue…</Button>
           </>}>
      <p>{s.isStandalone ? `The container ${s.name} is stopped and removed. Its image is kept.`
                         : "Its containers and networks are removed with docker compose down. Images are kept."}</p>
      <label className="check">
        <input type="checkbox" checked={volumes} onChange={(e) => setVolumes(e.target.checked)} />
        <span>{s.isStandalone ? "Also delete its anonymous volumes" : "Also delete its named volumes and their data"}</span>
      </label>
      {!s.isStandalone && (
        <label className="check">
          <input type="checkbox" checked={folder} disabled={!!s.folderProblem} onChange={(e) => setFolder(e.target.checked)} />
          <span>
            Delete the folder <span className="mono">{s.workingDir}</span>
            {s.folderProblem && <span className="dim"> ({s.folderProblem})</span>}
          </span>
        </label>
      )}
    </Modal>
  );
}

/** Add, edit or remove a service's Homepage labels (written into its compose file; the sheet after this shows the
 * diff). */
export function BookmarkSheet(props: {
  title: string;
  initial?: Bookmark;
  services?: { stackId: string; stackName: string; service: string }[];
  fixed?: { stackId: string; service: string };
  onSubmit: (target: { stackId: string; service: string }, bookmark: Bookmark | null, apply: boolean) => void;
  onCancel: () => void;
  readOnly: boolean;
}) {
  const [b, setB] = useState<Bookmark>(props.initial ?? { href: "" });
  const [pick, setPick] = useState(props.fixed ? `${props.fixed.stackId}\u0000${props.fixed.service}`
    : props.services?.[0] ? `${props.services[0].stackId}\u0000${props.services[0].service}` : "");
  const [stackId = "", service = ""] = pick.split("\u0000");
  const valid = /^https?:\/\/[^\s/]+/.test(b.href.trim()) && !!service;
  const clean = (): Bookmark => ({
    href: b.href.trim(), name: b.name?.trim() || undefined, group: b.group?.trim() || undefined,
    description: b.description?.trim() || undefined, icon: b.icon?.trim() || undefined,
  });
  const set = (k: keyof Bookmark) => (e: { target: { value: string } }) => setB({ ...b, [k]: e.target.value });
  return (
    <Modal title={props.title} onClose={props.onCancel}
           footer={<>
             {props.initial && (
               <Button kind="quiet" disabled={props.readOnly}
                       onClick={() => props.onSubmit({ stackId, service }, null, true)}>Remove Bookmark…</Button>
             )}
             <span className="sheet-footer-spacer" />
             <Button onClick={props.onCancel}>Cancel</Button>
             <Button disabled={!valid || props.readOnly} onClick={() => props.onSubmit({ stackId, service }, clean(), false)}>
               Save Only…
             </Button>
             <Button kind="primary" disabled={!valid || props.readOnly}
                     onClick={() => props.onSubmit({ stackId, service }, clean(), true)}>Save and Apply…</Button>
           </>}>
      {props.readOnly && <Notice tone="info">Read-only is on. Turn it off to change bookmarks.</Notice>}
      {props.services && !props.fixed && (
        <Field label="Service">
          <select value={pick} onChange={(e) => setPick(e.target.value)}>
            {props.services.map((s) => (
              <option key={`${s.stackId}/${s.service}`} value={`${s.stackId}\u0000${s.service}`}>
                {s.stackName} › {s.service}
              </option>
            ))}
          </select>
        </Field>
      )}
      <Field label="Address" hint="An http:// or https:// link, written as the homepage.href label">
        <input value={b.href} onChange={set("href")} placeholder="http://100.64.0.1:8096" spellCheck={false} />
      </Field>
      <div className="form-row">
        <Field label="Name"><input value={b.name ?? ""} onChange={set("name")} /></Field>
        <Field label="Group"><input value={b.group ?? ""} onChange={set("group")} placeholder="Media" /></Field>
      </div>
      <Field label="Description"><input value={b.description ?? ""} onChange={set("description")} /></Field>
      <p className="dim">Save and Apply updates the stack afterwards (the service restarts briefly) so the bookmark shows
        up; Save Only waits for the next update.</p>
    </Modal>
  );
}

export function stackRoute(serverId: string, stackId: string): string {
  return `/servers/${serverId}/docker/stack/${encodeURIComponent(stackId)}`;
}


/** Why Docker can't be shown, in words that never ask the user to change the server. */
export function DockerProblem(props: { state: DockerState; server: Server; onUnlock?: () => void }) {
  const s = props.state;
  if (s.status === "notInstalled") return <Empty title="Docker is not installed on this server" />;
  if (s.problem === "permission") {
    return (
      <Notice tone="warn" title={`Docker refused ${props.server.user ?? "this user"}`}
              actions={props.onUnlock && <Button kind="primary" onClick={props.onUnlock}>Unlock with sudo…</Button>}>
        <p>The ssh user may not use Docker on {props.server.name}. Rackoon can run Docker through sudo for a while
          instead; nothing on the server changes.</p>
        {s.elevation?.lockReason && <p>{s.elevation.lockReason}</p>}
        <p className="raw">{s.error}</p>
      </Notice>
    );
  }
  if (s.error) return <Notice tone="danger" title="Docker didn't answer"><p className="raw">{s.error}</p></Notice>;
  return null;
}


/** Docker through sudo: the unlock sheet, and while unlocked, a chip with the time left and Lock. */
export function useDockerSudo(server: Server, state: DockerState | undefined, reload: () => Promise<void>): {
  unlock: () => void; chip: ReactNode; sheet: ReactNode;
} {
  const [asking, setAsking] = useState<{ error: string | null }>();
  const until = state?.elevation?.until ?? null;
  const submit = async (password: string) => {
    try {
      await api.post(`/api/servers/${server.id}/docker/unlock`, { password });
      setAsking(undefined);
      await reload();
    } catch (e) {
      setAsking({ error: errorText(e) });
    }
  };
  const lock = async () => {
    await api.post(`/api/servers/${server.id}/docker/lock`).catch(() => undefined);
    await reload();
  };
  const chip = until ? (
    <span className="badge badge-warn" title="Docker commands run through sudo with the password held in memory">
      Docker via sudo until {new Date(until * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
      {" "}<button type="button" className="link" onClick={() => void lock()}>Lock</button>
    </span>
  ) : null;
  const sheet = asking ? (
    <PasswordSheet server={server} holds error={asking.error}
                   why={`Docker on ${server.name} refuses ${server.user ?? "this user"}. With the sudo password, Rackoon runs each Docker command through sudo.`}
                   onCancel={() => setAsking(undefined)} onSubmit={(pw) => void submit(pw)} />
  ) : null;
  return { unlock: () => setAsking({ error: null }), chip, sheet };
}
