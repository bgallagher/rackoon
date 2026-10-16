import { useState, type FormEvent } from "react";
import { api, ApiError } from "../api";
import { Button, Field, Notice } from "../components/ui";
import type { AuthState } from "../types";

/** First start (setup token from the log) or signing in (password, and a TOTP code when it is on). */
export function SignInScreen(props: { auth: AuthState; onSignedIn: () => void }) {
  const setup = props.auth.setupRequired;
  const [token, setToken] = useState("");
  const [password, setPassword] = useState("");
  const [again, setAgain] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError(undefined);
    if (setup && password !== again) return setError("The two passwords differ.");
    setBusy(true);
    try {
      if (setup) await api.post("/api/auth/setup", { token, password });
      else await api.post("/api/auth/login", { password, code: props.auth.totpEnabled ? code : null });
      props.onSignedIn();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
      setBusy(false);
    }
  };
  return (
    <main className="signin">
      <form className="signin-card" onSubmit={(e) => void submit(e)}>
        <img src="/rackoon-icon.svg" alt="" width="56" height="56" />
        <h1>{setup ? "Set up Rackoon" : "Sign in to Rackoon"}</h1>
        {setup && <p className="muted">Enter the one-time setup token from Rackoon's log (or the setup-token file in its data
          folder), then choose the admin password.</p>}
        {setup && (
          <Field label="Setup token">
            <input value={token} onChange={(e) => setToken(e.target.value)} required autoComplete="off" spellCheck={false} autoFocus />
          </Field>
        )}
        <Field label={setup ? "New password" : "Password"} hint={setup ? "At least 12 characters." : undefined}>
          <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required
                 autoComplete={setup ? "new-password" : "current-password"} autoFocus={!setup} />
        </Field>
        {setup && (
          <Field label="Repeat the password">
            <input type="password" value={again} onChange={(e) => setAgain(e.target.value)} required autoComplete="new-password" />
          </Field>
        )}
        {!setup && props.auth.totpEnabled && (
          <Field label="Code from your authenticator app">
            <input value={code} onChange={(e) => setCode(e.target.value)} inputMode="numeric" autoComplete="one-time-code" required />
          </Field>
        )}
        {error && <Notice tone="danger">{error}</Notice>}
        <Button kind="primary" type="submit" disabled={busy}>{setup ? "Set Password" : "Sign In"}</Button>
        {window.location.protocol === "http:" && !["localhost", "127.0.0.1", "[::1]"].includes(window.location.hostname) && (
          <Notice tone="warn" title="This page isn't on HTTPS">
            Browsers only keep Rackoon's sign-in cookie over HTTPS (or on localhost). Put Rackoon behind
            <code> tailscale serve</code> or another TLS proxy.
          </Notice>
        )}
      </form>
    </main>
  );
}
