"use client";
// Compact record inspector: identity, evidence state, three facts, one primary action. Detail lives one click away.
import { useEffect, useMemo, useRef, useState } from "react";
import type { Atlas, AtlasRecord, Candidate, GeoUnit } from "@/lib/types";
import { formatLatLon, haversineKm, pointInRing, tileKey } from "@/lib/geo";
import { exportCsv, exportJson } from "@/lib/export";
import { Limits, PROPERTY_LABEL } from "./RecordViews";
import { recordLine } from "./Panels";
import { IconExport } from "./Icons";

const pct = (v: unknown) => (typeof v === "number" ? `${(v * 100).toFixed(1)}%` : "not recorded");
const num = (v: unknown, d = 2) => (typeof v === "number" ? v.toFixed(d) : "not recorded");

type Fact = { label: string; value: string; cmp?: string; wide?: boolean };

/** Up to three facts, all read from the record. No derived scores. */
function facts(rec: AtlasRecord): Fact[] {
  if (rec.kind === "terrain") {
    const c = rec.raw as Candidate;
    const p0 = c.properties?.[0];
    const out: Fact[] = [{ label: "Slope distance, worst baseline", value: typeof c.distances?.worst_scale_slope_W1_deg === "number" ? `${c.distances.worst_scale_slope_W1_deg.toFixed(3)}°` : "not recorded", cmp: "Wasserstein-1 between slope distributions. Smaller is closer; not a percentage." }];
    if (p0) out.push({ label: p0.property.replace(/^median slope at (\d+) m$/, "Median slope, $1 m baseline"), value: typeof p0.value === "number" ? `${p0.value.toFixed(2)}°` : "not measured", cmp: `reference median ${num(p0.reference_band?.p50)}° · ${p0.outcome ?? "not evaluated"}` });
    out.push({ label: "Bare or sparse ground", value: pct(c.land_cover?.bare_fraction), cmp: `share of the window (ESA WorldCover); ${pct(c.land_cover?.valid_fraction)} of cells used` });
    return out;
  }
  if (rec.kind === "rock") {
    const c = rec.raw as Candidate;
    return [
      { label: "Screening tier", value: c.tier ?? "not recorded", cmp: "G1 mapped · G2 on bare ground · G4 partner class in the same box" },
      { label: "Target rock class mapped", value: pct(c.values?.mapped_target_fraction), cmp: "share of the box on the Global Lithological Map" },
      { label: "Target class on bare ground", value: typeof c.values?.exposed_target_area_km2 === "number" ? `${c.values.exposed_target_area_km2.toFixed(1)} km²` : "not recorded", cmp: `${pct(c.values?.exposed_target_fraction)} of the box · mineral spectra ${String(c.evidence_ladder?.G3_spectral ?? "not evaluated")}` },
    ];
  }
  const u = rec.raw as GeoUnit;
  const core = u.how_core_was_established ?? [];
  return [
    { label: "Required properties", value: core.length ? core.map((h) => `${PROPERTY_LABEL[h.property] ?? h.property}: ${h.earth_status}`).join(" · ") : "not recorded", wide: true },
    { label: "Supporting properties recorded", value: `${(u.supporting_recorded ?? []).length} of ${u.supporting_total ?? "?"}`, cmp: "a count from the map-unit description, not a score" },
    { label: "Source map scale", value: u.map_source?.scale ? `1:${u.map_source.scale.toLocaleString("en-US")}` : "not recorded", cmp: `contacts about ±${u.map_source?.contact_position_uncertainty_m ?? "?"} m · steep public ground (proxy) ${num(u.public_steep_ground_km2, 3)} km²` },
  ];
}

