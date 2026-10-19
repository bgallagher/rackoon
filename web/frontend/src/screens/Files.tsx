// Files: browse a server's folders, download, upload, new folder, rename, delete. Bytes pass through Rackoon's own
// server on a plain remote command's standard input or output. An upload is confirmed first (the exact command, with
// the exact size), and only a complete upload replaces anything. Folders download as a .tar of their contents.
import { useEffect, useRef, useState } from "react";
import { api, ApiError, csrfToken } from "../api";
import { ConfirmSheet } from "../components/ConfirmSheet";
import { errorText, Menu } from "../components/docker";
import { Button, Modal, Notice, Spinner } from "../components/ui";
import { useApp } from "../context";
import { bytes } from "../format";
import type { FileEntry, Listing, PendingAction, Server } from "../types";

interface Transfer { id: number; name: string; sent: number; total: number; error?: string; done?: boolean }
let nextTransfer = 0;

function sendBytes(token: string, file: File, progress: (sent: number) => void): Promise<void> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", `/api/files/uploads/${token}`);
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    const csrf = csrfToken();
    if (csrf) xhr.setRequestHeader("X-Rackoon-CSRF", csrf);
    xhr.upload.onprogress = (e) => progress(e.loaded);
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) resolve();
      else {
        let message = `Upload failed (${xhr.status})`;
        try { message = (JSON.parse(xhr.responseText) as { message?: string }).message ?? message; } catch { /* plain text */ }
        reject(new ApiError(xhr.status, "uploadFailed", message));
      }
    };
    xhr.onerror = () => reject(new ApiError(0, "offline", "The upload was interrupted. Nothing was replaced."));
    xhr.send(file);
  });
}

