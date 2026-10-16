import { FitAddon } from "@xterm/addon-fit";
import { Terminal, type ITheme } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { useEffect, useRef, useState } from "react";
import { api, ApiError } from "../api";
import { Button, Empty, Notice } from "../components/ui";
import { useApp } from "../context";
import { usePoll } from "../hooks";
import type { Appearance, Safety, Server, TerminalTab } from "../types";

function xtermTheme(a: Appearance | undefined): ITheme | undefined {
  if (!a) return undefined;
  const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  const t = (dark ? a.dark : a.light).terminal;
  const [black, red, green, yellow, blue, magenta, cyan, white, bBlack, bRed, bGreen, bYellow, bBlue, bMagenta, bCyan, bWhite] = t.ansi;
  return {
    background: t.background, foreground: t.foreground, cursor: t.cursor, cursorAccent: t.background,
    selectionBackground: `${t.selection}66`, black, red, green, yellow, blue, magenta, cyan, white,
    brightBlack: bBlack, brightRed: bRed, brightGreen: bGreen, brightYellow: bYellow, brightBlue: bBlue,
    brightMagenta: bMagenta, brightCyan: bCyan, brightWhite: bWhite,
  };
}

interface Status { state: TerminalTab["state"]; attempt?: number; of?: number; delay?: number; exitCode?: number | null }

/** One tab's screen: xterm.js fed by the backend's WebSocket. The shell lives on the backend, so closing this view
 * (switching tabs or screens, reloading) only detaches; coming back replays the scrollback. */
