"use client";
import { useMemo } from "react";
import type { Atlas, AtlasRecord, Candidate, GeoUnit } from "@/lib/types";
import { formatLatLon, haversineKm, pointInRing, tileKey } from "@/lib/geo";
import { exportJson } from "@/lib/export";
import { ComparisonTable, Limits, PROPERTY_LABEL, TerrainMeasurements, WhyIdentified } from "./RecordViews";
import { recordLine } from "./Panels";

const pct = (v: unknown) => (typeof v === "number" ? `${(v * 100).toFixed(1)}%` : "not recorded");
const num = (v: unknown, d = 2) => (typeof v === "number" ? v.toFixed(d) : "not recorded");

function Facts({ atlas, rec }: { atlas: Atlas; rec: AtlasRecord }) {
  const rows: [string, React.ReactNode][] = [];
  if (rec.kind === "terrain") {
    const c = rec.raw as Candidate;
    const p0 = c.properties?.[0];
    rows.push(["Slope distance, worst baseline", <>{num(c.distances?.worst_scale_slope_W1_deg, 3)}° <span className="muted">smaller is closer; not a score</span></>]);
    if (p0) rows.push([p0.property.replace(/^median slope at /, "Median slope, ").replace(/ m$/, " m baseline"), <>{num(p0.value)}° <span className="muted">reference median {num(p0.reference_band?.p50)}° · {p0.outcome ?? "not evaluated"}</span></>]);
    rows.push(["Bare or sparse ground", <>{pct(c.land_cover?.bare_fraction)} <span className="muted">of the window; {pct(c.land_cover?.valid_fraction)} of cells used</span></>]);
    rows.push(["Inside reference yardstick", typeof c.inside_yardstick === "boolean" ? (c.inside_yardstick ? "Yes" : "No") : "not evaluated"]);
  } else if (rec.kind === "rock") {
    const c = rec.raw as Candidate;
    rows.push(["Tier", <>{c.tier ?? "not recorded"} <span className="muted">G1 mapped · G2 exposed · G4 partner class co-located</span></>]);
    rows.push(["Target rock class mapped", pct(c.values?.mapped_target_fraction)]);
    rows.push(["Target on bare ground", <>{num(c.values?.exposed_target_area_km2, 1)} km² <span className="muted">{pct(c.values?.exposed_target_fraction)} of the box</span></>]);
    rows.push(["Mineral spectra", String(c.evidence_ladder?.G3_spectral ?? "not evaluated")]);
  } else {
    const u = rec.raw as GeoUnit;
    for (const h of u.how_core_was_established ?? []) rows.push([`Required: ${PROPERTY_LABEL[h.property] ?? h.property}`, h.earth_status]);
    rows.push(["Supporting properties", <>{(u.supporting_recorded ?? []).length} of {u.supporting_total ?? "?"} recorded <span className="muted">a count, not a score</span></>]);
    rows.push(["Source map", u.map_source?.scale ? `1:${u.map_source.scale.toLocaleString("en-US")}; contacts about ±${u.map_source.contact_position_uncertainty_m ?? "?"} m` : "scale not recorded"]);
    rows.push(["Steep public ground (proxy)", `${num(u.public_steep_ground_km2, 3)} km²`]);
  }
  return <table className="kv facts"><tbody>{rows.map(([k, v]) => <tr key={k}><th scope="row">{k}</th><td>{v}</td></tr>)}</tbody></table>;
}

