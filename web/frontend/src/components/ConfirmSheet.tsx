import { useState } from "react";
import { api, ApiError } from "../api";
import type { PendingAction } from "../types";
import { Button, Modal, Notice } from "./ui";

/** A diff preview (a file save carries its content encoded, so the sheet shows what changes instead). */
function Diff(props: { text: string }) {
  return (
    <pre className="command diff">
      {props.text.split("\n").map((line, i) => (
        <span key={i} className={line.startsWith("+") ? "diff-add" : line.startsWith("-") ? "diff-del" : undefined}>
          {line}
          {"\n"}
        </span>
      ))}
    </pre>
  );
}

/**
 * Shows exactly what will run on the server (the backend's pending action) and runs it only on "Run Command".
 * A destructive action's button is red and Return does not press it: only a click does, and Esc cancels. When the
 * backend asks for a word to be typed, the button waits for it (and the backend checks it again).
 */
export function ConfirmSheet(props: { action: PendingAction; onDone: (result: unknown) => void; onCancel: () => void }) {
  const [error, setError] = useState<string>();
  const [running, setRunning] = useState(false);
  const [typed, setTyped] = useState("");
  const { action } = props;
  const cancel = () => {
    void api.post(`/api/actions/${action.id}/cancel`).catch(() => undefined);
    props.onCancel();
  };
  const ready = action.typed === null || typed === action.typed;
  const run = async () => {
    if (!ready) return;
    setRunning(true);
    setError(undefined);
    try {
      const r = await api.post<{ result: unknown }>(`/api/actions/${action.id}/confirm`,
        action.typed ? { typed } : {});
      props.onDone(r.result);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e));
      setRunning(false);
    }
  };
  return (
    <Modal
      title={action.title}
      onClose={cancel}
      wide={action.isPreview}
      footer={
        <>
          <Button onClick={cancel}>Cancel</Button>
          <Button kind={action.destructive ? "danger" : "primary"} type={action.destructive ? "button" : "submit"}
                  disabled={running || !ready} onClick={() => void run()}>
            Run Command
          </Button>
        </>
      }
    >
      {action.message && <p>{action.message}</p>}
      <p className="muted">{action.isPreview ? "What changes" : "This runs on the server"}
        {action.target ? <> as <span className="mono">{action.target}</span></> : null}:</p>
      {action.isPreview ? <Diff text={action.command} /> : <pre className="command">{action.command}</pre>}
      {action.then && (
        <>
          <p className="muted">Then:</p>
          <pre className="command">{action.then}</pre>
        </>
      )}
      {action.typed !== null && (
        <label className="field">
          <span className="field-label">Type <span className="mono">{action.typed}</span> to confirm</span>
          <input value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" spellCheck={false}
                 aria-label={`Type ${action.typed} to confirm`}
                 onKeyDown={(e) => e.key === "Enter" && !action.destructive && void run()} />
        </label>
      )}
      {error && <Notice tone="danger">{error}</Notice>}
    </Modal>
  );
}
