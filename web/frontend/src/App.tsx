import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api, setCsrf, whenSignedOut } from "./api";
import { Sidebar } from "./components/Sidebar";
import { Empty, Spinner } from "./components/ui";
import { AppContext, type AppData } from "./context";
import { usePoll, useRoute } from "./hooks";
import { DashboardScreen } from "./screens/Dashboard";
import { OverviewScreen } from "./screens/Overview";
import { SettingsScreen } from "./screens/Settings";
import { SignInScreen } from "./screens/SignIn";
// xterm.js is most of the bundle: load it only when a terminal is opened.
const TerminalScreen = lazy(() => import("./screens/Terminal").then((m) => ({ default: m.TerminalScreen })));
import { applyAppearance } from "./theme";
import type { Appearance, AuthState, Fleet, Safety, Server } from "./types";

const LAST_SERVER = "rackoon.lastServer";

function remembered(): string | undefined {
  try {
    return window.localStorage.getItem(LAST_SERVER) ?? undefined;
  } catch {
    return undefined;
  }
}

function remember(id: string): void {
  try {
    window.localStorage.setItem(LAST_SERVER, id);
  } catch {
    // a private window: the app just starts on the dashboard next time
  }
}

/** Tells the backend the user is here (Read-only's idle timer), at most once a minute, only while changes are on. */
function useActivity(enabled: boolean): void {
  const last = useRef(0);
  useEffect(() => {
    if (!enabled) return;
    const ping = () => {
      if (Date.now() - last.current < 60_000) return;
      last.current = Date.now();
      void api.post("/api/activity").catch(() => undefined);
    };
    window.addEventListener("pointerdown", ping);
    window.addEventListener("keydown", ping);
    return () => {
      window.removeEventListener("pointerdown", ping);
      window.removeEventListener("keydown", ping);
    };
  }, [enabled]);
}

function Shell(props: { auth: AuthState; onSignedOut: () => void }) {
  const [route, go] = useRoute();
  const [servers, setServers] = useState<Server[]>();
  const [safety, setSafety] = useState<Safety>();
  const [appearance, setAppearanceState] = useState<Appearance>();
  const reloadServers = useCallback(async () => setServers(await api.get<Server[]>("/api/servers")), []);
  const { data: fleet, reload: reloadFleet } = usePoll(() => api.get<Fleet>("/api/fleet"), 10_000, []);
  const { data: polledSafety } = usePoll(() => api.get<Safety>("/api/safety"), 30_000, []);
  useEffect(() => {
    void reloadServers();
    void api.get<Appearance>("/api/appearance").then((a) => {
      setAppearanceState(a);
      applyAppearance(a);
    });
  }, [reloadServers]);
  useEffect(() => polledSafety && setSafety(polledSafety), [polledSafety]);
  useActivity(safety?.readOnly === false);

  const setAppearance = useCallback((a: Appearance) => {
    setAppearanceState(a);
    applyAppearance(a);
  }, []);

  const data: AppData | null = useMemo(() => servers === undefined ? null : ({
    auth: props.auth, servers, fleet, safety, appearance, reloadServers, reloadFleet, setSafety, setAppearance, go,
    signOut: async () => {
      await api.post("/api/auth/logout").catch(() => undefined);
      props.onSignedOut();
    },
  }), [props, servers, fleet, safety, appearance, reloadServers, reloadFleet, setAppearance, go]);

  // Routes: /dashboard, /servers/<id>[/terminal], /settings/<tab>[/<sub>]; "/" opens the last server or the dashboard.
  const parts = route.split("/").filter(Boolean);
  useEffect(() => {
    if (!servers || parts.length > 0) return;
    const last = remembered();
    go(last && servers.some((s) => s.id === last) ? `/servers/${last}` : "/dashboard");
  }, [servers, parts.length, go]);
  const serverId = parts[0] === "servers" ? parts[1] : undefined;
  useEffect(() => {
    if (serverId) remember(serverId);
  }, [serverId]);

  if (!data) return <div className="loading"><Spinner /></div>;
  const server = serverId ? servers!.find((s) => s.id === serverId) : undefined;
  let screen;
  if (parts[0] === "servers") {
    screen = server && parts[2] === "terminal"
      ? <Suspense fallback={<div className="page"><Spinner /></div>}><TerminalScreen key={server.id} server={server} /></Suspense>
           : server ? <OverviewScreen key={server.id} server={server} />
                    : <div className="page"><Empty title="No such server"><a href="#/dashboard">Back to the dashboard</a></Empty></div>;
  } else if (parts[0] === "settings") {
    screen = <SettingsScreen tab={parts[1] ?? "servers"} sub={parts[2]} />;
  } else {
    screen = <DashboardScreen />;
  }
  return (
    <AppContext.Provider value={data}>
      <div className="app">
        <Sidebar route={route} selected={serverId ?? remembered()} />
        <main className="main">{screen}</main>
      </div>
    </AppContext.Provider>
  );
}

export function App() {
  const [auth, setAuth] = useState<AuthState>();
  const load = useCallback(async () => {
    const state = await api.get<AuthState>("/api/auth/state");
    setCsrf(state.csrf);
    setAuth(state);
  }, []);
  useEffect(() => {
    whenSignedOut(() => void load());
    void load();
  }, [load]);
  if (!auth) return <div className="loading"><Spinner /></div>;
  if (!auth.authenticated) return <SignInScreen auth={auth} onSignedIn={() => void load()} />;
  return <Shell auth={auth} onSignedOut={() => void load()} />;
}
