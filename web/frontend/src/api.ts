// The one way the browser talks to the backend: same-origin JSON, the session cookie, and the CSRF token on every
// change. A 401 sends the app back to the sign-in page.

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

let csrf: string | undefined;
let onSignedOut: (() => void) | undefined;

export function setCsrf(token: string | undefined): void {
  csrf = token;
}

/** For requests that can't go through `api` (an upload with progress). */
export function csrfToken(): string | undefined {
  return csrf;
}

export function whenSignedOut(handler: () => void): void {
  onSignedOut = handler;
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { Accept: "application/json" };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (method !== "GET" && csrf) headers["X-Rackoon-CSRF"] = csrf;
  let response: Response;
  try {
    response = await fetch(path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      credentials: "same-origin",
    });
  } catch {
    throw new ApiError(0, "offline", "Rackoon's server can't be reached.");
  }
  const text = await response.text();
  const data: unknown = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const error = (data ?? {}) as { error?: string; message?: string };
    if (response.status === 401 && error.error === "signedOut") onSignedOut?.();
    throw new ApiError(response.status, error.error ?? "failed", error.message ?? `Request failed (${response.status})`);
  }
  return data as T;
}

export const api = {
  get: <T>(path: string) => request<T>("GET", path),
  post: <T>(path: string, body: unknown = {}) => request<T>("POST", path, body),
  put: <T>(path: string, body: unknown) => request<T>("PUT", path, body),
  del: <T>(path: string) => request<T>("DELETE", path),
};
