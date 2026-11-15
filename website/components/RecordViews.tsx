"use client";
// Evidence sections for a record. All text is assembled from record fields and fixed templates; nothing is generated per site.
import type { Atlas, AtlasRecord, Candidate, GeoUnit, ComparisonRow, TerrainReference } from "@/lib/types";
import { SOURCE_BY_KEY, doiUrl, GLIM_CLASSES, REFERENCE_LOCATIONS, type SourceEntry } from "@/lib/sources";
import { formatLatLon } from "@/lib/geo";
import { BandPlot, ConnectivityChart } from "./Charts";

export const PROPERTY_LABEL: Record<string, string> = {
  FINE_CLASTIC: "Fine-grained clastic rock (mudstone, shale, siltstone)",
  LACUSTRINE: "Deposited in a lake",
  MARINE: "Marine deposit",
  DESICCATION: "Desiccation (mud) cracks",
  CYCLIC: "Cyclic bedding",
  LAMINATED: "Laminated bedding",
  CLAY: "Clay minerals",
  EVAPORITE: "Evaporite minerals (sulfate, salt)",
  VOLCANIC_NEIGHBOUR: "Shares a boundary with a mapped lava-flow unit",
  LAKE_NEIGHBOUR: "Shares a boundary with a mapped lake unit",
  CONTACT_METAMORPHISM: "Heated by a nearby intrusion",
  OLIVINE_RICH_ULTRAMAFIC: "Olivine-rich ultramafic rock",
  OLIVINE: "Olivine",
  CARBONATE: "Carbonate minerals",
  SERPENTINE: "Serpentine minerals",
  SERPENTINIZATION: "Serpentinization",
  H2_PRODUCTION: "Hydrogen production",
  MAFIC_VOLCANIC: "Mafic volcanic rock (basalt)",
  EXTRUSIVE: "Erupted as lava (extrusive)",
  INTRUSIVE: "Intruded below ground (intrusive)",
  PILLOWS: "Pillow structures",
};
const label = (code: string) => PROPERTY_LABEL[code] ?? code;

const fmt = (v: unknown, digits = 2): string => (typeof v === "number" && isFinite(v) ? (Number.isInteger(v) ? String(v) : v.toFixed(digits)) : "not recorded");
const pct = (v: unknown): string => (typeof v === "number" && isFinite(v) ? `${(v * 100).toFixed(1)}%` : "not recorded");

export function SourceLink({ k }: { k: string }) {
  const s = SOURCE_BY_KEY.get(k);
  if (!s) return <span>{k}</span>;
  return s.url ? <a href={s.url} target="_blank" rel="noreferrer">{s.name}</a> : <span>{s.name}</span>;
}

function Citations({ atlas, keys }: { atlas: Atlas; keys?: string[] }) {
  const cites = atlas.bundle.geology_v2?.citations ?? {};
  if (!keys?.length) return <span className="muted">none listed</span>;
  return (
    <>
      {keys.map((k, i) => {
        const full = cites[k];
        const url = full ? doiUrl(full) : null;
        return (
          <span key={k}>
            {i > 0 && ", "}
            {url ? <a href={url} target="_blank" rel="noreferrer" title={full}>{k}</a> : <span title={full ?? "citation text not in bundle"}>{k}</span>}
          </span>
        );
      })}
    </>
  );
}

