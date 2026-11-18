"use client";
// Data & methods: every value on this page is read from the loaded bundle or from the fixed source catalogue.
import { useEffect, useState } from "react";
import Link from "next/link";
import { loadAtlas } from "@/lib/adapter";
import { APP_NAME, BASE_PATH, TEAM } from "@/lib/config";
import { REPO_URL, SOURCES, doiUrl } from "@/lib/sources";
import type { Atlas } from "@/lib/types";

const WC: Record<string, string> = { "10": "tree cover", "20": "shrubland", "30": "grassland", "40": "cropland", "50": "built-up", "60": "bare / sparse vegetation", "70": "snow and ice", "80": "permanent water", "90": "herbaceous wetland", "95": "mangroves", "100": "moss and lichen" };

export default function Methods() {
  const [atlas, setAtlas] = useState<Atlas | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => { loadAtlas(BASE_PATH).then(setAtlas).catch((e: Error) => setErr(e.message)); }, []);
  if (err) return <main className="docpage"><div className="doc"><p>The results bundle could not be loaded: {err}</p><p><Link href="/">Back to the globe</Link></p></div></main>;
  if (!atlas) return <main className="docpage" aria-busy="true"><div className="doc"><p>Loading…</p></div></main>;
  const b = atlas.bundle;
  const run = b.run ?? {};
  const p = (run.parameters ?? {}) as Record<string, unknown>;
  const g2 = b.geology_v2;
  const ext = atlas.coverage.length ? { s: Math.min(...atlas.coverage.map((t) => t.south)), n: Math.max(...atlas.coverage.map((t) => t.south)) + 1, w: Math.min(...atlas.coverage.map((t) => t.west)), e: Math.max(...atlas.coverage.map((t) => t.west)) + 1 } : null;
  const isGlobal = !!ext && ext.e - ext.w >= 300 && ext.n - ext.s >= 120;
  const missing = Object.entries(run.tiles ?? {}).filter(([k]) => /missing|failed/i.test(k)).reduce((a, [, v]) => a + v, 0);
  const list = (v: unknown) => (Array.isArray(v) ? v.join(", ") : String(v ?? "not recorded"));
  const classes = (v: unknown) => (Array.isArray(v) ? v.map((c) => `${c} ${WC[String(c)] ?? ""}`.trim()).join("; ") : "not recorded");
  return (
    <main className="docpage">
    <div className="doc">
      <header className="dochead">
        <Link href="/" className="backbtn">Back to the globe</Link>
        <div className="brand"><b>{APP_NAME}</b><span>Earth analog atlas</span></div>
        <a href={REPO_URL} className="backbtn" style={{ marginLeft: "auto" }} target="_blank" rel="noreferrer">Code on GitHub</a>
      </header>
      <h1>Data &amp; methods</h1>
      <p className="lede">What was computed, from which data, at what scale, and what it does not show. {TEAM}.</p>

      <nav className="toc" aria-label="On this page">
        <a href="#status">Run status and coverage</a><a href="#records">What a record is</a><a href="#terrain">Terrain pathway</a><a href="#rock">Rock-type screening</a><a href="#geo2">Regional geology (geo-2.0)</a><a href="#datasets">Datasets</a><a href="#literature">Literature</a><a href="#limits">Limits</a><a href="#code">Code and reproducibility</a>
      </nav>

      <section id="status">
        <h2>Run status and coverage</h2>
        <p className="statement">{isGlobal ? "Global terrain run" : "Terrain run"}. Run statement: <strong>{run.manifest_describe_as ?? "coverage statement missing from the bundle"}</strong></p>
        <table className="data"><tbody>
          <tr><td>Run created (UTC)</td><td>{run.created_utc ?? "not recorded"}</td></tr>
          <tr><td>1° tiles with evaluated windows</td><td className="num">{run.tiles?.windows ?? "not recorded"}</td></tr>
          <tr><td>1° tiles processed, no valid window</td><td className="num">{run.tiles?.no_valid_windows ?? "not recorded"}</td></tr>
          <tr><td>1° tiles skipped because land cover rules out every window</td><td className="num">{run.tiles?.skipped_landcover ?? "not recorded"}</td></tr>
          {missing > 0 ? <tr><td>Listed 1° tiles that failed or were not run</td><td className="num">{missing}</td></tr> : null}
          <tr><td>10 km windows evaluated</td><td className="num">{run.windows?.evaluated?.toLocaleString("en-US") ?? "not recorded"}</td></tr>
          {typeof run.windows?.excluded_snow_ice_gt_half === "number" ? <tr><td>Windows not nominated because more than half is snow or ice</td><td className="num">{run.windows.excluded_snow_ice_gt_half.toLocaleString("en-US")}</td></tr> : null}
          <tr><td>Bundle schema</td><td>{b.schema_version ?? "not recorded"}{g2?.block_version ? `; geology block ${g2.block_version}` : ""}</td></tr>
        </tbody></table>
        <p>{ext ? `The ${atlas.coverage.length.toLocaleString("en-US")} processed 1° tiles lie between ${Math.abs(ext.s)}° ${ext.s < 0 ? "S" : "N"} and ${Math.abs(ext.n)}° ${ext.n < 0 ? "S" : "N"}, and between ${Math.abs(ext.w)}° ${ext.w < 0 ? "W" : "E"} and ${Math.abs(ext.e)}° ${ext.e < 0 ? "W" : "E"}.` : "The bundle does not list the processed tiles."}{ext && ext.s >= -60 ? " No tile south of 60° S is in the loaded run, so Antarctica has no result." : ""}{missing > 0 ? ` ${missing} listed tiles failed or were not run and have no result.` : ""} Only tiles that exist in the Copernicus land-tile list can be processed; open ocean has none. The globe shows the whole Earth for navigation; that is not evidence that every place was analysed. Turn on <em>Analysis coverage</em> in the map layers to see each tile's status.</p>
        <h3>Known coverage limits of the terrain run</h3>
        <ul>{(run.known_coverage_limits ?? []).map((x) => <li key={x}>{x}</li>)}</ul>
        {atlas.issues.length > 0 && (<><h3>Bundle validation notes</h3><ul>{atlas.issues.map((x) => <li key={x}>{x}</li>)}</ul></>)}
      </section>

      <section id="records">
        <h2>What a record is</h2>
        <p>The bundle holds <strong>{atlas.counts.total} mappable records</strong>: {atlas.counts.terrain} terrain windows, {atlas.counts.rock} rock-type screening boxes and {atlas.counts.geo2} mapped geologic units. They come from three pathways at different scales. They are not {atlas.counts.total} independent places, and none is a verified field site: the same window can be nominated for several references, and a mapped unit stands for many polygons.</p>
        <table className="data">
          <thead><tr><th>Pathway</th><th>Record</th><th>Footprint on the map</th><th>Count</th></tr></thead>
          <tbody>
            <tr><td>Terrain</td><td>10 km window whose slope and roughness distributions are closest to a reference</td><td>Exact square, computed from the centre with the engine's projection</td><td className="num">{atlas.counts.terrain}</td></tr>
            <tr><td>Rock-type screening</td><td>0.1° box where the Global Lithological Map shows the target rock class</td><td>Exact box</td><td className="num">{atlas.counts.rock}</td></tr>
            <tr><td>Regional geology (geo-2.0)</td><td>Mapped geologic unit whose recorded properties meet a Mars reference's required properties</td><td>Representative point only; unit outlines are not in the bundle</td><td className="num">{atlas.counts.geo2}</td></tr>
          </tbody>
        </table>
        <p>Outcome vocabulary used for terrain properties: {list(b.outcome_vocabulary)}.</p>
      </section>

      <section id="terrain">
        <h2>Terrain pathway</h2>
        <ol>
          <li>Each 1° Copernicus GLO-90 tile is reprojected to a local azimuthal-equidistant grid of {String(p.grid_m ?? "?")} m.</li>
          <li>At every cell, a plane is fitted over a disc at each baseline ({list(p.baselines_m)} m). The plane's tilt is the slope; the spread of heights about the plane is the roughness.</li>
          <li>Cells under masked land cover are excluded (ESA WorldCover classes {classes(p.worldcover_masked_classes)}). Bare ground is classes {classes(p.exposure_classes)}; snow is {classes(p.snow_classes)}.</li>
          <li>For every window of {String(p.window_cells ?? "?")} × {String(p.window_cells ?? "?")} cells (step {String(p.stride_cells ?? "?")} cells) with at least {typeof p.min_valid_fraction === "number" ? p.min_valid_fraction * 100 : "?"}% usable cells, {String(p.quantile_levels ?? "?")} quantiles of slope and of log10 roughness are stored per baseline, plus a connectivity curve: the largest connected share of the window below each slope threshold ({list(p.connectivity_thresholds_deg)}°) at the {String(p.connectivity_baseline_m ?? "?")} m baseline.</li>
          <li>The same statistics are computed for each lunar and Martian reference from its own elevation model. Mars references use only the 1600 m and 3200 m baselines because the Mars model is 200 m per pixel.</li>
          <li>Window and reference are compared with the Wasserstein-1 distance between quantile sets at each baseline; the worst baseline is kept. Windows on the successive Pareto fronts of (slope distance, roughness distance, connectivity distance) are nominated, with 25 km suppression between nominees.</li>
          <li>The yardstick is the distance between real reference sites (or leave-one-site-out for the pooled zone classes). "Inside the yardstick" means a window is as close to the reference as real reference sites are to each other.</li>
        </ol>
        <p>Distances are in physical units (degrees, log10 units). They are not similarity percentages, and none is shown as one. Antarctic rule recorded by the run: {String(p.antarctic_rule ?? "not recorded")}.</p>
        <p>Software recorded by the run: {Object.entries(run.software ?? {}).map(([k, v]) => `${k} ${v}`).join("; ") || "not recorded"}.</p>
      </section>

      <section id="rock">
        <h2>Rock-type screening</h2>
        <p>Source: {String(b.geology_run?.source ?? "not recorded")}. Boxes of 0.1° latitude by 0.1°/cos(latitude) longitude are tiered: G1 when the target rock class covers at least {String((b.geology_run?.thresholds as Record<string, number> | undefined)?.G1_min_mapped ?? "?")} of mapped land; G2 when at least {String((b.geology_run?.thresholds as Record<string, number> | undefined)?.G2_min_exposed ?? "?")} of the box is target rock on bare ground; G4 when a partner rock class is also mapped in the box. G3 (mineral spectra, EMIT) is {String(b.geology_run?.emit ?? "not evaluated")}.</p>
        <p>This pathway screens for a mapped rock class from 1:1,000,000–1:5,000,000 maps. It does not establish matching mineralogy or a shared geological process, and it is separate from the regional geology engine below.</p>
      </section>

      <section id="geo2">
        <h2>Regional geology (geo-2.0)</h2>
        <p>A property-by-property comparison between mapped geologic units and published Mars observations, run in two regions only:</p>
        <table className="data">
          <thead><tr><th>Region</th><th>Role</th><th>Extent</th><th>Map polygons</th><th>Map units</th><th>Run</th></tr></thead>
          <tbody>{(g2?.regions ?? []).map((r) => (<tr key={r.id}><td>{r.id}</td><td>{r.role}</td><td>{r.radius_km} km around {r.centre[0]}°, {r.centre[1]}°</td><td className="num">{r.n_polygons?.toLocaleString("en-US") ?? "?"}</td><td className="num">{r.n_units ?? "?"}</td><td>{r.created ?? "not recorded"}</td></tr>))}</tbody>
        </table>
        <ol>
          <li>Each map unit gets an evidence profile: lithology from structured SGMC fields (major or minor); environment, structures, minerals and alteration from the unit description with a controlled vocabulary and a negation guard. Minerals named in map text are "mapped mentions", not measured mineralogy.</li>
          <li>Macrostrat can corroborate a property only when its unit lies within 150 km and overlaps in age. It never establishes a required property alone; its "inferred" environments are database defaults and are not used.</li>
          <li>Spatial context is measured from the polygons: boundary shared with lava-flow units and lake units, and the share of area within 500 m of an intrusion. A unit named as an intrusion (for example diabase) is not counted as a lava neighbour.</li>
          <li>A lake setting may be inferred without lake wording only for a mainly fine-grained clastic unit with no marine evidence, at least two independent drying or standing-water indicators, and a basin context. The record states whether the setting was recorded or inferred.</li>
          <li>A unit qualifies when every required property of the Mars reference is recorded and no ruling-out property is. Supporting properties are counted, never scored.</li>
          <li>Exposure and access are proxies: ground steeper than 25° on a ~20 m elevation grid, and whether it lies on PAD-US "Open access" land.</li>
        </ol>
        <h3>Controls</h3>
        <p>Units with a known answer from published formation descriptions, used for evaluation only. Precision is the share of selected units that were correct; recall is the share of known units that were found. The Newark figures were seen while the rules were being adjusted; the Hartford region was held out.</p>
        <table className="data">
          <thead><tr><th>Region</th><th>Reference</th><th>Method</th><th>Precision</th><th>Recall</th></tr></thead>
          <tbody>{(g2?.controls ?? []).map((c, i) => (<tr key={i}><td>{c.region}</td><td>{c.reference}</td><td>{c.method}</td><td className="num">{c.precision ?? "n/a"}</td><td className="num">{c.recall ?? "n/a"}</td></tr>))}</tbody>
        </table>
        <h3>Independent cross-check</h3>
        {(g2?.featured ?? []).map((f) => (<p key={f.id}>{f.title}. <strong>{f.outcome}.</strong> {f.note ? `Note: ${f.note}.` : ""} The guide's stop coordinates are not verified by this project and no field scan is part of the loaded results.</p>))}
      </section>

      <section id="datasets">
        <h2>Datasets</h2>
        <p>Inputs to the analysis are listed separately from what is only drawn on the globe. The bundle's own dataset strings are: {Object.entries(run.datasets ?? {}).map(([k, v]) => `${k}: ${v}`).join(" · ") || "not recorded"}.</p>
        <h3 id="nasa-lro">NASA challenge resource: Lunar Reconnaissance Orbiter</h3>
        <table className="data"><tbody>
          <tr><td>NASA Space Apps 2026 challenge-listed resource</td><td>Lunar Reconnaissance Orbiter (LRO)</td></tr>
          <tr><td>Dataset actually used</td><td>Lunar Orbiter Laser Altimeter (LOLA), an instrument on LRO: south-pole elevation model <code>LDEM_80S_20MPP_ADJ</code>, <a href="https://pgda.gsfc.nasa.gov/products/90" target="_blank" rel="noreferrer">Product 90</a> of the NASA GSFC Planetary Geodesy Data Archive (PGDA), with lunar site boundaries from <a href="https://pgda.gsfc.nasa.gov/products/78" target="_blank" rel="noreferrer">Product 78</a></td></tr>
          <tr><td>Where it was obtained</td><td>Read directly from NASA GSFC PGDA (<code>pgda.gsfc.nasa.gov</code>) by <a href={`${REPO_URL}/blob/main/engine/lolaread.py`} target="_blank" rel="noreferrer"><code>engine/lolaread.py</code></a></td></tr>
          <tr><td>How it is used</td><td>The LOLA elevation values inside each site boundary are averaged to a 100 m grid and turned into slope and roughness distributions at 400, 800, 1600 and 3200 m, plus a connectivity curve (<a href={`${REPO_URL}/blob/main/engine/build_refs.py`} target="_blank" rel="noreferrer"><code>engine/build_refs.py</code></a>, <a href={`${REPO_URL}/blob/main/engine/terrain_engine.py`} target="_blank" rel="noreferrer"><code>engine/terrain_engine.py</code></a>; pooled zone classes in <a href={`${REPO_URL}/blob/main/engine/build_zone_refs.py`} target="_blank" rel="noreferrer"><code>engine/build_zone_refs.py</code></a>). These are the lunar references M-CR, M-SR, M-DG, M-MA, MZ-FLAT and MZ-STEEP. Every Earth window is compared with them, and the closest windows are nominated as candidates (<a href={`${REPO_URL}/blob/main/engine/compare.py`} target="_blank" rel="noreferrer"><code>engine/compare.py</code></a>).</td></tr>
          <tr><td>What this does not mean</td><td>The candidates are this project's computed nominations. NASA has not reviewed, validated or endorsed any of them.</td></tr>
        </tbody></table>
        {(["analysis input", "planetary reference", "corroboration", "field proxy", "independent cross-check", "display only", "software"] as const).map((role) => {
          const items = SOURCES.filter((s) => s.role === role);
          if (!items.length) return null;
          return (
            <div key={role}>
              <h3>{role === "display only" ? "Display only (not analysis inputs)" : role[0].toUpperCase() + role.slice(1)}</h3>
              <div className="tablewrap">
                <table className="data src">
                  <thead><tr><th>Dataset</th><th>Product and version</th><th>Used for</th><th>Resolution</th><th>Licence and attribution</th></tr></thead>
                  <tbody>
                    {items.map((s) => (
                      <tr key={s.key} id={`src-${s.key}`}>
                        <td><strong>{s.name}</strong><div className="meta">{s.provider}</div>{s.url ? <div className="meta"><a href={s.url} target="_blank" rel="noreferrer">{s.urlLabel}</a></div> : <div className="meta">No online source is linked.</div>}</td>
                        <td>{s.product}{s.citation ? <div className="meta">{s.citationUrl ? <a href={s.citationUrl} target="_blank" rel="noreferrer">{s.citation}</a> : s.citation}</div> : null}</td>
                        <td>{s.usedFor}</td>
                        <td>{s.resolution}</td>
                        <td>{s.license}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          );
        })}
        <p className="muted">Other NASA data in the analysis: NASA MGS MOLA elevations within the USGS blended Mars model. The Mars geology references rest on published results from NASA's Curiosity and Perseverance rovers, listed below.</p>
      </section>

      <section id="literature">
        <h2>Literature for the Mars geology references</h2>
        <ul className="cites">{Object.entries(g2?.citations ?? {}).map(([k, v]) => { const u = doiUrl(v); return (<li key={k} id={`cite-${k}`}><span className="code">{k}</span><span>{u ? <a href={u} target="_blank" rel="noreferrer">{v}</a> : v}</span></li>); })}</ul>
      </section>

      <section id="limits">
        <h2>Limits</h2>
        <ul>{[...(b.limitations ?? []), ...(g2?.limitations ?? [])].map((x) => <li key={x}>{x}</li>)}</ul>
        <ul>
          <li>No record is a landing-safety, base-suitability or resource assessment.</li>
          <li>Illumination, ice, thermal environment, communications, dust and regolith properties are not measured anywhere in the loaded run.</li>
          <li>No field measurement is part of the loaded results.</li>
          <li>Searching for a place or coordinate navigates the globe. It does not analyse that place.</li>
        </ul>
      </section>

      <section id="code">
        <h2>Code and reproducibility</h2>
        <p>The analysis code, tests and result files are in the project repository: <a href={REPO_URL} target="_blank" rel="noreferrer">{REPO_URL.replace("https://", "")}</a>. The file this site reads is <code>web/app_bundle.json</code> (schema in <code>SCHEMA.md</code>). Map outlines are derived from each record's centre by <code>scripts/derive_geometry.py</code> using the engine's documented footprint rule.</p>
      </section>
    </div>
    </main>
  );
}
