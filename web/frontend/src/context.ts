import { createContext, useContext } from "react";
import type { Appearance, AuthState, Fleet, Safety, Server } from "./types";

export interface AppData {
  auth: AuthState;
  servers: Server[];
  fleet: Fleet | undefined;
  safety: Safety | undefined;
  appearance: Appearance | undefined;
  reloadServers: () => Promise<void>;
  reloadFleet: () => Promise<void>;
  setSafety: (s: Safety) => void;
  setAppearance: (a: Appearance) => void;
  signOut: () => Promise<void>;
  go: (route: string) => void;
}

export const AppContext = createContext<AppData | null>(null);

export function useApp(): AppData {
  const data = useContext(AppContext);
  if (!data) throw new Error("useApp outside AppContext");
  return data;
}
