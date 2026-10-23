import { useEffect, useRef, useState, type ReactNode } from "react";
import type { Connection } from "../types";

export function Button(props: {
  children: ReactNode;
  onClick?: () => void;
  kind?: "primary" | "plain" | "danger" | "quiet";
  disabled?: boolean;
  title?: string;
  type?: "button" | "submit";
  small?: boolean;
}) {
  const { kind = "plain", type = "button" } = props;
  return (
    <button
      type={type}
      className={`btn btn-${kind}${props.small ? " btn-small" : ""}`}
      onClick={props.onClick}
      disabled={props.disabled}
      title={props.title}
    >
      {props.children}
    </button>
  );
}

export function Card(props: { title?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`card ${props.className ?? ""}`}>
      {(props.title || props.actions) && (
        <header className="card-head">
          <h3>{props.title}</h3>
          <div className="card-actions">{props.actions}</div>
        </header>
      )}
      {props.children}
    </section>
  );
}

/** A bar from 0 to 1; amber over 85%, red from 95% (the attention thresholds). */
export function Meter(props: { value: number | null | undefined; label?: string }) {
  const v = props.value ?? 0;
  const tone = v >= 0.95 ? "danger" : v > 0.85 ? "warn" : "ok";
  return (
    <div className="meter" role="meter" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(v * 100)}
         aria-label={props.label}>
      <div className={`meter-fill meter-${props.value == null ? "idle" : tone}`} style={{ width: `${Math.min(100, v * 100)}%` }} />
    </div>
  );
}

export function StatusDot(props: { connection: Connection | "stale"; title?: string }) {
  const tone = {
    ok: "ok", connecting: "idle", stale: "idle", hostKeyUnknown: "idle", hostKeyChanged: "danger", authFailed: "danger",
    unreachable: "danger", failed: "danger",
  }[props.connection];
  return <span className={`dot dot-${tone}`} title={props.title ?? props.connection} aria-label={props.title ?? props.connection} />;
}

export type Tone = "info" | "ok" | "warn" | "danger";

/** One notice look for the whole app, like Notices.swift on the Mac. */
export function Notice(props: { tone: Tone; title?: ReactNode; children?: ReactNode; actions?: ReactNode }) {
  return (
    <div className={`notice notice-${props.tone}`} role={props.tone === "danger" ? "alert" : "status"}>
      <div className="notice-body">
        {props.title && <strong className="notice-title">{props.title}</strong>}
        {props.children}
      </div>
      {props.actions && <div className="notice-actions">{props.actions}</div>}
    </div>
  );
}

export function CopyButton(props: { text: string; label?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      type="button"
      className="copy"
      title={`Copy ${props.label ?? props.text}`}
      onClick={() => {
        void navigator.clipboard?.writeText(props.text).then(() => {
          setDone(true);
          window.setTimeout(() => setDone(false), 1200);
        });
      }}
    >
      {done ? "Copied" : "Copy"}
    </button>
  );
}

export function Field(props: { label: string; hint?: ReactNode; children: ReactNode }) {
  return (
    <label className="field">
      <span className="field-label">{props.label}</span>
      {props.children}
      {props.hint && <span className="field-hint">{props.hint}</span>}
    </label>
  );
}

/** A modal sheet. Esc closes it; focus starts inside. */
export function Modal(props: { title: string; onClose: () => void; children: ReactNode; footer?: ReactNode; wide?: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    const first = ref.current?.querySelector<HTMLElement>("input, textarea, select, button.btn-primary, button");
    first?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") props.onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("keydown", onKey);
      previous?.focus();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && props.onClose()}>
      <div className={`sheet${props.wide ? " sheet-wide" : ""}`} role="dialog" aria-modal="true" aria-label={props.title} ref={ref}>
        <h2 className="sheet-title">{props.title}</h2>
        <div className="sheet-body">{props.children}</div>
        {props.footer && <div className="sheet-footer">{props.footer}</div>}
      </div>
    </div>
  );
}

export function Empty(props: { title: string; children?: ReactNode }) {
  return (
    <div className="empty">
      <h2>{props.title}</h2>
      {props.children}
    </div>
  );
}

export function Spinner() {
  return <span className="spinner" aria-label="Loading" />;
}
