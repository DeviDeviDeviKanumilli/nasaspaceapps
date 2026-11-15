// Typed read adapter with runtime validation. Renders whatever the bundle contains; records what is missing in `issues`.
import type { Atlas, AtlasRecord, Bundle, Candidate, CoverageTile, GeoReference, GeoUnit, TerrainReference } from "./types";
import { parseTileName } from "./geo";

type Derived = { note?: string; terrain_method?: string; rock_method?: string; footprints?: Record<string, { kind: string; ring: [number, number][] }> };

const isNum = (v: unknown): v is number => typeof v === "number" && isFinite(v);

function bodyOf(v: unknown): "Moon" | "Mars" | "Unknown" {
  return v === "Moon" || v === "Mars" ? v : "Unknown";
}

export function buildAtlas(bundle: Bundle, derived: Derived | null): Atlas {
  const issues: string[] = [];
  if (bundle.schema_version !== "1.0") issues.push(`Bundle schema_version is "${bundle.schema_version ?? "missing"}"; this site was written for "1.0".`);
  if (!bundle.run?.manifest_describe_as) issues.push("run.manifest_describe_as is missing; coverage statement cannot be shown.");

  const terrainRefs = new Map<string, TerrainReference>();
  for (const r of bundle.references ?? []) {
    if (!r || typeof r.id !== "string") { issues.push("A terrain reference without an id was skipped."); continue; }
    terrainRefs.set(r.id, r);
  }
  const geoRefs = new Map<string, GeoReference>();
  for (const r of bundle.geology_v2?.references ?? []) {
    if (!r || typeof r.id !== "string") { issues.push("A geology reference without an id was skipped."); continue; }
    geoRefs.set(r.id, r);
  }

  const records: AtlasRecord[] = [];
  const fps = derived?.footprints ?? {};
  let skipped = 0;
  for (const c of (bundle.candidates ?? []) as Candidate[]) {
    if (!c || typeof c.id !== "string" || !isNum(c.position?.lat) || !isNum(c.position?.lon)) { skipped++; continue; }
    const ref = terrainRefs.get(c.reference);
    if (!ref) issues.push(`Candidate ${c.id} points to unknown reference "${c.reference}".`);
    const kind = c.pathway === "terrain" ? "terrain" : c.pathway === "rock type" ? "rock" : null;
    if (!kind) { issues.push(`Candidate ${c.id} has an unrecognised pathway "${c.pathway}"; shown as rock-type screening is NOT assumed, record skipped.`); skipped++; continue; }
    const fp = fps[c.id];
    records.push({
      id: c.id,
      kind,
      pathwayLabel: kind === "terrain" ? "Terrain pathway" : "Rock-type screening (GLiM)",
      referenceId: c.reference,
      body: bodyOf(ref?.body),
      lat: c.position.lat,
      lon: c.position.lon,
      title: c.id,
      subtitle: ref?.description ?? c.reference,
      positionMeaning:
        kind === "terrain"
          ? "Centre of a 10 km terrain window (square in the tile's local azimuthal-equidistant projection)"
          : "Centre of a rock-type screening box (0.1° latitude × 0.1°/cos(lat) longitude)",
      ring: fp?.ring,
      ringKind: fp?.kind,
      raw: c,
    });
  }
  for (const u of (bundle.geology_v2?.units ?? []) as GeoUnit[]) {
    if (!u || typeof u.id !== "string") { skipped++; continue; }
    const p = u.nearest_point;
    if (!Array.isArray(p) || !isNum(p[0]) || !isNum(p[1])) { issues.push(`geo-2.0 unit ${u.id} has no representative point; it is listed but cannot be mapped.`); skipped++; continue; }
    records.push({
      id: u.id,
      kind: "geo2",
      pathwayLabel: "Regional geology (geo-2.0)",
      referenceId: u.reference,
      body: "Mars",
      lat: p[0],
      lon: p[1],
      title: u.unit_name,
      subtitle: `${u.state ?? "state not recorded"} · map unit ${u.unit_link}`,
      positionMeaning:
        "Representative point of a mapped geologic unit (the unit's polygon nearest the study-area centre). The unit's outline is not in the bundle and is not drawn.",
      raw: u,
    });
  }
  if (skipped) issues.push(`${skipped} record(s) could not be mapped (missing id, position or pathway).`);

  const coverage: CoverageTile[] = [];
  const coverageByKey = new Map<string, CoverageTile>();
  let badTiles = 0;
  for (const [name, v] of Object.entries(bundle.coverage ?? {})) {
    const t = parseTileName(name);
    if (!t) { badTiles++; continue; }
    const status: CoverageTile["status"] = typeof v === "number" ? (v > 0 ? "windows" : "no_valid_windows") : v === "no_valid_windows" ? "no_valid_windows" : v === "skipped_landcover" ? "skipped_landcover" : "other";
    const tile: CoverageTile = { name, south: t.south, west: t.west, status, windows: typeof v === "number" ? v : null, rawStatus: v };
    coverage.push(tile);
    coverageByKey.set(t.key, tile);
  }
  if (badTiles) issues.push(`${badTiles} coverage entries do not follow the Copernicus tile-name convention and are not drawn.`);

  const byId = new Map(records.map((r) => [r.id, r]));
  const counts = {
    terrain: records.filter((r) => r.kind === "terrain").length,
    rock: records.filter((r) => r.kind === "rock").length,
    geo2: records.filter((r) => r.kind === "geo2").length,
    total: records.length,
  };
  return { bundle, records, byId, terrainRefs, geoRefs, coverage, coverageByKey, counts, issues, geometryNote: derived?.note ?? null };
}

export async function loadAtlas(basePath: string): Promise<Atlas> {
  const res = await fetch(`${basePath}/data/app_bundle.json`);
  if (!res.ok) throw new Error(`The results bundle could not be loaded (HTTP ${res.status}).`);
  const bundle = (await res.json()) as Bundle;
  if (!bundle || typeof bundle !== "object") throw new Error("The results bundle is not a JSON object.");
  let derived: Derived | null = null;
  try {
    const g = await fetch(`${basePath}/data/derived_geometry.json`);
    if (g.ok) derived = (await g.json()) as Derived;
  } catch {
    derived = null;
  }
  const atlas = buildAtlas(bundle, derived);
  if (!derived) atlas.issues.push("derived_geometry.json is missing: footprints are not drawn; records are shown as points.");
  return atlas;
}

/** Reference lookup across both pathways. */
export function referenceLabel(atlas: Atlas, id: string): { id: string; body: string; label: string; kind: "terrain" | "geology" | "unknown" } {
  const t = atlas.terrainRefs.get(id);
  if (t) return { id, body: t.body, label: t.description ?? id, kind: "terrain" };
  const g = atlas.geoRefs.get(id);
  if (g) return { id, body: "Mars", label: g.name, kind: "geology" };
  return { id, body: "Unknown", label: id, kind: "unknown" };
}