/** Two or three template sentences from record fields. */
function why(atlas: Atlas, rec: AtlasRecord): string {
  if (rec.kind === "terrain") {
    const c = rec.raw as Candidate;
    const ref = atlas.terrainRefs.get(c.reference);
    const n = atlas.bundle.run?.windows?.evaluated;
    const y = ref?.yardstick as { p90?: number } | null | undefined;
    const yard = typeof c.inside_yardstick === "boolean" && typeof y?.p90 === "number"
      ? ` Its slope distance is ${c.inside_yardstick ? "inside" : "outside"} the spread between real reference sites (yardstick ${y.p90}°).`
      : " This reference has no site-to-site yardstick.";
    return `Nominated for ${c.reference}${ref?.description ? ` (${ref.description})` : ""}: on Pareto front ${c.pareto_front ?? "?"} for slope, roughness and connectivity distance${typeof n === "number" ? ` among ${n.toLocaleString("en-US")} windows evaluated` : ""}.${yard}`;
  }
  if (rec.kind === "rock") {
    const c = rec.raw as Candidate;
    return `The Global Lithological Map shows the rock class associated with ${c.reference} in this 0.1° box (tier ${c.tier ?? "not recorded"}). This is a map classification at 1:1,000,000 to 1:5,000,000; a co-located partner class does not establish a shared process.`;
  }
  const u = rec.raw as GeoUnit;
  const nc = (u.conflicts ?? []).length;
  return `Every required property of ${u.reference} is recorded for this map unit and no ruling-out property is. ${(u.supporting_recorded ?? []).length} of ${u.supporting_total ?? "?"} supporting properties are recorded${nc ? `, with ${nc} recorded conflict${nc > 1 ? "s" : ""}` : ""}. Evidence is map text and structured lithology, not field observation.`;
}

