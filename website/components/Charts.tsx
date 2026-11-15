"use client";
// SVG charts drawn only from values in the loaded bundle. Every chart has an axis, units and a source note.
import type { Band } from "@/lib/types";

const MOON = "#567C94";
const MARS = "#B66F54";

function ticks(max: number): number[] {
  const step = max <= 6 ? 1 : max <= 12 ? 2 : max <= 30 ? 5 : 10;
  const out: number[] = [];
  for (let v = 0; v <= max + 1e-9; v += step) out.push(v);
  return out;
}

export interface BandRow {
  label: string;
  band?: Band;
  value?: number | null;
}

/** Reference percentile bands (p10–p90, p25–p75, median) per baseline, with the Earth window's value where one exists. */
export function BandPlot({ rows, body, unit, axisLabel, earthLabel, note }: { rows: BandRow[]; body: string; unit: string; axisLabel: string; earthLabel?: string; note: string }) {
  const col = body === "Moon" ? MOON : MARS;
  const all: number[] = [];
  for (const r of rows) {
    if (r.band) for (const k of ["p10", "p25", "p50", "p75", "p90"] as const) if (typeof r.band[k] === "number") all.push(r.band[k]!);
    if (typeof r.value === "number") all.push(r.value);
  }
  if (!all.length) return <p className="muted">No percentile bands are recorded for this reference.</p>;
  const max = Math.ceil((Math.max(...all) * 1.08) / 2) * 2;
  const W = 520, L = 86, R = 14, rowH = 30, top = 8;
  const H = top + rows.length * rowH + 34;
  const x = (v: number) => L + (v / max) * (W - L - R);
  const hasEarth = rows.some((r) => typeof r.value === "number");
  return (
    <figure className="chart">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${axisLabel}: reference percentile bands${hasEarth ? " and the Earth value" : ""} by baseline`}>
        {ticks(max).map((t) => (
          <g key={t}>
            <line x1={x(t)} x2={x(t)} y1={top} y2={top + rows.length * rowH} className="grid" />
            <text x={x(t)} y={top + rows.length * rowH + 14} textAnchor="middle" className="tick">{t}</text>
          </g>
        ))}
        {rows.map((r, i) => {
          const y = top + i * rowH + rowH / 2;
          const b = r.band;
          return (
            <g key={r.label}>
              <text x={L - 10} y={y + 4} textAnchor="end" className="rowlab">{r.label}</text>
              {b && typeof b.p10 === "number" && typeof b.p90 === "number" && <rect x={x(b.p10)} y={y - 3} width={Math.max(1, x(b.p90) - x(b.p10))} height={6} fill={col} opacity={0.22} />}
              {b && typeof b.p25 === "number" && typeof b.p75 === "number" && <rect x={x(b.p25)} y={y - 7} width={Math.max(1, x(b.p75) - x(b.p25))} height={14} fill={col} opacity={0.45} />}
              {b && typeof b.p50 === "number" && <line x1={x(b.p50)} x2={x(b.p50)} y1={y - 9} y2={y + 9} stroke={col} strokeWidth={2} />}
              {typeof r.value === "number" && (
                <g transform={`translate(${x(r.value)},${y})`}>
                  <path d="M0,-7 L6,0 L0,7 L-6,0 Z" fill="#18252A" stroke="#F7F8F5" strokeWidth={1.5} />
                </g>
              )}
            </g>
          );
        })}
        <text x={(L + W - R) / 2} y={H - 4} textAnchor="middle" className="axis">{axisLabel} ({unit})</text>
      </svg>
      <figcaption>
        <span className="key"><i style={{ background: col, opacity: 0.22 }} />reference 10th–90th percentile</span>
        <span className="key"><i style={{ background: col, opacity: 0.45 }} />25th–75th</span>
        <span className="key"><i className="tickkey" style={{ background: col }} />median</span>
        {hasEarth && <span className="key"><i className="diamond" />{earthLabel ?? "Earth window median"}</span>}
        <span className="note">{note}</span>
      </figcaption>
    </figure>
  );
}

/** Reference connectivity curve: largest connected share of the area below each slope threshold. */
export function ConnectivityChart({ curve, body, baselineM }: { curve: Record<string, number>; body: string; baselineM?: number }) {
  const col = body === "Moon" ? MOON : MARS;
  const pts = Object.entries(curve).map(([k, v]) => [parseFloat(k), v] as [number, number]).filter(([a, b]) => isFinite(a) && isFinite(b)).sort((a, b) => a[0] - b[0]);
  if (pts.length < 2) return null;
  const W = 520, H = 200, L = 46, R = 14, T = 10, B = 40;
  const xmax = Math.max(...pts.map((p) => p[0]));
  const x = (v: number) => L + (v / xmax) * (W - L - R);
  const y = (v: number) => T + (1 - v) * (H - T - B);
  return (
    <figure className="chart">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Connectivity curve of the reference">
        {[0, 0.25, 0.5, 0.75, 1].map((t) => (
          <g key={t}>
            <line x1={L} x2={W - R} y1={y(t)} y2={y(t)} className="grid" />
            <text x={L - 8} y={y(t) + 4} textAnchor="end" className="tick">{t.toFixed(2)}</text>
          </g>
        ))}
        {pts.map(([a]) => <text key={a} x={x(a)} y={H - B + 15} textAnchor="middle" className="tick">{a}</text>)}
        <polyline fill="none" stroke={col} strokeWidth={2} points={pts.map(([a, b]) => `${x(a)},${y(b)}`).join(" ")} />
        {pts.map(([a, b]) => <circle key={a} cx={x(a)} cy={y(b)} r={3} fill={col} />)}
        <text x={(L + W - R) / 2} y={H - 6} textAnchor="middle" className="axis">Slope threshold (degrees{baselineM ? `, ${baselineM} m baseline` : ""})</text>
        <text transform={`translate(12,${(T + H - B) / 2}) rotate(-90)`} textAnchor="middle" className="axis">Largest connected share</text>
      </svg>
      <figcaption><span className="note">Share of the reference area that lies in the single largest connected patch with slope at or below each threshold. Geometry only; it does not model a vehicle or a person.</span></figcaption>
    </figure>
  );
}
