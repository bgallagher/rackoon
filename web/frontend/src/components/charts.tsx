import type { HealthSample } from "../types";

/** An Uptime-Kuma-style bar: one slot per check, newest on the right, empty slots for checks not made yet. */
export function Heartbeat(props: { samples: HealthSample[]; slots?: number }) {
  const slots = props.slots ?? 60;
  const recent = props.samples.slice(-slots);
  const pad = slots - recent.length;
  return (
    <div className="heartbeat" role="img"
         aria-label={`${recent.filter((s) => s.up).length} of ${recent.length} checks answered`}>
      {Array.from({ length: pad }, (_, i) => <span key={`e${i}`} className="beat beat-none" />)}
      {recent.map((s, i) => (
        <span key={i} className={`beat ${s.up ? "beat-up" : "beat-down"}`}
              title={`${new Date(s.at * 1000).toLocaleTimeString()}: ${s.up ? "answered" : "no answer"}`} />
      ))}
    </div>
  );
}

/** A fixed 0–100 sparkline (Beszel-style), so servers compare at a glance. */
export function Sparkline(props: { values: (number | undefined)[]; label: string; tone?: "series0" | "series1" }) {
  const w = 120;
  const h = 28;
  const points = props.values
    .map((v, i) => (v === undefined ? null : [(i / Math.max(1, props.values.length - 1)) * w, h - (Math.min(100, Math.max(0, v)) / 100) * h]))
    .filter((p): p is number[] => p !== null);
  const last = props.values.filter((v) => v !== undefined).at(-1);
  return (
    <svg className={`spark spark-${props.tone ?? "series0"}`} viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" role="img"
         aria-label={`${props.label}${last !== undefined ? `: ${Math.round(last)}%` : ": no data"}`}>
      <title>{`${props.label}${last !== undefined ? ` ${Math.round(last)}%` : ""}`}</title>
      <line x1="0" y1={h - 0.5} x2={w} y2={h - 0.5} className="spark-base" />
      {points.length > 1 && <polyline points={points.map((p) => p.join(",")).join(" ")} />}
      {points.length === 1 && points[0] && <circle cx={points[0][0]} cy={points[0][1]} r="2" />}
    </svg>
  );
}
