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
  reboot?: RebootState | null;
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
  highlightOutput: boolean;
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
  /** The exact command, or its readable preview (a diff) when `isPreview`. */
  command: string;
  isPreview: boolean;
  risk: "read" | "mutate";
  destructive: boolean;
  title: string;
  message: string | null;
  /** A word the user must type before the button works (the backend checks it too). */
  typed: string | null;
  /** The command that follows once this one succeeded (the `up -d` after a save). */
  then: string | null;
  target: string | null;
  /** A dry run's output (what a Commands entry would affect). */
  details: string | null;
}

export interface TerminalTab {
  id: string;
  serverId: string;
  title: string;
  state: "starting" | "connected" | "reconnecting" | "disconnected" | "exited";
  kind?: "shell" | "command";
  attempt?: number;
  of?: number;
  delay?: number;
  exitCode?: number | null;
}

// --- Docker (stage W5) ------------------------------------------------------------------------------------------

export interface Bookmark {
  href: string;
  name?: string;
  group?: string;
  icon?: string;
  description?: string;
}

export interface Container {
  id: string;
  name: string;
  image: string;
  imageName: string;
  imageTag: string | null;
  state: string;
  health: string;
  status: string;
  ports: { hostPort: number; containerPort: number; proto: string }[];
  project?: string;
  service?: string;
  cpuPercent?: number;
  memoryUsedBytes?: number;
  memoryLimitBytes?: number;
  bookmark?: Bookmark;
  isRunning: boolean;
  isUnhealthy: boolean;
  canRebuild: boolean;
  letter: string;
  hue: number;
}

export interface Stack {
  id: string;
  name: string;
  kind: string;
  isStandalone: boolean;
  workingDir: string | null;
  configFiles: string[];
  statusText: string;
  severity: "ok" | "warning" | "danger" | "idle";
  health?: "running" | "attention" | "stopped";
  running: number;
  stopped: number;
  unhealthy: number;
  total: number;
  hasBookmark: boolean;
  mainWebPort: number | null;
  link: string | null;
  letter: string;
  hue: number;
  images: string[];
  cpuPercent: number | null;
  memoryBytes: number;
  notStarted: boolean;
  removing: boolean;
  busy: boolean;
  containers: Container[];
  // a stack's page only
  composeBlocked?: string | null;
  blocked?: string | null;
  pullable?: string | null;
  folderProblem?: string | null;
  files?: { path: string; name: string; isEnv: boolean }[];
  services?: string[];
}

export interface Run {
  id: string;
  serverId: string;
  scope: string;
  title: string;
  working: string;
  phase: "running" | "succeeded" | "failed" | "cancelled";
  exitCode: number | null;
  message: string | null;
  started: number;
  finished: number | null;
  cols: number;
  rows: number;
  /** sudo wanted a password (or rejected the one given): the page may ask for it. */
  needsPassword: boolean;
  sudo: "accepted" | "rejected" | "refused" | "other_prompt" | "unfinished" | null;
}

export interface BookmarkItem {
  stackId: string;
  stackName: string;
  service: string | null;
  container: string;
  containerId: string;
  bookmark: Bookmark;
  address: string;
  scope: "local" | "tailscale" | "public";
  origin: string | null;
  editable: boolean;
}

export interface DockerTotals {
  stacks: number;
  containers: number;
  running: number;
  unhealthy: number;
  cpuPercentOfHost: number | null;
  memoryBytes: number;
  memoryFractionOfHost: number | null;
  dataDisk: Disk | null;
}

export interface DockerState {
  serverId: string;
  status: "loading" | "ready" | "notInstalled" | "failed";
  error: string | null;
  problem: "notInstalled" | "permission" | "daemon" | "malformed" | "connection" | null;
  updatedAt: number | null;
  summary: string | null;
  totals: DockerTotals | null;
  stacks: Stack[];
  running: Run | null;
  readOnly: boolean;
  bookmarks?: BookmarkItem[];
  elevation?: { until: number | null; lockReason: string | null; generation: number };
}

export interface StackPage {
  stack: Stack;
  run: Run | null;
  updatedAt: number | null;
  error: string | null;
}

export interface CheckRow {
  id: string;
  state: "pass" | "fail" | "warn" | "skipped" | "running";
  title: string;
  detail: string;
}

export interface Issue {
  severity: "error" | "warning";
  line: number | null;
  message: string;
}

export interface EditorFile {
  path: string;
  name: string;
  isEnv: boolean;
  status: "file" | "missing" | "tooLarge";
  content: string | null;
  sha: string | null;
}

export interface Verdict {
  rows: CheckRow[];
  canSave: boolean;
  blocked: string | null;
  changedLines: number[];
  errorLines: number[];
  changeCount: number;
  issues: Issue[];
  checked: boolean;
}