function TerminalView(props: { tab: TerminalTab; onStatus: (s: Status) => void; onReadOnly: () => void }) {
  const app = useApp();
  const host = useRef<HTMLDivElement>(null);
  const [attached, setAttached] = useState(false);
  useEffect(() => {
    const term = new Terminal({
      fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace', fontSize: 13, cursorBlink: true,
      scrollback: 10_000, theme: xtermTheme(app.appearance), allowProposedApi: false,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(host.current!);
    const encoder = new TextEncoder();
    let socket: WebSocket | undefined;
    let closed = false;
    let retry = 0;
    const sendSize = () => {
      try {
        fit.fit();
      } catch {
        return; // not laid out yet
      }
      if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: "resize", cols: term.cols, rows: term.rows }));
    };
    const connect = () => {
      const proto = window.location.protocol === "https:" ? "wss" : "ws";
      socket = new WebSocket(`${proto}://${window.location.host}/api/terminals/${props.tab.id}/ws`);
      socket.binaryType = "arraybuffer";
      socket.onopen = () => {
        retry = 0;
        term.reset(); // the backend replays the scrollback first
        setAttached(true);
        sendSize();
      };
      socket.onmessage = (e: MessageEvent<ArrayBuffer | string>) => {
        if (typeof e.data === "string") {
          const control = JSON.parse(e.data) as Status & { type: string };
          if (control.type === "state") props.onStatus(control);
          if (control.type === "readOnly") props.onReadOnly();
        } else {
          term.write(new Uint8Array(e.data));
        }
      };
      socket.onclose = (e) => {
        setAttached(false);
        if (closed || e.code === 4404) return;
        // The page lost the backend (a restart, the network): attach again; the shell itself is still there.
        retry = Math.min(retry + 1, 5);
        window.setTimeout(() => !closed && connect(), 500 * 2 ** retry);
      };
    };
    connect();
    const send = (data: string) => socket?.readyState === WebSocket.OPEN && socket.send(encoder.encode(data));
    const input = term.onData(send);
    const binary = term.onBinary((data) => socket?.readyState === WebSocket.OPEN &&
      socket.send(Uint8Array.from(data, (c) => c.charCodeAt(0))));
    const observer = new ResizeObserver(() => sendSize());
    observer.observe(host.current!);
    term.focus();
    return () => {
      closed = true;
      observer.disconnect();
      input.dispose();
      binary.dispose();
      socket?.close();
      term.dispose();
    };
    // The theme is applied below without reconnecting.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.tab.id]);
  return (
    <div className="terminal-host" data-attached={attached}>
      <div ref={host} className="terminal-surface" />
    </div>
  );
}

function Overlay(props: { status: Status; onReconnect: () => void; onClose: () => void }) {
  const { status } = props;
  const [left, setLeft] = useState(status.delay ?? 0);
  useEffect(() => {
    setLeft(status.delay ?? 0);
    if (status.state !== "reconnecting") return;
    const timer = window.setInterval(() => setLeft((l) => Math.max(0, l - 1)), 1000);
    return () => window.clearInterval(timer);
  }, [status]);
  if (status.state === "connected" || status.state === "starting") return null;
  const text = status.state === "reconnecting"
    ? `Connection lost. Reconnecting in ${Math.ceil(left)} s (attempt ${status.attempt} of ${status.of}).`
    : status.state === "exited" ? `The shell ended (exit ${status.exitCode ?? "?"}).` : "Disconnected.";
  return (
    <div className="terminal-overlay" role="status">
      <span>{text}</span>
      <Button kind="primary" small onClick={props.onReconnect}>{status.state === "exited" ? "Start Again" : "Reconnect Now"}</Button>
      <Button small onClick={props.onClose}>Close Tab</Button>
    </div>
  );
}

export function TerminalScreen(props: { server: Server }) {
  const app = useApp();
  const [selected, setSelected] = useState<string>();
  const [statuses, setStatuses] = useState<Record<string, Status>>({});
  const [renaming, setRenaming] = useState<string>();
  const [error, setError] = useState<string>();
  const [typingBlocked, setTypingBlocked] = useState(false);
  const { data: tabs, reload } = usePoll(() => api.get<TerminalTab[]>(`/api/servers/${props.server.id}/terminals`), 5000,
    [props.server.id]);
  const readOnly = app.safety?.readOnly ?? true;
  useEffect(() => {
    if (tabs && (!selected || !tabs.some((t) => t.id === selected))) setSelected(tabs[0]?.id);
  }, [tabs, selected]);
  useEffect(() => setTypingBlocked(false), [readOnly]);

  const newTab = async () => {
    setError(undefined);
    try {
      const tab = await api.post<TerminalTab>(`/api/servers/${props.server.id}/terminals`, { cols: 100, rows: 30 });
      await reload();
      setSelected(tab.id);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e));
    }
  };
  const closeTab = async (id: string) => {
    await api.del(`/api/terminals/${id}`).catch(() => undefined);
    await reload();
  };
  const turnOffReadOnly = async () => app.setSafety(await api.put<Safety>("/api/safety", { readOnly: false }));
  const toggleHighlight = async () => {
    if (!app.appearance) return;
    app.setAppearance(await api.put<Appearance>("/api/appearance", { highlightOutput: !app.appearance.highlightOutput }));
  };

  if (!tabs) return <div className="page" />;
  const current = tabs.find((t) => t.id === selected);
  const status: Status | undefined = current ? statuses[current.id] ?? { ...current } : undefined;
  return (
    <div className="terminal-page">
      <div className="terminal-tabs" role="tablist" aria-label="Terminal tabs">
        {tabs.map((t) => (
          <div key={t.id} role="tab" aria-selected={t.id === selected} className={`terminal-tab${t.id === selected ? " selected" : ""}`}>
            {renaming === t.id ? (
              <input autoFocus defaultValue={t.title} maxLength={40} aria-label="Tab name"
                     onKeyDown={async (e) => {
                       if (e.key === "Escape") setRenaming(undefined);
                       if (e.key === "Enter") {
                         await api.put(`/api/terminals/${t.id}`, { title: e.currentTarget.value });
                         setRenaming(undefined);
                         await reload();
                       }
                     }}
                     onBlur={async (e) => {
                       await api.put(`/api/terminals/${t.id}`, { title: e.currentTarget.value });
                       setRenaming(undefined);
                       await reload();
                     }} />
            ) : (
              <button type="button" className="terminal-tab-name"
                      title={t.id === selected ? "Click to rename" : t.title}
                      onClick={() => (t.id === selected ? setRenaming(t.id) : setSelected(t.id))}>
                <span className={`dot dot-${(statuses[t.id]?.state ?? t.state) === "connected" ? "ok" : "idle"}`} />
                {t.title}
              </button>
            )}
            <button type="button" className="terminal-tab-close" title={`Close ${t.title}`} onClick={() => void closeTab(t.id)}>×</button>
          </div>
        ))}
        <button type="button" className="terminal-tab-add" title="New tab" disabled={readOnly} onClick={() => void newTab()}>+</button>
        <span className="terminal-tabs-spacer" />
        <label className="toggle">
          <input type="checkbox" checked={app.appearance?.highlightOutput ?? true} onChange={() => void toggleHighlight()} />
          Highlight output
        </label>
      </div>
      {error && <Notice tone="danger">{error}</Notice>}
      {readOnly && (
        <Notice tone="info" title="Read-only is on"
                actions={<Button kind="primary" onClick={() => void turnOffReadOnly()}>Turn Off Read-only</Button>}>
          A shell can change anything on the server, so {tabs.length ? "typing is paused" : "no session opens"} until
          Read-only is off.
        </Notice>
      )}
      {!readOnly && typingBlocked && <Notice tone="warn">Typing was refused while Read-only was on.</Notice>}
      {tabs.length === 0 && !readOnly && (
        <Empty title={`No terminal on ${props.server.name}`}>
          <Button kind="primary" onClick={() => void newTab()}>Open a Shell</Button>
        </Empty>
      )}
      {current && status && (
        <div className="terminal-frame">
          <TerminalView key={current.id} tab={current}
                        onStatus={(s) => setStatuses((m) => ({ ...m, [current.id]: s }))}
                        onReadOnly={() => setTypingBlocked(true)} />
          <Overlay status={status} onClose={() => void closeTab(current.id)}
                   onReconnect={async () => {
                     try {
                       await api.post(`/api/terminals/${current.id}/reconnect`);
                     } catch (e) {
                       setError(e instanceof ApiError ? e.message : String(e));
                     }
                   }} />
        </div>
      )}
    </div>
  );
}
