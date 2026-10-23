import { useCallback, useEffect, useRef, useState } from "react";

/** The current hash route, e.g. "/servers/ABC" for "#/servers/ABC". */
export function useRoute(): [string, (to: string) => void] {
  const read = () => window.location.hash.replace(/^#/, "") || "/";
  const [route, setRoute] = useState(read);
  useEffect(() => {
    const changed = () => setRoute(read());
    window.addEventListener("hashchange", changed);
    return () => window.removeEventListener("hashchange", changed);
  }, []);
  const go = useCallback((to: string) => {
    window.location.hash = to;
  }, []);
  return [route, go];
}

/** Calls `load` now and every `interval` ms while mounted (and while the tab is visible); keeps the last result. */
export function usePoll<T>(load: () => Promise<T>, interval: number, deps: unknown[]): {
  data: T | undefined;
  error: string | undefined;
  reload: () => Promise<void>;
} {
  const [data, setData] = useState<T>();
  const [error, setError] = useState<string>();
  const loadRef = useRef(load);
  loadRef.current = load;
  const reload = useCallback(async () => {
    try {
      setData(await loadRef.current());
      setError(undefined);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);
  useEffect(() => {
    setData(undefined);
    let stopped = false;
    void reload();
    const timer = window.setInterval(() => {
      if (!stopped && document.visibilityState === "visible") void reload();
    }, interval);
    return () => {
      stopped = true;
      window.clearInterval(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return { data, error, reload };
}

/** Seconds since the epoch, ticking once a second (uptime and the server clock count up between polls). */
export function useNow(): number {
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now() / 1000), 1000);
    return () => window.clearInterval(timer);
  }, []);
  return now;
}