// ---------------------------------------------------------------- identity
export function IdentityTable({ atlas, rec }: { atlas: Atlas; rec: AtlasRecord }) {
  const b = atlas.bundle;
  const rows: [string, React.ReactNode][] = [
    ["Record ID", <code key="id">{rec.id}</code>],
    ["Pathway", rec.pathwayLabel],
    ["Compared with", `${rec.referenceId} · ${rec.body}`],
    ["Map position", formatLatLon(rec.lat, rec.lon)],
    ["Position means", rec.positionMeaning],
  ];
  if (rec.kind === "terrain") {
    rows.push(["Footprint", "10 km × 10 km window, 5 km step. The outline on the map is computed from the centre with the engine's projection."]);
    rows.push(["Run", `${b.run?.created_utc ?? "date not recorded"} · ${b.run?.manifest_describe_as ?? "coverage statement missing"}`]);
  } else if (rec.kind === "rock") {
    const c = rec.raw as Candidate;
    rows.push(["Footprint", `0.1° latitude × 0.1°/cos(latitude) longitude box, about ${fmt((c.footprint as { size_km_approx?: number } | undefined)?.size_km_approx, 1)} km across; half-box step`]);
    rows.push(["Run", String(b.geology_run?.source ?? "source not recorded")]);
  } else {
    const u = rec.raw as GeoUnit;
    const reg = b.geology_v2?.regions?.find((x) => x.id === u.region);
    rows.push(["Mapped unit", `${u.unit_name} (${u.unit_link}), ${u.unit_age ?? "age not recorded"}`]);
    rows.push(["Aggregation", `${fmt(u.polygons, 0)} map polygons, ${fmt(u.area_km2, 1)} km² in total inside the study area. One record per map unit, not per outcrop.`]);
    rows.push(["Study area", reg ? `${reg.id} (${reg.role}): ${reg.radius_km} km around ${formatLatLon(reg.centre[0], reg.centre[1], 2)}; run ${reg.created ?? "date not recorded"}` : "region not recorded"]);
  }
  return (
    <table className="kv"><tbody>{rows.map(([k, v]) => (<tr key={k}><th scope="row">{k}</th><td>{v}</td></tr>))}</tbody></table>
  );
}

