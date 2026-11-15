import type { Atlas, AtlasRecord, Candidate, GeoUnit } from "./types";

function download(name: string, text: string, mime: string) {
  const blob = new Blob([text], { type: mime });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

const safe = (id: string) => id.replace(/[^A-Za-z0-9._-]+/g, "_");

/** The exported object: the engine record exactly as loaded, plus run lineage copied from the same bundle. Nothing is added or recomputed. */
export function exportObject(atlas: Atlas, r: AtlasRecord) {
  const b = atlas.bundle;
  const lineage =
    r.kind === "geo2"
      ? { pathway: "geo-2.0 regional geology", block_version: b.geology_v2?.block_version ?? null, region: b.geology_v2?.regions?.find((x) => x.id === (r.raw as GeoUnit).region) ?? null }
      : r.kind === "rock"
        ? { pathway: "rock-type screening", geology_run: b.geology_run ?? null }
        : { pathway: "terrain", run: { manifest_describe_as: b.run?.manifest_describe_as ?? null, created_utc: b.run?.created_utc ?? null, parameters: b.run?.parameters ?? null, datasets: b.run?.datasets ?? null } };
  return {
    export_note: "Record exactly as stored in the loaded results bundle (app_bundle.json, schema " + (b.schema_version ?? "unknown") + "). Summary values only: raw source pixels and map polygons are not included.",
    record: r.raw,
    derived_map_outline: r.ring ? { kind: r.ringKind, method: atlas.geometryNote, ring_lon_lat: r.ring } : null,
    lineage,
  };
}

export function exportJson(atlas: Atlas, r: AtlasRecord) {
  download(`${safe(r.id)}.json`, JSON.stringify(exportObject(atlas, r), null, 2), "application/json");
}

const q = (v: unknown) => {
  const s = v === null || v === undefined ? "" : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

/** CSV of the fields that map meaningfully to rows. */
export function recordCsv(r: AtlasRecord): string {
  const rows: unknown[][] = [];
  if (r.kind === "terrain") {
    const c = r.raw as Candidate;
    rows.push(["record_id", "latitude", "longitude", "reference", "property", "unit", "earth_value", "ref_p10", "ref_p25", "ref_p50", "ref_p75", "ref_p90", "outcome"]);
    for (const p of c.properties ?? []) rows.push([c.id, c.position.lat, c.position.lon, c.reference, p.property, p.unit, p.value, p.reference_band?.p10, p.reference_band?.p25, p.reference_band?.p50, p.reference_band?.p75, p.reference_band?.p90, p.outcome]);
    for (const [k, v] of Object.entries(c.distances?.by_baseline_deg ?? {})) rows.push([c.id, c.position.lat, c.position.lon, c.reference, `slope distribution distance (W1) at ${k} m`, "deg", v, "", "", "", "", "", ""]);
    for (const [k, v] of Object.entries(c.land_cover ?? {})) rows.push([c.id, c.position.lat, c.position.lon, c.reference, `land cover ${k}`, "fraction", v, "", "", "", "", "", ""]);
  } else if (r.kind === "rock") {
    const c = r.raw as Candidate;
    rows.push(["record_id", "latitude", "longitude", "reference", "field", "value"]);
    rows.push([c.id, c.position.lat, c.position.lon, c.reference, "tier", c.tier]);
    for (const [k, v] of Object.entries(c.values ?? {})) rows.push([c.id, c.position.lat, c.position.lon, c.reference, k, v]);
    for (const [k, v] of Object.entries(c.evidence_ladder ?? {})) rows.push([c.id, c.position.lat, c.position.lon, c.reference, k, v]);
  } else {
    const u = r.raw as GeoUnit;
    rows.push(["record_id", "unit_name", "unit_link", "reference", "property", "role", "mars_evidence_type", "mars_site", "mars_statement", "citations", "earth_status", "earth_source", "earth_text"]);
    for (const c of u.comparison ?? []) rows.push([u.id, u.unit_name, u.unit_link, u.reference, c.property, c.role, c.mars_evidence_type, c.mars_site, c.mars_statement, (c.citations ?? []).join("; "), c.earth_status, c.earth_source, c.earth_text]);
  }
  return rows.map((row) => row.map(q).join(",")).join("\n") + "\n";
}

export function exportCsv(r: AtlasRecord) {
  download(`${safe(r.id)}.csv`, recordCsv(r), "text/csv");
}