export function Inspector({ atlas, rec, onData, onReference, onFly }: { atlas: Atlas; rec: AtlasRecord; onData(tab?: string): void; onReference(id: string): void; onFly(): void }) {
  const u = rec.kind === "geo2" ? (rec.raw as GeoUnit) : null;
  const featured = u ? (atlas.bundle.geology_v2?.featured ?? []).find((f) => f.unit_link === u.unit_link && f.region === u.region) : undefined;
  const status = rec.kind === "terrain" ? "Measured from elevation data; not visited" : rec.kind === "rock" ? "Map classification; mineralogy not measured" : "Mapped unit; field exposure not verified";
  return (
    <div className="inspector">
      <div className={`grouplab ${rec.body.toLowerCase()}`}>{rec.pathwayLabel}</div>
      <h2>{rec.title}</h2>
      <p className="sub">{rec.kind === "geo2" ? rec.subtitle : formatLatLon(rec.lat, rec.lon)}</p>
      <p className="chips">
        <button className="chip" onClick={() => onReference(rec.referenceId)} title="Open the planetary reference">Compared with {rec.referenceId} · {rec.body}</button>
        <span className="chip quiet">{status}</span>
      </p>
      <Facts atlas={atlas} rec={rec} />
      <p className="pos muted small">{rec.kind === "geo2" ? `Map point ${formatLatLon(rec.lat, rec.lon)}. ` : ""}{rec.positionMeaning.replace(/\.$/, "")}.</p>
      <div className="btnrow">
        <button className="primary" onClick={() => onData()}>Data for this site</button>
        <button onClick={onFly}>Fly to</button>
        <button onClick={() => exportJson(atlas, rec)}>Export JSON</button>
      </div>

      {featured && (
        <section className="xcheck">
          <h3>Independent cross-check</h3>
          <p>{featured.title}.</p>
          <p><strong>{featured.outcome}.</strong></p>
          <p className="muted small">{featured.note ? `${featured.note[0].toUpperCase()}${featured.note.slice(1)}. ` : ""}The guide's stop locations are not verified by this project, and no field scan is part of the loaded results. In the polygon inside the preserve, {pct(featured.share_within_500m_of_intrusive_contact)} of the area lies within 500 m of an intrusive contact (possible heat alteration).</p>
        </section>
      )}

      <details open>
        <summary>Why it was identified</summary>
        <WhyIdentified atlas={atlas} rec={rec} />
      </details>
      {rec.kind === "terrain" && (
        <details open>
          <summary>Terrain compared with {rec.referenceId}</summary>
          <TerrainMeasurements rec={rec} part="plot" />
          <button className="link" onClick={() => onData("comparison")}>Full table and distances →</button>
        </details>
      )}
      {u && (
        <details>
          <summary>Geologic evidence, property by property</summary>
          <ComparisonTable atlas={atlas} rows={u.comparison ?? []} />
        </details>
      )}
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
      <h2>{formatLatLon(loc.lat, loc.lon)}</h2>
      {loc.label && <p className="sub">{loc.label}</p>}
      <p className="notice"><strong>No analysis for this exact location in the loaded results.</strong> The site can navigate anywhere on Earth, but measurements exist only for the precomputed records. On-demand analysis of a new location is not available in this build.</p>

      <h3>What the loaded run covers here</h3>
      <table className="kv"><tbody>
        <tr><th scope="row">Terrain run</th><td>
          {t ? (t.status === "windows" ? `This 1° tile was processed: ${t.windows} windows were evaluated.` : t.status === "no_valid_windows" ? "This 1° tile was processed, but no 10 km window passed the validity test (too much masked or missing ground)." : t.status === "skipped_landcover" ? "This 1° tile was skipped: land cover (trees, crops, built-up, water) rules out every window, so its elevation data was not read." : `Tile status: ${String(t.rawStatus)}.`)
            : "There is no result for this 1° tile in the loaded run: it is ocean, outside the tile list, or it failed."}
        </td></tr>
        <tr><th scope="row">Loaded footprints containing this point</th><td>
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
        <tr><th scope="row">Rock-type screening</th><td>Screened globally at 0.1°, but only the 50 highest-ranked boxes per reference are loaded. A box that is not listed was either not nominated or ranked lower.</td></tr>
      </tbody></table>

      <div className="btnrow">
        <button onClick={onUseAsCentre}>Search around this point</button>
        <button onClick={onFly}>Fly to</button>
      </div>

      <h3>Nearest loaded records</h3>
      <p className="muted small">Listed for navigation. Their measurements are not properties of the selected location.</p>
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
