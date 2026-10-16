import { useState } from "react";
import { api, ApiError } from "../api";
import type { PendingAction } from "../types";
import { Button, Modal, Notice } from "./ui";

/**
 * Shows exactly what will run on the server (the backend's pending action) and runs it only on "Run Command".
 * A destructive action's button is red and Return does not press it: only a click does, and Esc cancels.
 */
export function ConfirmSheet(props: { action: PendingAction; onDone: (result: unknown) => void; onCancel: () => void }) {
  const [error, setError] = useState<string>();
  const [running, setRunning] = useState(false);
  const { action } = props;
  const cancel = () => {
    void api.post(`/api/actions/${action.id}/cancel`).catch(() => undefined);
    props.onCancel();
  };
  const run = async () => {
    setRunning(true);
    setError(undefined);
    try {
      const r = await api.post<{ result: unknown }>(`/api/actions/${action.id}/confirm`);
      props.onDone(r.result);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e));
      setRunning(false);
    }
  };
  return (
    <Modal
      title={action.summary}
      onClose={cancel}
      footer={
        <>
          <Button onClick={cancel}>Cancel</Button>
          <Button kind={action.destructive ? "danger" : "primary"} type={action.destructive ? "button" : "submit"}
                  disabled={running} onClick={() => void run()}>
            Run Command
          </Button>
        </>
      }
    >
      <p className="muted">This runs on the server:</p>
      <pre className="command">{action.command}</pre>
      {error && <Notice tone="danger">{error}</Notice>}
    </Modal>
  );
}
