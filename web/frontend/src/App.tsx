import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api, setCsrf, whenSignedOut } from "./api";
import { Sidebar } from "./components/Sidebar";
import { Empty, Spinner } from "./components/ui";
import { AppContext, type AppData } from "./context";
import { usePoll, useRoute } from "./hooks";
import { AlertsScreen } from "./screens/Alerts";
import { BookmarksScreen } from "./screens/Bookmarks";
import { DashboardScreen } from "./screens/Dashboard";
import { OverviewScreen } from "./screens/Overview";
import { SettingsScreen } from "./screens/Settings";
import { SignInScreen } from "./screens/SignIn";
// xterm.js is most of the bundle: load it only when a terminal is opened.
const TerminalScreen = lazy(() => import("./screens/Terminal").then((m) => ({ default: m.TerminalScreen })));
const DockerScreen = lazy(() => import("./screens/Docker").then((m) => ({ default: m.DockerScreen })));
const StackScreen = lazy(() => import("./screens/Docker").then((m) => ({ default: m.StackScreen })));
const UpdatesScreen = lazy(() => import("./screens/Updates").then((m) => ({ default: m.UpdatesScreen })));
const CommandsScreen = lazy(() => import("./screens/Commands").then((m) => ({ default: m.CommandsScreen })));
const ServicesScreen = lazy(() => import("./screens/Services").then((m) => ({ default: m.ServicesScreen })));
const FilesScreen = lazy(() => import("./screens/Files").then((m) => ({ default: m.FilesScreen })));
const AddContainerScreen = lazy(() => import("./screens/AddContainer").then((m) => ({ default: m.AddContainerScreen })));
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

  // Routes: /dashboard[/<page>], /servers/<id>[/terminal|/docker[/add|/stack/<id>]|/bookmarks|/updates|/services[/<q>]|/commands[/<id>]|/files|/alerts], /settings/<tab>[/<sub>]; "/" opens the last server or the dashboard.
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
    const lazyScreen = (node: JSX.Element) => <Suspense fallback={<div className="page"><Spinner /></div>}>{node}</Suspense>;
    if (!server) {
      screen = <div className="page"><Empty title="No such server"><a href="#/dashboard">Back to the dashboard</a></Empty></div>;
    } else if (parts[2] === "terminal") {
      screen = lazyScreen(<TerminalScreen key={server.id} server={server} />);
    } else if (parts[2] === "docker" && parts[3] === "stack" && parts[4]) {
      const stackId = decodeURIComponent(parts.slice(4).join("/"));
      screen = lazyScreen(<StackScreen key={`${server.id}/${stackId}`} server={server} stackId={stackId} />);
    } else if (parts[2] === "docker" && parts[3] === "add") {
      screen = lazyScreen(<AddContainerScreen key={server.id} server={server} />);
    } else if (parts[2] === "docker") {
      screen = lazyScreen(<DockerScreen key={server.id} server={server} />);
    } else if (parts[2] === "updates") {
      screen = lazyScreen(<UpdatesScreen key={server.id} server={server} />);
    } else if (parts[2] === "commands") {
      screen = lazyScreen(<CommandsScreen key={server.id} server={server} select={parts[3]} />);
    } else if (parts[2] === "services") {
      screen = lazyScreen(<ServicesScreen key={server.id} server={server} focus={parts[3] ? decodeURIComponent(parts[3]) : undefined} />);
    } else if (parts[2] === "files") {
      screen = lazyScreen(<FilesScreen key={server.id} server={server} />);
    } else if (parts[2] === "alerts") {
      screen = <AlertsScreen key={server.id} serverId={server.id} />;
    } else if (parts[2] === "bookmarks") {
      screen = <BookmarksScreen key={server.id} server={server} />;
    } else {
      screen = <OverviewScreen key={server.id} server={server} />;
    }
  } else if (parts[0] === "settings") {
    screen = <SettingsScreen tab={parts[1] ?? "servers"} sub={parts[2]} />;
  } else {
    screen = <DashboardScreen page={parts[1]} />;
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
