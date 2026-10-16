// The API's JSON, as rackoon/app returns it (camelCase, like spec/models.schema.json). Nothing here is computed in
// the browser: the backend works out attention, palettes, explanations and totals.

export interface Server {
  id: string;
  name: string;
  host: string;
  user?: string;
  port?: number;
  sshConfigAlias?: string;
  identityFile?: string;
  keyId: string | null;
}

export interface Disk {
  filesystem: string;
  mount: string;
  totalBytes: number;
  usedBytes: number;
  usePercent: number;
}

export interface Overview {
  hostname: string;
  os: { id: string; name: string; version: string; prettyName: string };
  uptimeSeconds: number;
  load1: number;
  load5: number;
  load15: number;
  cores: number;
  memory: { totalBytes: number; availableBytes: number };
  disks: Disk[];
  rebootRequired: boolean;
  unhealthyContainers: string[];
  pendingUpdates: number;
  securityUpdates: number;
  vendor: string;
  product: string;
  machineID: string;
  kernel: string;
  bootID: string;
  ipAddress?: string;
  tailscaleIP?: string;
  serverTime: number;
  utcOffsetSeconds: number;
  timeZoneName: string;
}

export interface Derived {
  memoryUsedBytes: number;
  memoryUsedFraction: number;
  modelName: string;
  fullestDisk: Disk | null;
}

export interface AttentionItem {
  id: string;
  severity: "info" | "warning" | "critical";
  message: string;
  short: string;
  red: boolean;
  fix: string;
}

export type Connection = "ok" | "connecting" | "hostKeyUnknown" | "hostKeyChanged" | "authFailed" | "unreachable" | "failed";

export interface ServerState {
  serverId: string;
  connection: Connection;
  overview: Overview | null;
  derived: Derived | null;
  cpuPercent: number | null;
  attention: AttentionItem[];
  error: string | null;
  failure: { kind: string; headline: string; advice: string } | null;
  updatedAt: number | null;
  isStale: boolean;
  isUnraid: boolean;
  polling: "watched" | "background";
}

export interface HealthSample {
  at: number;
  up: boolean;
  cpuPercent?: number;
  memoryFraction?: number;
  diskFraction?: number;
}

export interface FleetRow {
  id: string;
  name: string;
  host: string;
  connection: Connection;
  error: string | null;
  isStale: boolean;
  updatedAt: number | null;
  cpuPercent: number | null;
  overview: Overview | null;
  derived: Derived | null;
  attentionCount: number;
  redCount: number;
  history: HealthSample[];
  uptimeFraction: number | null;
}

export interface FleetTotals {
  servers: number;
  online: number;
  cpuPercent?: number;
  memoryUsed: number;
  memoryTotal: number;
  diskUsed: number;
  diskTotal: number;
  updates: number;
  securityUpdates: number;
  rebootRequired: number;
  unhealthyContainers: number;
}

export interface Fleet {
  totals: FleetTotals;
  servers: FleetRow[];
}

export interface AuthState {
  setupRequired: boolean;
  passwordManaged: boolean;
  totpEnabled: boolean;
  authenticated: boolean;
  forwardAuth: boolean;
  demo: boolean;
  user?: string;
  via?: "session" | "forwardAuth" | "demo";
  csrf?: string;
}

export interface Role { mark: string; label: string; fill: string; onFill: string }

export interface Palette {
  background: string;
  sidebar: string;
  card: string;
  selection: string;
  border: string;
  textPrimary: string;
  textSecondary: string;
  textMuted: string;
  textDim: string;
  accent: string;
  accentText: string;
  ok: string;
  warn: string;
  danger: string;
  idle: string;
  warnBackground: string;
  warnBorder: string;
  warnChip: string;
  warnText: string;
  okRole: Role;
  warnRole: Role;
  dangerRole: Role;
  info: Role;
  scopeLocal: Role;
  scopeTailscale: Role;
  scopePublic: Role;
  series: Role[];
  isDark: boolean;
}

export interface ResolvedTheme {
  themeId: string;
  palette: Palette;
  terminal: { background: string; foreground: string; cursor: string; selection: string; ansi: string[] };
}

export interface Appearance {
  selection: string;
  themes: { id: string; name: string; family: string; appearance: "dark" | "light" }[];
  dark: ResolvedTheme;
  light: ResolvedTheme;
}

export interface Safety {
  readOnly: boolean;
  auto: string;
  options: { key: string; label: string }[];
}

export interface CheckResult {
  status: "ok" | "hostKeyUnknown" | "hostKeyChanged" | "authFailed" | "unreachable" | "failed";
  message: string;
  hostKey?: { keyType: string; fingerprint: string };
  trusted?: { keyType: string; fingerprint: string };
  scanId?: string;
}

export interface KeyInfo {
  id: string;
  name: string;
  keyType: string;
  fingerprint: string;
  publicKey: string;
  createdAt: string;
  source: "generated" | "imported";
}

export interface SSHConfigHost {
  alias: string;
  hostName: string | null;
  user: string | null;
  port: number | null;
  keyFile: string | null;
  supported: boolean;
  alreadyAdded: boolean;
  note: string | null;
}

export interface PendingAction {
  id: string;
  summary: string;
  command: string;
  risk: "read" | "mutate";
  destructive: boolean;
}