/** What a confirmed Docker action came to: a run that streams, and/or a file outcome. */
export interface ActionResult {
  run?: Run;
  outcome?: "saved" | "changed" | "invalid" | "created" | "exists";
  message?: string;
  issues?: Issue[];
  stackId?: string;
  sha?: string;
}

export interface FleetDocker {
  servers: (DockerState & { server: { id: string; name: string }; bookmarks: BookmarkItem[]; linkHost: string | null })[];
}

// --- Updates and reboot (stage W6) ------------------------------------------------------------------------------

export interface RebootState {
  phase: "waiting" | "back" | "timedOut";
  started: number;
  elapsed: number | null;
}

export interface PendingUpdate {
  name: string;
  suite: string;
  newVersion: string;
  oldVersion?: string;
  architecture: string;
  isSecurity: boolean;
}

export interface UpdatesState {
  serverId: string;
  status: "loading" | "ready" | "notInstalled" | "failed";
  error: string | null;
  updatedAt: number | null;
  readOnly: boolean;
  packages: PendingUpdate[];
  held: string[];
  refreshedAt: number | null;
  rebootRequired: boolean;
  securityCount: number;
  subtitle: string | null;
  refreshedText: string | null;
  staleness: string | null;
  securityHint: string | null;
  run: Run | null;
  reboot: RebootState | null;
}

// --- Stage W7 ---------------------------------------------------------------------------------------------------

export interface LibraryParam { id: string; label: string; kind: "container" | "hostname"; placeholder: string }

export interface LibraryCommand {
  id: string;
  title: string;
  group: string;
  summary: string;
  risk: "read" | "mutate";
  root: boolean;
  needs: string | null;
  warning: string | null;
  interactive: boolean;
  params: LibraryParam[];
  readable: string;
  readablePreview: string | null;
  full: string | null;
}

export interface Service {
  id: string;
  kind: "system" | "user" | "process";
  unit: string | null;
  name: string;
  detail: string;
  product: string | null;
  status: "running" | "starting" | "restarting" | "stopping" | "stopped" | "failed";
  subState: string;
  result: string | null;
  enabledAtBoot: boolean | null;
  activeSeconds: number | null;
  memoryBytes: number | null;
  restarts: number;
  ports: { address: string; port: number }[];
  path: string | null;
  isPlumbing: boolean;
  visibleByDefault: boolean;
  visible: boolean;
  chosen: boolean;
  isProblem: boolean;
  actions: string[];
  canFollow: boolean;
  links: string[];
}

export interface ServicesState {
  serverId: string;
  status: "ready" | "failed" | "loading";
  error: string | null;
  updatedAt: number;
  isRoot: boolean | null;
  hasSystemd: boolean | null;
  services: Service[];
  runs: Record<string, Run>;
}

export interface FileEntry {
  name: string;
  kind: "file" | "directory" | "symlink" | "other";
  linkTarget: string | null;
  linksToDirectory: boolean;
  size: number;
  modified: number;
  permissions: string;
  owner: string;
  isDirectory: boolean;
  deleteProblem: string | null;
}

export interface Listing {
  path: string;
  parent: string | null;
  truncated: boolean;
  crumbs: { name: string; path: string }[];
  entries: FileEntry[];
}

export interface Alert {
  id: string;
  serverId: string;
  serverName: string;
  source: string;
  key: string;
  category: string;
  severity: "info" | "warning" | "critical";
  title: string;
  detail: string | null;
  fix: { screen: string; target: string | null } | null;
  firstSeen: number;
  lastSeen: number;
  resolvedAt: number | null;
  acknowledged: boolean;
  muted: boolean;
}

export interface NotificationSettings {
  enabled: boolean;
  ntfyUrl: string;
  hasNtfyToken: boolean;
  webhookUrl: string;
  hasWebhookSecret: boolean;
  publicUrl: string;
  pushSubscriptions: number;
  lastError: string | null;
}

export interface AlertsState {
  active: Alert[];
  muted: Alert[];
  history: Alert[];
  unseen: number;
  worst: "warning" | "critical" | null;
  lastSweep: number | null;
  sweeping: boolean;
  notifications: NotificationSettings;
}

export interface AlertSummary {
  servers: Record<string, { unseen: number; worst: string | null }>;
  unseen: number;
  worst: string | null;
}

export interface SearchItem {
  group: string;
  id: string;
  title: string;
  subtitle: string;
  serverName: string | null;
  target: { kind: "server" | "stack" | "service" | "bookmark" | "command" | "alert"; server: string; id: string };
  tone: string | null;
  link: string | null;
}
