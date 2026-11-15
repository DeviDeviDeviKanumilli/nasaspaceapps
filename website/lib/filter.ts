import type { Atlas, AtlasRecord, Candidate, RecordKind } from "./types";
import type { Area } from "@/components/Globe";
import { haversineKm, pointInRing } from "./geo";

export interface Filters {
  body: "all" | "Moon" | "Mars";
  kinds: Record<RecordKind, boolean>;
  /** empty = every reference */
  refs: string[];
  insideYardstick: boolean;
  tiers: string[];
  area: Area | null;
}

export const DEFAULT_FILTERS: Filters = { body: "all", kinds: { terrain: true, rock: true, geo2: true }, refs: [], insideYardstick: false, tiers: [], area: null };

export function inArea(a: Area, lat: number, lon: number): boolean {
  if (a.type === "circle") return haversineKm(a.lat, a.lon, lat, lon) <= a.radiusKm;
  if (a.type === "rect") return lat >= a.south && lat <= a.north && lon >= a.west && lon <= a.east;
  return pointInRing(lon, lat, a.ring);
}

export interface FilterResult {
  records: AtlasRecord[];
  ids: Set<string>;
  /** records dropped because a condition needs a value the record does not carry */
  notApplicable: number;
}

export function applyFilters(atlas: Atlas, f: Filters): FilterResult {
  const out: AtlasRecord[] = [];
  let notApplicable = 0;
  for (const r of atlas.records) {
    if (f.body !== "all" && r.body !== f.body) continue;
    if (!f.kinds[r.kind]) continue;
    if (f.refs.length && !f.refs.includes(r.referenceId)) continue;
    if (f.area && !inArea(f.area, r.lat, r.lon)) continue;
    if (f.insideYardstick) {
      const v = (r.raw as Candidate).inside_yardstick;
      if (r.kind !== "terrain" || typeof v !== "boolean") { notApplicable++; continue; }
      if (!v) continue;
    }
    if (f.tiers.length) {
      const t = (r.raw as Candidate).tier;
      if (r.kind !== "rock" || typeof t !== "string") { notApplicable++; continue; }
      if (!f.tiers.includes(t)) continue;
    }
    out.push(r);
  }
  return { records: out, ids: new Set(out.map((r) => r.id)), notApplicable };
}

export function activeFilterCount(f: Filters): number {
  let n = 0;
  if (f.body !== "all") n++;
  if (!f.kinds.terrain || !f.kinds.rock || !f.kinds.geo2) n++;
  if (f.refs.length) n++;
  if (f.insideYardstick) n++;
  if (f.tiers.length) n++;
  if (f.area) n++;
  return n;
}

export function describeArea(a: Area): string {
  if (a.type === "circle") return `within ${a.radiusKm} km of ${a.lat.toFixed(3)}°, ${a.lon.toFixed(3)}°`;
  if (a.type === "rect") return `box ${a.south.toFixed(2)}° to ${a.north.toFixed(2)}° lat, ${a.west.toFixed(2)}° to ${a.east.toFixed(2)}° lon`;
  return `drawn polygon (${a.ring.length} vertices)`;
}