// ---------------------------------------------------------------- why identified
export function WhyIdentified({ atlas, rec }: { atlas: Atlas; rec: AtlasRecord }) {
  if (rec.kind === "terrain") {
    const c = rec.raw as Candidate;
    const ref = atlas.terrainRefs.get(c.reference);
    const y = ref?.yardstick as Record<string, unknown> | null | undefined;
    return (
      <div className="prose">
        <p>The terrain pathway compared this 10 km window's slope and roughness distributions with reference <strong>{c.reference}</strong>{ref?.description ? ` (${ref.description})` : ""} at every baseline the reference supports.</p>
        <table className="kv"><tbody>
          <tr><th scope="row">Nomination rule</th><td>{c.rank_rule ?? "not recorded"}</td></tr>
          <tr><th scope="row">Pareto front</th><td>{fmt(c.pareto_front, 0)} <span className="muted">(1 = not beaten on every criterion by any other window)</span></td></tr>
          <tr><th scope="row">Slope distance, worst baseline</th><td>{fmt(c.distances?.worst_scale_slope_W1_deg, 3)}° <span className="muted">Wasserstein-1 distance between slope distributions, in degrees. Smaller is closer. Not a percentage.</span></td></tr>
          <tr><th scope="row">Roughness distance, worst baseline</th><td>{fmt(c.distances?.worst_scale_log10_roughness_W1, 3)} <span className="muted">log10 units</span></td></tr>
          <tr><th scope="row">Connectivity distance</th><td>{fmt(c.distances?.connectivity_distance, 3)} <span className="muted">mean absolute difference between connectivity curves</span></td></tr>
          <tr><th scope="row">Inside the reference yardstick</th><td>{typeof c.inside_yardstick === "boolean" ? (c.inside_yardstick ? "Yes" : "No") : "not evaluated"}{y && typeof y.p90 === "number" ? <span className="muted"> — the test is: worst-baseline slope distance at or below the yardstick's 90th percentile ({String(y.p90)}°). The yardstick is the spread between real reference sites{typeof y.kind === "string" ? ` (${y.kind})` : " (leave-one-site-out)"}.{typeof y.caveat === "string" ? ` Caveat: ${y.caveat}.` : ""}</span> : <span className="muted"> — this reference has no yardstick</span>}</td></tr>
        </tbody></table>
        <p className="muted">Distances are relative measures between distributions. They are not suitability scores, and lists depend on the nomination rule.</p>
      </div>
    );
  }
  if (rec.kind === "rock") {
    const c = rec.raw as Candidate;
    const L = c.evidence_ladder ?? {};
    const row = (k: string, text: string) => {
      const v = L[k];
      return <tr key={k}><th scope="row">{text}</th><td>{v === true ? "Yes" : v === false ? "No" : String(v ?? "not recorded")}</td></tr>;
    };
    return (
      <div className="prose">
        <p>Rock-type screening looked for the rock class associated with reference <strong>{c.reference}</strong> on the Global Lithological Map (GLiM), inside a 0.1° box. Tier <strong>{c.tier ?? "not recorded"}</strong>.</p>
        <table className="kv"><tbody>
          {row("G1_mapped", "G1 · target rock class mapped over at least half the box")}
          {row("G2_exposed", "G2 · target rock on bare or sparsely vegetated ground")}
          {row("G3_spectral", "G3 · mineral spectra")}
          {row("G4_colocated_partner", "G4 · partner rock class mapped in the same box")}
          <tr><th scope="row">Ranking rule</th><td>{c.rank_rule ?? "not recorded"}</td></tr>
        </tbody></table>
        <p className="muted">GLiM classes come from 1:1,000,000 to 1:5,000,000 maps. A co-located partner class does not establish a shared geological process, and no mineralogy is measured.</p>
      </div>
    );
  }
  const u = rec.raw as GeoUnit;
  const gref = atlas.geoRefs.get(u.reference);
  return (
    <div className="prose">
      <p>The regional geology engine (geo-2.0) compared every mapped unit in the study area with reference <strong>{u.reference}</strong>{gref ? ` (${gref.name})` : ""}. A unit qualifies only if every required property is recorded and no ruling-out property is.</p>
      <table className="kv"><tbody>
        {(u.how_core_was_established ?? []).map((h) => (<tr key={h.property}><th scope="row">Required: {label(h.property)}</th><td>{h.earth_status}</td></tr>))}
        <tr><th scope="row">Supporting properties recorded</th><td>{(u.supporting_recorded ?? []).length} of {fmt(u.supporting_total, 0)} <span className="muted">(a count, not a score)</span>{(u.supporting_recorded ?? []).length ? `: ${(u.supporting_recorded ?? []).map(label).join("; ")}` : ""}</td></tr>
        <tr><th scope="row">Recorded conflicts</th><td>{(u.conflicts ?? []).length ? (u.conflicts ?? []).join(" ") : "none"}</td></tr>
      </tbody></table>
      <p className="muted">"Recorded" means the property is stated in the map-unit description or structured lithology. "Inferred" means derived from sedimentary indicators plus basin context. Neither is a field observation.</p>
    </div>
  );
}

// ---------------------------------------------------------------- measurements
export function TerrainMeasurements({ rec, part }: { atlas?: Atlas; rec: AtlasRecord; part: "plot" | "comparison" | "earth" }) {
  const c = rec.raw as Candidate;
  const props = c.properties ?? [];
  const rows = props.map((p) => ({ label: (/at (\d+) m/.exec(p.property)?.[1] ?? p.property) + " m", band: p.reference_band, value: p.value }));
  const lc = c.land_cover;
  const geo = c.cross_pathway?.geology as Record<string, unknown> | undefined;
  const shares = (geo?.rock_class_shares ?? null) as Record<string, number> | null;
  return (
    <div>
      {part !== "earth" && (rows.length > 0 ? (
        <BandPlot rows={rows} body={rec.body} unit="degrees" axisLabel="Median plane-fit slope" earthLabel="this Earth window (median)" note={`Bands: slope distribution of ${c.reference} from its elevation model. Diamond: median slope of this window from Copernicus GLO-90 at the same baseline.`} />
      ) : <p className="muted">No slope properties are recorded for this window.</p>)}
      {part === "comparison" && (
        <>
          <table className="data">
            <thead><tr><th>Property</th><th>Earth window</th><th>Ref. p10</th><th>p25</th><th>p50</th><th>p75</th><th>p90</th><th>Outcome</th></tr></thead>
            <tbody>
              {props.map((p) => (
                <tr key={p.property}>
                  <td>{p.property}</td><td className="num">{fmt(p.value)} {p.unit ?? ""}</td>
                  <td className="num">{fmt(p.reference_band?.p10)}</td><td className="num">{fmt(p.reference_band?.p25)}</td><td className="num">{fmt(p.reference_band?.p50)}</td><td className="num">{fmt(p.reference_band?.p75)}</td><td className="num">{fmt(p.reference_band?.p90)}</td>
                  <td>{p.outcome ?? "not evaluated"}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <h4>Distribution distance by baseline</h4>
          <table className="data">
            <thead><tr><th>Baseline</th><th>Slope distance (Wasserstein-1)</th></tr></thead>
            <tbody>{Object.entries(c.distances?.by_baseline_deg ?? {}).map(([k, v]) => (<tr key={k}><td>{k} m</td><td className="num">{fmt(v, 3)}°</td></tr>))}</tbody>
          </table>
        </>
      )}
      {part === "earth" && (
        <>
          <h4>Land cover of the window (ESA WorldCover)</h4>
          <table className="data"><tbody>
            <tr><td>Share of cells used (not masked)</td><td className="num">{pct(lc?.valid_fraction)}</td></tr>
            <tr><td>Bare or sparsely vegetated</td><td className="num">{pct(lc?.bare_fraction)}</td></tr>
            <tr><td>Snow or ice</td><td className="num">{pct(lc?.snow_ice_fraction)}</td></tr>
          </tbody></table>
          <h4>Mapped rock classes under the window (GLiM, context only)</h4>
          {geo?.status === "measured" && shares ? (
            <table className="data">
              <thead><tr><th>GLiM class</th><th>Share of the window</th></tr></thead>
              <tbody>
                {Object.entries(shares).sort((a, b) => b[1] - a[1]).map(([k, v]) => (<tr key={k}><td>{GLIM_CLASSES[k] ?? k} <span className="muted">({k})</span></td><td className="num">{pct(v)}</td></tr>))}
                <tr><td>On bare or sparse ground</td><td className="num">{pct(geo.exposed_share)}</td></tr>
              </tbody>
            </table>
          ) : <p className="muted">{String(geo?.status ?? "Not measured for this window.")}</p>}
          <p className="muted">{String(geo?.cell_size ?? "")}{geo?.cell_size ? ". Map classes, not site lithology." : ""}</p>
        </>
      )}
    </div>
  );
}

export function RockMeasurements({ rec }: { rec: AtlasRecord }) {
  const c = rec.raw as Candidate;
  const v = c.values ?? {};
  const terr = c.cross_pathway?.terrain as Record<string, unknown> | undefined;
  return (
    <div>
      <table className="data">
        <thead><tr><th>Quantity (GLiM, 0.01° cells in the box)</th><th>Value</th></tr></thead>
        <tbody>
          <tr><td>Target rock class, share of mapped land</td><td className="num">{pct(v.mapped_target_fraction)}</td></tr>
          <tr><td>Target rock class on bare or sparse ground, share</td><td className="num">{pct(v.exposed_target_fraction)}</td></tr>
          <tr><td>Target rock class on bare or sparse ground, area</td><td className="num">{fmt(v.exposed_target_area_km2, 1)} km²</td></tr>
          <tr><td>Partner rock class, share</td><td className="num">{pct(v.partner_fraction)}</td></tr>
          <tr><td>Mineral spectra (EMIT)</td><td>{String(c.evidence_ladder?.G3_spectral ?? "not evaluated")}</td></tr>
        </tbody>
      </table>
      <h4>Terrain of the same place</h4>
      <p className="muted">{String(terr?.status ?? "not recorded")}</p>
    </div>
  );
}

export function ComparisonTable({ atlas, rows }: { atlas: Atlas; rows: ComparisonRow[] }) {
  return (
    <div className="tablewrap">
      <table className="data cmp">
        <thead><tr><th>Property</th><th>Role</th><th>Mars: what is reported</th><th>Earth: map record for this unit</th></tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.property}>
              <td><strong>{label(r.property)}</strong><div className="code">{r.property}</div></td>
              <td>{r.role_label ?? r.role}</td>
              <td>
                {r.mars_statement ?? "not recorded"}
                <div className="meta">{r.mars_evidence_type && r.mars_evidence_type !== "not_applicable" ? <span className="tag">{r.mars_evidence_type}</span> : null}{r.mars_site ? <span className="tag">{r.mars_site}</span> : null} <Citations atlas={atlas} keys={r.citations} /></div>
              </td>
              <td>
                <span className={/^(recorded|corroborated)/.test(r.earth_status ?? "") ? "yes" : /^CONTRADICTION/.test(r.earth_status ?? "") ? "no" : ""}>{r.earth_status ?? "not recorded"}</span>
                {r.earth_text ? <div className="quote" title="Excerpt of the map-unit description stored by the engine">"…{r.earth_text.trim()}…"</div> : null}
                {r.earth_source ? <div className="meta">Source: {r.earth_source}</div> : null}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function GeoMeasurements({ atlas, rec }: { atlas: Atlas; rec: AtlasRecord }) {
  const u = rec.raw as GeoUnit;
  const sc = u.spatial_context ?? {};
  const ms = u.macrostrat;
  return (
    <div>
      <h4>Map relationships (computed from unit polygons)</h4>
      <table className="data"><tbody>
        <tr><td>Boundary shared with mapped lava-flow units</td><td className="num">{fmt(sc.shared_perimeter_with_lava_flows_km)} km</td></tr>
        <tr><td>Boundary shared with mapped lake units</td><td className="num">{fmt(sc.shared_perimeter_with_lake_units_km)} km</td></tr>
        <tr><td>Within 10 km of a mapped lake unit</td><td>{typeof sc.within_10km_of_mapped_lake_unit === "boolean" ? (sc.within_10km_of_mapped_lake_unit ? "Yes" : "No") : "not recorded"}</td></tr>
        <tr><td>Share of area within 500 m of an intrusive contact</td><td className="num">{pct(sc.share_within_500m_of_intrusive_contact)} <span className="muted">possible heat alteration; values are for the representative polygon</span></td></tr>
      </tbody></table>
      <h4>Exposure and access (proxies)</h4>
      <table className="data"><tbody>
        <tr><td>Ground steeper than 25° inside the unit</td><td className="num">{fmt(u.steep_ground_km2, 3)} km²</td></tr>
        <tr><td>…of which on PAD-US "Open access" land</td><td className="num">{fmt(u.public_steep_ground_km2, 3)} km²</td></tr>
        <tr><td>Public lands containing steep ground</td><td>{(u.public_lands_with_steep_ground ?? []).length ? (u.public_lands_with_steep_ground ?? []).join("; ") : "none found"}</td></tr>
      </tbody></table>
      <p className="muted">{u.exposure_note ?? ""} Small squares on the map mark the largest steep public patches. They are computed search areas, not trail destinations, and no one has confirmed rock there.</p>
      <h4>Map source and positional uncertainty</h4>
      <table className="data"><tbody>
        <tr><td>Source map</td><td>{u.map_source?.reference ?? "not recorded"}</td></tr>
        <tr><td>Scale</td><td>{u.map_source?.scale ? `1:${u.map_source.scale.toLocaleString("en-US")}` : "not recorded"}</td></tr>
        <tr><td>Contact position uncertainty</td><td>{u.map_source?.contact_position_uncertainty_m ? `about ±${u.map_source.contact_position_uncertainty_m} m` : "not recorded"}</td></tr>
      </tbody></table>
      <h4>Macrostrat corroboration</h4>
      <p>{typeof ms?.name_matches === "number" ? `${ms.name_matches} unit(s) matched by name; ${fmt(ms.accepted, 0)} accepted after the distance (150 km) and age-overlap checks.` : "Macrostrat was not queried for this unit."}{(ms?.rejected ?? []).length ? ` Rejected: ${(ms?.rejected ?? []).map((r) => `${r.strat_name ?? "unit"} (${r.reason ?? "reason not recorded"})`).join("; ")}.` : ""}</p>
    </div>
  );
}

// ---------------------------------------------------------------- limits
export function Limits({ atlas, rec }: { atlas: Atlas; rec: AtlasRecord }) {
  const b = atlas.bundle;
  const list = (title: string, items?: string[]) => items && items.length ? (<><h4>{title}</h4><ul>{items.map((x) => <li key={x}>{x}</li>)}</ul></>) : null;
  if (rec.kind === "geo2") {
    const u = rec.raw as GeoUnit;
    return (
      <div className="prose">
        {list("Not measured for this unit", u.unmeasured)}
        {list("Cannot be compared with Mars", u.not_comparable)}
        {list("Recorded conflicts", u.conflicts)}
        {list("Limits of the regional geology method", b.geology_v2?.limitations)}
        <p className="muted">Regional refinement searched the Newark and Hartford study areas only. It is not a global geological run.</p>
      </div>
    );
  }
  const c = rec.raw as Candidate;
  return (
    <div className="prose">
      {list("Evidence against", c.evidence?.contradicting)}
      {list("Not measured for this record", c.evidence?.unmeasured)}
      {list(`Cannot be compared with ${rec.body === "Moon" ? "the Moon" : "Mars"}`, c.evidence?.not_comparable)}
      {rec.kind === "terrain" ? list("Coverage limits of the terrain run", b.run?.known_coverage_limits) : null}
      {list("Limits of the method", b.limitations)}
      <p className="muted">Selected run: {b.run?.manifest_describe_as ?? "coverage statement missing"}.</p>
    </div>
  );
}

// ---------------------------------------------------------------- sources
type Prov = { field: string; kind: string; sources: string[]; detail: string };
export function provenance(rec: AtlasRecord): Prov[] {
  if (rec.kind === "terrain") {
    const body = rec.body;
    const refKey = body === "Moon" ? ["lola", "pgda78"] : ["mars-dem"];
    return [
      { field: "Earth slope and roughness (properties, distances)", kind: "Computed from an elevation model", sources: ["cop-dem"], detail: "Plane-fit slope and detrended roughness on a 100 m grid at each baseline; 50 quantiles per 10 km window." },
      { field: "Reference percentile bands", kind: "Computed from a planetary elevation model", sources: refKey, detail: body === "Moon" ? "Same slope computation on LOLA 20 m/pixel data aggregated to 100 m." : "Same slope computation on the 200 m/pixel Mars DEM; only 1600 m and 3200 m baselines." },
      { field: "Land-cover fractions and mask", kind: "Classified satellite product", sources: ["worldcover"], detail: "Masked classes: tree cover, cropland, built-up, water, wetland, mangroves." },
      { field: "Rock classes under the window", kind: "Map classification (context only)", sources: ["glim"], detail: "0.01° raster of GLiM classes over the exact window square." },
    ];
  }
  if (rec.kind === "rock") {
    return [
      { field: "Mapped target and partner rock classes", kind: "Map classification", sources: ["glim"], detail: "Share of 0.01° cells in the box; source maps 1:1M to 1:5M." },
      { field: "Exposed share and area", kind: "Classified satellite product", sources: ["worldcover"], detail: "Cells classed bare/sparse vegetation or moss and lichen." },
      { field: "Mineral spectra", kind: "Not evaluated", sources: [], detail: "No spectral data are used in this run." },
    ];
  }
  return [
    { field: "Lithology (major/minor), unit description, age", kind: "Mapped lithology and map-text evidence", sources: ["sgmc"], detail: "State geologic map unit, as compiled in SGMC. A map classification at 1:100,000–1:250,000." },
    { field: "Neighbour and intrusive-contact relationships", kind: "Computed from map polygons", sources: ["sgmc"], detail: "Shared boundary length and 500 m buffer of intrusive units." },
    { field: "Corroboration of lithology and environment", kind: "Independent database, constrained by distance and age", sources: ["macrostrat"], detail: "Never establishes a required property alone." },
    { field: "Steep ground", kind: "Proxy from an elevation model", sources: ["3dep"], detail: "Slope of 25° or more on a ~20 m grid. Not confirmed rock." },
    { field: "Public access", kind: "Proxy from a land-status layer", sources: ["padus"], detail: "'Open access' areas only." },
    { field: "Mars properties", kind: "Published rover and orbiter observations and interpretations", sources: [], detail: "Listed per property with citations in the comparison table." },
  ];
}

export function SourcesTable({ rec }: { rec: AtlasRecord }) {
  const rows = provenance(rec);
  return (
    <div>
      <div className="tablewrap">
        <table className="data">
          <thead><tr><th>Fields in this record</th><th>Kind of evidence</th><th>Source product</th><th>Resolution / scale</th></tr></thead>
          <tbody>
            {rows.map((p) => (
              <tr key={p.field}>
                <td>{p.field}<div className="meta">{p.detail}</div></td>
                <td>{p.kind}</td>
                <td>{p.sources.length ? p.sources.map((k, i) => { const s = SOURCE_BY_KEY.get(k) as SourceEntry; return (<div key={k}>{i > 0 ? null : null}<SourceLink k={k} /><div className="meta">{s.product}</div></div>); }) : <span className="muted">—</span>}</td>
                <td>{p.sources.length ? p.sources.map((k) => <div key={k}>{SOURCE_BY_KEY.get(k)?.resolution}</div>) : <span className="muted">—</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted">These are the run-wide inputs for this pathway. The bundle does not list which individual source tiles or scenes contributed to this record, so tile-level lineage is not claimed. Raw source pixels and map polygons are not included in this record.</p>
    </div>
  );
}

// ---------------------------------------------------------------- reference detail
export function ReferenceDetail({ atlas, id }: { atlas: Atlas; id: string }) {
  const t = atlas.terrainRefs.get(id);
  const g = atlas.geoRefs.get(id);
  if (t) return <TerrainRefDetail refr={t} />;
  if (g) {
    return (
      <div className="prose">
        <p>{g.name}</p>
        {g.site_note ? <p className="muted">{g.site_note}</p> : null}
        {(g.locations ?? []).length ? <p className="muted">Mars locations: {(g.locations ?? []).map((l) => `${l.site ?? "site"} (${fmt(l.lat)}° N, ${fmt(l.lon)}° E)`).join("; ")}</p> : null}
        <div className="tablewrap">
          <table className="data cmp">
            <thead><tr><th>Property</th><th>Role</th><th>What is reported on Mars</th><th>Evidence</th></tr></thead>
            <tbody>
              {(g.properties ?? []).map((p) => (
                <tr key={p.code}><td><strong>{label(p.code)}</strong><div className="code">{p.code}</div></td><td>{p.role_label ?? p.role}</td><td>{p.statement}</td>
                  <td>{p.evidence_type && p.evidence_type !== "not_applicable" ? <span className="tag">{p.evidence_type}</span> : <span className="muted">Earth-side only</span>}{p.mars_site ? <span className="tag">{p.mars_site}</span> : null}<div className="meta"><Citations atlas={atlas} keys={p.citations} /></div></td></tr>
              ))}
            </tbody>
          </table>
        </div>
        {(g.not_comparable ?? []).length ? (<><h4>Cannot be compared</h4><ul>{(g.not_comparable ?? []).map((x) => <li key={x}>{x}</li>)}</ul></>) : null}
      </div>
    );
  }
  return <p className="muted">Reference {id} is not in the loaded bundle.</p>;
}

function TerrainRefDetail({ refr }: { refr: TerrainReference }) {
  const loc = REFERENCE_LOCATIONS[refr.id];
  const bands = refr.slope_bands_deg ?? {};
  const rows = Object.keys(bands).map(Number).sort((a, b) => a - b).map((k) => ({ label: `${k} m`, band: bands[String(k)] }));
  const y = refr.yardstick as Record<string, unknown> | null | undefined;
  return (
    <div className="prose">
      <table className="kv"><tbody>
        <tr><th scope="row">Body</th><td>{refr.body}</td></tr>
        <tr><th scope="row">Reference type</th><td>{refr.ref_type ?? "not recorded"}</td></tr>
        <tr><th scope="row">Where</th><td>{loc ? `${loc.text} — ${loc.source}` : "location not recorded in the bundle"}</td></tr>
        <tr><th scope="row">Why it is included</th><td>{refr.exploration_purpose ?? "not recorded"}</td></tr>
        <tr><th scope="row">Grid and baselines</th><td>{typeof refr.grid_m === "number" ? `${Math.round(refr.grid_m)} m grid` : "grid not recorded"}; {(refr.baselines_m ?? []).length ? `baselines ${(refr.baselines_m ?? []).join(", ")} m` : "no terrain baselines (rock-type pathway only)"}</td></tr>
        <tr><th scope="row">Elevation source</th><td>{refr.body === "Moon" ? <><SourceLink k="lola" /> with <SourceLink k="pgda78" /></> : (refr.baselines_m ?? []).length ? <SourceLink k="mars-dem" /> : "none: this reference is used by rock-type screening only"}</td></tr>
        {y ? <tr><th scope="row">Yardstick</th><td>{Object.entries(y).map(([k, v]) => `${k}: ${v}`).join("; ")}</td></tr> : null}
      </tbody></table>
      {rows.length ? <BandPlot rows={rows} body={refr.body} unit="degrees" axisLabel="Plane-fit slope" note={`Slope distribution of ${refr.id} at each baseline.`} /> : null}
      {refr.connectivity_curve && Object.keys(refr.connectivity_curve).length ? <ConnectivityChart curve={refr.connectivity_curve} body={refr.body} baselineM={refr.body === "Moon" ? 800 : 1600} /> : null}
      {(refr.warnings ?? []).length ? (<><h4>Warnings</h4><ul>{(refr.warnings ?? []).map((x) => <li key={x}>{x}</li>)}</ul></>) : null}
      {(refr.not_comparable ?? []).length ? (<><h4>Cannot be compared with Earth</h4><ul>{(refr.not_comparable ?? []).map((x) => <li key={x}>{x}</li>)}</ul></>) : null}
    </div>
  );
}