export function Inspector({ atlas, rec, onData, onReference, onFly }: { atlas: Atlas; rec: AtlasRecord; onData(tab?: string): void; onReference(id: string): void; onFly(): void }) {
  const [menu, setMenu] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  useEffect(() => { setMenu(false); }, [rec.id]);
  useEffect(() => {
    if (!menu) return;
    const f = (e: MouseEvent) => { if (menuRef.current && !menuRef.current.contains(e.target as Node)) setMenu(false); };
    const k = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); setMenu(false); } };
    document.addEventListener("mousedown", f);
    document.addEventListener("keydown", k, true);
    return () => { document.removeEventListener("mousedown", f); document.removeEventListener("keydown", k, true); };
  }, [menu]);

  const u = rec.kind === "geo2" ? (rec.raw as GeoUnit) : null;
  const featured = u ? (atlas.bundle.geology_v2?.featured ?? []).find((f) => f.unit_link === u.unit_link && f.region === u.region) : undefined;
  const state = rec.kind === "terrain" ? "Elevation-derived; not field-visited" : rec.kind === "rock" ? "Map classification; mineralogy not measured" : "Mapped unit; exposure unverified";
  const tref = atlas.terrainRefs.get(rec.referenceId);
  const gref = atlas.geoRefs.get(rec.referenceId);
  const refName = tref?.description ?? gref?.name ?? "";
  const refShort = refName.length > 46 ? `${refName.slice(0, 44)}…` : refName;

  return (
    <div className="inspector">
      <div className="path"><i className={`sym ${rec.kind === "terrain" ? "circle" : rec.kind === "rock" ? "square" : "diamond"} ${rec.body.toLowerCase()}`} />{rec.pathwayLabel}</div>
      <h2>{rec.title}</h2>
      {rec.kind === "geo2" ? <p className="sub plainfont">{rec.subtitle}{u?.unit_age ? ` · ${u.unit_age}` : ""}</p> : <p className="sub">{formatLatLon(rec.lat, rec.lon)}</p>}
      <p className="cmpline"><span className="cmplab">Compared with <span className={`grouplab ${rec.body.toLowerCase()}`}>{rec.body}</span></span><button onClick={() => onReference(rec.referenceId)} title={`${rec.referenceId}: ${refName}`}>{rec.referenceId}{refShort ? ` · ${refShort}` : ""}</button></p>
      <p className="state">{state}</p>

      <dl className="facts3">
        {facts(rec).map((f) => (
          <div key={f.label} className={`fact${f.wide ? " wide" : ""}`}>
            <dt>{f.label}</dt><dd>{f.value}</dd>
            {f.cmp ? <div className="cmp">{f.cmp}</div> : null}
          </div>
        ))}
      </dl>

      <div className="actions" ref={menuRef}>
        <button className="primary" onClick={() => onData()}>Inspect evidence</button>
        <button className="textbtn" onClick={onFly}>Fly to</button>
        <button className="textbtn" aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu((v) => !v)} style={{ display: "inline-flex", alignItems: "center", gap: 5, marginLeft: "auto" }}><IconExport /> Export</button>
        {menu && (
          <div className="menu" role="menu">
            <button role="menuitem" onClick={() => { exportJson(atlas, rec); setMenu(false); }}>Record as JSON</button>
            <button role="menuitem" onClick={() => { exportCsv(rec); setMenu(false); }}>Values as CSV</button>
          </div>
        )}
      </div>
      <p className="pos muted small">{rec.kind === "geo2" ? `Map point ${formatLatLon(rec.lat, rec.lon)}: ` : ""}{rec.positionMeaning.replace(/\.$/, "")}.</p>

      {featured && (
        <section className="xcheck">
          <b>Independent cross-check</b>
          <p><strong>{featured.outcome}.</strong></p>
          <details>
            <summary>Source and caveats</summary>
            <p>{featured.title}.</p>
            <p className="muted">{featured.note ? `${featured.note[0].toUpperCase()}${featured.note.slice(1)}. ` : ""}The guide's stop locations are not verified by this project, and no field scan is part of the loaded results. In the polygon inside the preserve, {pct(featured.share_within_500m_of_intrusive_contact)} of the area lies within 500 m of an intrusive contact (possible heat alteration).</p>
          </details>
        </section>
      )}

      <details open>
        <summary>Why identified</summary>
        <div className="prose">
          <p>{why(atlas, rec)}</p>
          <button className="link" onClick={() => onData("why")}>Full reasoning</button>
          {rec.kind !== "rock" && <> · <button className="link" onClick={() => onData("comparison")}>{rec.kind === "terrain" ? "View comparison chart" : "View property-by-property evidence"}</button></>}
          {" · "}<button className="link" onClick={() => onData("sources")}>Sources</button>
        </div>
      </details>
      <details>
        <summary>Limits</summary>
        <Limits atlas={atlas} rec={rec} />
      </details>
    </div>
  );
}

export function ClusterList({ atlas, ids, onSelect }: { atlas: Atlas; ids: string[]; onSelect(id: string): void }) {
  const recs = ids.map((i) => atlas.byId.get(i)).filter(Boolean) as AtlasRecord[];
  return (
    <div className="inspector">
      <h2>{recs.length} records here</h2>
      <p className="muted small">These records overlap on the map. A window can be nominated for more than one reference, and different pathways can point at the same place. They are separate records, not {recs.length} separate sites.</p>
      <ul className="reclist">
        {recs.map((r) => (
          <li key={r.id}><button onClick={() => onSelect(r.id)}>
            <i className={`sym ${r.kind === "terrain" ? "circle" : r.kind === "rock" ? "square" : "diamond"} ${r.body.toLowerCase()}`} />
            <span className="t">{r.title}<em>{r.referenceId}</em></span><span className="s">{recordLine(r)}</span>
          </button></li>
        ))}
      </ul>
    </div>
  );
}

