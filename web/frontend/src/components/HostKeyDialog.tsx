import { useEffect, useState } from "react";
import { api, ApiError } from "../api";
import type { CheckResult, Server } from "../types";
import { Button, Modal, Notice, Spinner } from "./ui";

/**
 * Trust on first use, done carefully: the backend scans the key, the user compares the fingerprint with the server's
 * own, and only that exact scanned key is trusted. A changed key is shown and never offered.
 */
export function HostKeyDialog(props: { server: Server; onClose: (trusted: boolean) => void }) {
  const [scan, setScan] = useState<CheckResult>();
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    api.post<CheckResult>(`/api/servers/${props.server.id}/host-key/scan`).then(setScan, (e: unknown) =>
      setError(e instanceof ApiError ? e.message : String(e)));
  }, [props.server.id]);
  const trust = async () => {
    if (!scan?.scanId || !scan.hostKey) return;
    setBusy(true);
    try {
      await api.post(`/api/servers/${props.server.id}/host-key/trust`, {
        scanId: scan.scanId,
        fingerprint: scan.hostKey.fingerprint,
      });
      props.onClose(true);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e));
      setBusy(false);
    }
  };
  const canTrust = scan?.status === "hostKeyUnknown" && !!scan.scanId;
  return (
    <Modal
      title={`Host key for ${props.server.name}`}
      onClose={() => props.onClose(false)}
      footer={
        <>
          <Button onClick={() => props.onClose(false)}>{canTrust ? "Cancel" : "Close"}</Button>
          {canTrust && <Button kind="primary" disabled={busy} onClick={() => void trust()}>Trust This Key</Button>}
        </>
      }
    >
      {!scan && !error && <Spinner />}
      {error && <Notice tone="danger">{error}</Notice>}
      {scan?.status === "hostKeyUnknown" && scan.hostKey && (
        <>
          <p>Rackoon has not connected to <strong>{props.server.host}</strong> before. Compare this fingerprint with the
            one the server itself shows before trusting it:</p>
          <pre className="command">{scan.hostKey.keyType} {scan.hostKey.fingerprint}</pre>
          <p className="muted">On the server: <code>ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub</code></p>
        </>
      )}
      {scan?.status === "hostKeyChanged" && (
        <Notice tone="danger" title="The host key changed. Rackoon won't connect.">
          <p>Trusted: <code>{scan.trusted?.fingerprint}</code></p>
          <p>Now shown: <code>{scan.hostKey?.fingerprint}</code></p>
          <p>If the server was reinstalled, check the new fingerprint on the server, then remove its entry from
            known_hosts.json in Rackoon's data folder. Otherwise someone may be in between: don't sign in.</p>
        </Notice>
      )}
      {scan?.status === "ok" && <Notice tone="ok">The host key is already trusted ({scan.hostKey?.fingerprint}).</Notice>}
      {scan?.status === "unreachable" && <Notice tone="danger" title="Can't reach the server">{scan.message}</Notice>}
    </Modal>
  );
}