export function FilesScreen(props: { server: Server }) {
  const app = useApp();
  const base = `/api/servers/${props.server.id}/files`;
  const [path, setPath] = useState<string>();
  const [listing, setListing] = useState<Listing>();
  const [error, setError] = useState<string>();
  const [pending, setPending] = useState<{ action: PendingAction; then: (result: unknown) => void }>();
  const [naming, setNaming] = useState<{ kind: "mkdir" | "rename"; entry?: FileEntry }>();
  const [conflict, setConflict] = useState<{ file: File; resolve: (choice: "replace" | "keep" | "skip") => void }>();
  const [transfers, setTransfers] = useState<Transfer[]>([]);
  const picker = useRef<HTMLInputElement>(null);
  const readOnly = app.safety?.readOnly ?? true;
  useEffect(() => {
    void api.get<{ path: string }>(`${base}/home`).then((h) => setPath(h.path)).catch((e) => setError(errorText(e)));
  }, [base]);
  const load = async (p: string) => {
    setError(undefined);
    try {
      const l = await api.get<Listing>(`${base}/list?path=${encodeURIComponent(p)}`);
      setListing(l);
      setPath(l.path);
    } catch (e) {
      setError(errorText(e));
    }
  };
  useEffect(() => {
    if (path && listing?.path !== path) void load(path);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [path]);
  const propose = async (url: string, body: Record<string, unknown>, then: (result: unknown) => void) => {
    setError(undefined);
    try {
      const r = await api.post<{ pending: PendingAction }>(url, body);
      setPending({ action: r.pending, then });
    } catch (e) {
      setError(errorText(e));
    }
  };
  const op = (body: Record<string, unknown>) => void propose(`${base}/op`, { directory: listing!.path, ...body }, (result) => {
    const r = result as { ok: boolean; message?: string };
    if (!r.ok) setError(r.message);
    void load(listing!.path);
  });
  const uploadOne = (file: File, name: string) => new Promise<void>((resolve) => {
    void propose(`${base}/upload`, { directory: listing!.path, name, size: file.size }, (result) => {
      const token = (result as { upload: string }).upload;
      const id = nextTransfer++;
      setTransfers((ts) => [...ts, { id, name, sent: 0, total: file.size }]);
      const update = (patch: Partial<Transfer>) => setTransfers((ts) => ts.map((x) => (x.id === id ? { ...x, ...patch } : x)));
      sendBytes(token, file, (sent) => update({ sent }))
        .then(() => update({ done: true, sent: file.size }))
        .catch((e) => update({ error: errorText(e) }))
        .finally(() => { void load(listing!.path); resolve(); });
    });
  });
  const upload = async (files: FileList | null) => {
    if (!files || !listing) return;
    for (const file of Array.from(files)) {
      let name = file.name;
      if (listing.entries.some((e) => e.name === name)) {
        const choice = await new Promise<"replace" | "keep" | "skip">((resolve) => setConflict({ file, resolve }));
        setConflict(undefined);
        if (choice === "skip") continue;
        if (choice === "keep") {
          name = (await api.get<{ name: string }>(`${base}/free-name?directory=${encodeURIComponent(listing.path)}&name=${encodeURIComponent(name)}`)).name;
        }
      }
      await uploadOne(file, name);
    }
  };
  if (!listing) return <div className="page">{error ? <Notice tone="danger">{error}</Notice> : <Spinner />}</div>;
  const download = (e: FileEntry) => {
    const q = `directory=${encodeURIComponent(listing.path)}&name=${encodeURIComponent(e.name)}&folder=${e.isDirectory}`;
    window.location.href = `${base}/download?${q}`;
  };
  return (
    <div className="page"
         onDragOver={(e) => { if (!readOnly) e.preventDefault(); }}
         onDrop={(e) => { e.preventDefault(); if (!readOnly) void upload(e.dataTransfer.files); }}>
      <header className="page-head">
        <div>
          <h1>Files</h1>
          <nav className="breadcrumb crumbs">
            {listing.crumbs.map((c, i) => (
              <span key={c.path}>
                {i > 1 && <span className="muted">/</span>}
                <button type="button" className="link" onClick={() => void load(c.path)}>{c.name}</button>
              </span>
            ))}
          </nav>
        </div>
        <div className="card-actions">
          <Button disabled={readOnly} title={readOnly ? "Read-only mode is on" : undefined}
                  onClick={() => setNaming({ kind: "mkdir" })}>New Folder…</Button>
          <Button kind="primary" disabled={readOnly} title={readOnly ? "Read-only mode is on" : "Or drop files on this page"}
                  onClick={() => picker.current?.click()}>Upload…</Button>
          <input ref={picker} type="file" multiple hidden onChange={(e) => { void upload(e.target.files); e.target.value = ""; }} />
        </div>
      </header>
      {error && <Notice tone="danger">{error}</Notice>}
      {listing.truncated && <Notice tone="info">This folder has more than 5,000 entries; only the first are shown.</Notice>}
      {transfers.length > 0 && (
        <ul className="transfers">
          {transfers.map((t) => (
            <li key={t.id} className={t.error ? "failed" : t.done ? "done" : ""}>
              <span>{t.name}</span>
              <progress max={t.total || 1} value={t.sent} />
              <span className="dim">{t.error ?? (t.done ? "uploaded" : `${bytes(t.sent)} of ${bytes(t.total)}`)}</span>
            </li>
          ))}
          <li><button type="button" className="link" onClick={() => setTransfers([])}>Clear</button></li>
        </ul>
      )}
      <div className="card">
        <table className="files">
          <thead><tr><th>Name</th><th>Size</th><th>Modified</th><th>Owner</th><th>Mode</th><th /></tr></thead>
          <tbody>
            {listing.parent && (
              <tr><td colSpan={6}><button type="button" className="link" onClick={() => void load(listing.parent!)}>‹ Up to {listing.parent}</button></td></tr>
            )}
            {listing.entries.map((e) => (
              <tr key={e.name}>
                <td>
                  {e.isDirectory
                    ? <button type="button" className="link file-name" onClick={() => void load(`${listing.path === "/" ? "" : listing.path}/${e.name}`)}>📁 {e.name}</button>
                    : <span className="file-name">{e.kind === "symlink" ? "↪" : "📄"} {e.name}</span>}
                  {e.linkTarget && <span className="dim"> → {e.linkTarget}</span>}
                </td>
                <td className="dim">{e.isDirectory ? "—" : bytes(e.size)}</td>
                <td className="dim">{new Date(e.modified * 1000).toLocaleString()}</td>
                <td className="dim">{e.owner}</td>
                <td className="mono dim">{e.permissions}</td>
                <td>
                  <Menu small label="⋯" title={`More for ${e.name}`} items={[
                    { label: e.isDirectory ? "Download as .tar" : "Download", onClick: () => download(e) },
                    { label: "Rename…", onClick: () => setNaming({ kind: "rename", entry: e }), disabled: readOnly, reason: "Read-only mode is on" },
                    null,
                    { label: "Delete…", danger: true, onClick: () => op({ kind: "delete", name: e.name, isFolder: e.kind === "directory" }),
                      disabled: readOnly || (e.kind === "directory" && !!e.deleteProblem),
                      reason: readOnly ? "Read-only mode is on" : e.deleteProblem },
                  ]} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {listing.entries.length === 0 && <p className="dim">This folder is empty.</p>}
      </div>
      {naming && (
        <NameSheet title={naming.kind === "mkdir" ? "New folder" : `Rename ${naming.entry?.name}`}
                   initial={naming.entry?.name ?? ""}
                   onCancel={() => setNaming(undefined)}
                   onSubmit={(name) => {
                     setNaming(undefined);
                     op(naming.kind === "mkdir" ? { kind: "mkdir", name } : { kind: "rename", name: naming.entry!.name, to: name });
                   }} />
      )}
      {conflict && (
        <Modal title={`${conflict.file.name} is already there`} onClose={() => conflict.resolve("skip")}
               footer={<>
                 <Button onClick={() => conflict.resolve("skip")}>Skip</Button>
                 <Button onClick={() => conflict.resolve("keep")}>Keep Both</Button>
                 <Button kind="danger" onClick={() => conflict.resolve("replace")}>Replace…</Button>
               </>}>
          <p>Replace the file on the server, keep both (the new one gets a number), or skip this one.</p>
        </Modal>
      )}
      {pending && (
        <ConfirmSheet action={pending.action} onCancel={() => setPending(undefined)}
                      onDone={(result) => { const then = pending.then; setPending(undefined); then(result); }} />
      )}
    </div>
  );
}

function NameSheet(props: { title: string; initial: string; onSubmit: (name: string) => void; onCancel: () => void }) {
  const [name, setName] = useState(props.initial);
  const valid = name.trim() !== "" && !name.includes("/") && name !== "." && name !== "..";
  return (
    <Modal title={props.title} onClose={props.onCancel}
           footer={<><Button onClick={props.onCancel}>Cancel</Button>
             <Button kind="primary" disabled={!valid} onClick={() => props.onSubmit(name.trim())}>Continue…</Button></>}>
      <form onSubmit={(e) => { e.preventDefault(); if (valid) props.onSubmit(name.trim()); }}>
        <input value={name} onChange={(e) => setName(e.target.value)} aria-label="Name" spellCheck={false} />
      </form>
    </Modal>
  );
}