export function LocationCard({ atlas, loc, onSelect, onUseAsCentre, onFly }: { atlas: Atlas; loc: { lat: number; lon: number; label?: string }; onSelect(id: string): void; onUseAsCentre(): void; onFly(): void }) {
  const info = useMemo(() => {
    const tile = atlas.coverageByKey.get(tileKey(loc.lat, loc.lon)) ?? null;
    const containing = atlas.records.filter((r) => r.ring && pointInRing(loc.lon, loc.lat, r.ring));
    const regions = (atlas.bundle.geology_v2?.regions ?? []).filter((g) => haversineKm(g.centre[0], g.centre[1], loc.lat, loc.lon) <= g.radius_km);
    const nearest = atlas.records.map((r) => ({ r, d: haversineKm(loc.lat, loc.lon, r.lat, r.lon) })).sort((a, b) => a.d - b.d).slice(0, 5);
    return { tile, containing, regions, nearest };
  }, [atlas, loc]);
  const t = info.tile;
  return (
    <div className="inspector">
      <div className="path">Selected location</div>
      <h2 className="mono" style={{ fontSize: 17 }}>{formatLatLon(loc.lat, loc.lon)}</h2>
      {loc.label && <p className="sub plainfont">{loc.label}</p>}
      <p className="notice"><strong>No analysis for this exact location in the loaded results.</strong>The globe can go anywhere, but measurements exist only for the precomputed records. On-demand analysis of a new location is not available in this build.</p>
      <div className="actions">
        <button className="btn" onClick={onUseAsCentre}>Search around this point</button>
        <button className="textbtn" onClick={onFly}>Fly to</button>
      </div>

      <h3>What the loaded run covers here</h3>
      <table className="kv"><tbody>
        <tr><th scope="row">Terrain run</th><td>
          {t ? (t.status === "windows" ? `This 1° tile was processed: ${t.windows} window${t.windows === 1 ? " was" : "s were"} evaluated.` : t.status === "no_valid_windows" ? "This 1° tile was processed, but no 10 km window passed the validity test (too much masked or missing ground)." : t.status === "skipped_landcover" ? "This 1° tile was skipped: land cover (trees, crops, built-up, water) rules out every window, so its elevation data was not read." : `Tile status: ${String(t.rawStatus)}.`)
            : "There is no result for this 1° tile in the loaded run: it is ocean, outside the tile list, or it failed."}
        </td></tr>
        <tr><th scope="row">Footprints containing this point</th><td>
          {info.containing.length === 0 ? "None." : (
            <>
              {info.containing.length} record{info.containing.length > 1 ? "s" : ""}. Their values describe the whole window or box, not this point.
              <ul className="reclist tight">{info.containing.slice(0, 8).map((r) => (<li key={r.id}><button onClick={() => onSelect(r.id)}><span className="t">{r.title}<em>{r.referenceId}</em></span><span className="s">{r.pathwayLabel}</span></button></li>))}</ul>
            </>
          )}
        </td></tr>
        <tr><th scope="row">Regional geology</th><td>
          {info.regions.length ? `Inside the ${info.regions.map((g) => `${g.id} ${g.role}`).join(" and ")} circle. Qualifying map units are shown at representative points; unit outlines are not in the bundle, so the unit under this exact point cannot be stated.` : "Outside both regional geology study areas. Not searched."}
        </td></tr>
        <tr><th scope="row">Rock-type screening</th><td>Screened at 0.1°, but only the 50 highest-ranked boxes per reference are loaded. A box that is not listed was either not nominated or ranked lower.</td></tr>
      </tbody></table>

      <h3>Nearest loaded records</h3>
      <p className="muted small" style={{ margin: 0 }}>Listed for navigation. Their measurements are not properties of the selected location.</p>
      <ul className="reclist">
        {info.nearest.map(({ r, d }) => (
          <li key={r.id}><button onClick={() => onSelect(r.id)}>
            <i className={`sym ${r.kind === "terrain" ? "circle" : r.kind === "rock" ? "square" : "diamond"} ${r.body.toLowerCase()}`} />
            <span className="t">{r.title}<em>{r.referenceId}</em></span><span className="s">{d < 10 ? d.toFixed(1) : Math.round(d).toLocaleString("en-US")} km away · {r.pathwayLabel}</span>
          </button></li>
        ))}
      </ul>
    </div>
  );
}
