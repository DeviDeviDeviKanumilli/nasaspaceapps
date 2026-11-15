"use client";
import { useMemo, useState } from "react";
import type { Atlas, AtlasRecord, Candidate, GeoUnit, RecordKind } from "@/lib/types";
import type { Area, DrawMode } from "./Globe";
import { DEFAULT_FILTERS, activeFilterCount, describeArea, type FilterResult, type Filters } from "@/lib/filter";
import { haversineKm, formatLatLon } from "@/lib/geo";
import { PROFILES } from "@/lib/profiles";
import { IconBack, IconInfo } from "./Icons";

const KIND_LABEL: Record<RecordKind, string> = { terrain: "Terrain windows", rock: "Rock-type screening (GLiM)", geo2: "Mapped geologic units (geo-2.0)" };

export function recordLine(r: AtlasRecord): string {
  if (r.kind === "terrain") {
    const c = r.raw as Candidate;
    const d = c.distances?.worst_scale_slope_W1_deg;
    return `${formatLatLon(r.lat, r.lon, 2)} · slope distance ${typeof d === "number" ? d.toFixed(2) + "°" : "not recorded"}`;
  }
  if (r.kind === "rock") {
    const c = r.raw as Candidate;
    return `${formatLatLon(r.lat, r.lon, 2)} · tier ${c.tier ?? "not recorded"}`;
  }
  const u = r.raw as GeoUnit;
  return `${u.state ?? ""} · ${(u.supporting_recorded ?? []).length} of ${u.supporting_total ?? "?"} supporting properties recorded`;
}

// ------------------------------------------------------------------ Find analogs
export function FindPanel({ atlas, filters, setFilters, result, selectedId, location, onSelect, onReference, onArea }: {
  atlas: Atlas; filters: Filters; setFilters: (f: Filters | ((f: Filters) => Filters)) => void; result: FilterResult; selectedId: string | null;
  location: { lat: number; lon: number } | null; onSelect(id: string): void; onReference(id: string): void; onArea(): void;
}) {
  const [limit, setLimit] = useState(40);
  // counts per reference under the current filters, ignoring the reference filter itself
  const perRef = useMemo(() => {
    const m = new Map<string, number>();
    for (const r of atlas.records) {
      if (filters.body !== "all" && r.body !== filters.body) continue;
      if (!filters.kinds[r.kind]) continue;
      m.set(r.referenceId, (m.get(r.referenceId) ?? 0) + 1);
    }
    return m;
  }, [atlas, filters.body, filters.kinds]);
  const refs = useMemo(() => {
    const out: { id: string; body: string; label: string; total: number }[] = [];
    for (const t of atlas.terrainRefs.values()) out.push({ id: t.id, body: t.body, label: t.description ?? t.id, total: atlas.records.filter((r) => r.referenceId === t.id).length });
    for (const g of atlas.geoRefs.values()) out.push({ id: g.id, body: "Mars", label: g.name, total: atlas.records.filter((r) => r.referenceId === g.id).length });
    return out;
  }, [atlas]);
  const centre = filters.area?.type === "circle" ? { lat: filters.area.lat, lon: filters.area.lon } : location;
  const sorted = useMemo(() => {
    const list = [...result.records];
    if (centre) list.sort((a, b) => haversineKm(centre.lat, centre.lon, a.lat, a.lon) - haversineKm(centre.lat, centre.lon, b.lat, b.lon));
    return list;
  }, [result, centre]);
  const toggleRef = (id: string) => setFilters((f) => ({ ...f, refs: f.refs.includes(id) ? f.refs.filter((x) => x !== id) : [...f.refs, id] }));
  const n = activeFilterCount(filters);

  return (
    <div className="panel fill">
      <div className="controls">
        <p className="lede">Filters the records already computed. Choosing a reference does not start a new analysis.</p>
        <div className="seg" role="group" aria-label="Planetary body">
          {(["all", "Moon", "Mars"] as const).map((b) => (<button key={b} className={filters.body === b ? "on" : ""} aria-pressed={filters.body === b} onClick={() => setFilters((f) => ({ ...f, body: b }))}>{b === "all" ? "All" : b}</button>))}
        </div>
        <div className="checks" role="group" aria-label="Pathway">
          {(["terrain", "rock", "geo2"] as RecordKind[]).map((k) => (
            <label key={k} className="check"><input type="checkbox" checked={filters.kinds[k]} onChange={(e) => setFilters((f) => ({ ...f, kinds: { ...f.kinds, [k]: e.target.checked } }))} /> {KIND_LABEL[k]} <span className="count">{atlas.counts[k]}</span></label>
          ))}
        </div>
        <div className="refs" role="group" aria-label="Planetary reference">
          {(["Moon", "Mars"] as const).filter((b) => filters.body === "all" || filters.body === b).map((b) => (
            <div key={b}>
              <div className={`grouplab ${b.toLowerCase()}`}>{b} references</div>
              {refs.filter((r) => r.body === b).map((r) => {
                const c = perRef.get(r.id) ?? 0;
                return (
                  <div key={r.id} className={`refrow${filters.refs.includes(r.id) ? " on" : ""}${c === 0 ? " none" : ""}`}>
                    <button className="pick" aria-pressed={filters.refs.includes(r.id)} title={`${r.id}: ${r.label}`} onClick={() => toggleRef(r.id)}>
                      <span className="rid">{r.id}</span><span className="rlab">{r.label}</span><span className="count">{c}</span>
                    </button>
                    <button className="info" title={`About reference ${r.id}`} aria-label={`About reference ${r.id}`} onClick={() => onReference(r.id)}><IconInfo /></button>
                  </div>
                );
              })}
            </div>
          ))}
        </div>
        <div className="resulthead">
          <strong>{result.records.length}</strong> of {atlas.counts.total} records
          {n > 0 && <button className="link" onClick={() => setFilters(DEFAULT_FILTERS)}>Clear all filters</button>}
        </div>
        {filters.area && <p className="active">Area: {describeArea(filters.area)} <button className="link" onClick={onArea}>Edit</button></p>}
        {(filters.insideYardstick || filters.tiers.length > 0) && <p className="active">Evidence filter active{result.notApplicable ? `; ${result.notApplicable} records do not carry that value and are left out` : ""}. <button className="link" onClick={onArea}>Edit</button></p>}
        {centre && <p className="muted small" style={{ margin: "6px 0 0" }}>Sorted by distance from {formatLatLon(centre.lat, centre.lon, 2)}.</p>}
      </div>
      <div className="results-scroll">
        {result.records.length === 0 ? (
          <p className="empty">No loaded record matches these filters. Nothing has been computed for this combination; widen the area or clear a filter.</p>
        ) : (
          <ul className="reclist">
            {sorted.slice(0, limit).map((r) => (
              <li key={r.id}>
                <button className={r.id === selectedId ? "on" : ""} onClick={() => onSelect(r.id)}>
                  <i className={`sym ${r.kind === "terrain" ? "circle" : r.kind === "rock" ? "square" : "diamond"} ${r.body.toLowerCase()}`} />
                  <span className="t">{r.title}<em>{r.referenceId}</em></span>
                  <span className="s">{recordLine(r)}{centre ? ` · ${Math.round(haversineKm(centre.lat, centre.lon, r.lat, r.lon)).toLocaleString("en-US")} km away` : ""}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
        {sorted.length > limit && <button className="more" onClick={() => setLimit((l) => l + 60)}>Show more ({sorted.length - limit} remaining)</button>}
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ Base profiles
export function ProfilesPanel({ atlas, profileId, setProfileId, onReference, onShow }: {
  atlas: Atlas; profileId: string | null; setProfileId(id: string | null): void; onReference(id: string): void; onShow(refs: string[], kinds: RecordKind[]): void;
}) {
  const p = PROFILES.find((x) => x.id === profileId) ?? null;
  const has = (id: string) => atlas.terrainRefs.has(id) || atlas.geoRefs.has(id);
  const countFor = (refs: string[], kinds: RecordKind[]) => atlas.records.filter((r) => refs.includes(r.referenceId) && kinds.includes(r.kind)).length;
  if (!p) {
    return (
      <div className="panel">
        <h2>Exploration scenarios</h2>
        <p className="lede">Team-defined study questions. They are not sites selected or endorsed by NASA, and none produces a suitability score.</p>
        <ul className="profiles">
          {PROFILES.map((x) => (
            <li key={x.id}>
              <button onClick={() => setProfileId(x.id)}>
                <span className={`grouplab ${x.body.toLowerCase()}`}>{x.body}</span>
                <span className="t">{x.title}</span>
                <span className="s">{x.question}</span>
                <span className="s meta">References: {x.references.join(", ")} · {countFor(x.references, x.kinds)} Earth records</span>
              </button>
            </li>
          ))}
        </ul>
        <p className="muted small" style={{ marginTop: 14 }}>Every planetary reference can also be browsed without a scenario under Find analogs.</p>
      </div>
    );
  }
  const n = countFor(p.references, p.kinds);
  const groups: [string, string][] = [["measured", "Measured in the loaded run"], ["proxy", "Proxy only"], ["not measured", "Not measured"]];
  return (
    <div className="panel">
      <button className="link back" onClick={() => setProfileId(null)} style={{ display: "inline-flex", alignItems: "center", gap: 4 }}><IconBack /> All scenarios</button>
      <div className={`grouplab ${p.body.toLowerCase()}`}>{p.body}</div>
      <h2>{p.title}</h2>
      <p className="scenario-meta">Team-defined scenario · not a NASA site selection</p>
      <p className="lede">{p.question}</p>

      <h3>Planetary references used</h3>
      {p.references.map((id) => {
        const t = atlas.terrainRefs.get(id); const g = atlas.geoRefs.get(id);
        return (
          <div key={id} className="refrow static">
            <button className="pick" onClick={() => onReference(id)} disabled={!has(id)}><span className="rid">{id}</span><span className="rlab">{t?.description ?? g?.name ?? "not in the loaded bundle"}</span></button>
          </div>
        );
      })}
      {p.relatedReferences.filter((r) => has(r.id)).map((r) => (
        <div key={r.id} className="refrow static related">
          <button className="pick" onClick={() => onReference(r.id)}><span className="rid">{r.id}</span><span className="rlab">Related: {r.why}</span></button>
        </div>
      ))}

      <button className="primary" disabled={n === 0} onClick={() => onShow(p.references, p.kinds)}>View {n} related Earth records</button>
      <p className="muted small">This filters the loaded records by reference{p.kinds.length === 1 ? ` (${KIND_LABEL[p.kinds[0]].toLowerCase()})` : ""}. No weighting or combined score is applied.</p>

      {groups.map(([status, title]) => {
        const dims = p.dimensions.filter((d) => d.status === status);
        if (!dims.length) return null;
        return (
          <section key={status} className={`dims ${status.replace(" ", "-")}`}>
            <h3>{title}</h3>
            <dl>{dims.map((d) => (<div key={d.name}><dt>{d.name}</dt><dd>{d.note}</dd></div>))}</dl>
          </section>
        );
      })}

      <h3>Not established</h3>
      <ul className="plain">{p.notEstablished.map((x) => <li key={x}>{x}</li>)}</ul>
      <h3>Context</h3>
      <ul className="plain">{p.context.map((c) => <li key={c.url}><a href={c.url} target="_blank" rel="noreferrer">{c.label}</a></li>)}</ul>
    </div>
  );
}

// ------------------------------------------------------------------ Search area
export function AreaPanel({ atlas, filters, setFilters, result, drawMode, setDrawMode, location, onShowList, onFit }: {
  atlas: Atlas; filters: Filters; setFilters: (f: Filters | ((f: Filters) => Filters)) => void; result: FilterResult; drawMode: DrawMode; setDrawMode(m: DrawMode): void;
  location: { lat: number; lon: number } | null; onShowList(): void; onFit(a: Area): void;
}) {
  const a = filters.area;
  const circle = a?.type === "circle" ? a : null;
  const [lat, setLat] = useState(circle ? String(circle.lat) : "");
  const [lon, setLon] = useState(circle ? String(circle.lon) : "");
  const [rad, setRad] = useState(circle ? String(circle.radiusKm) : "150");
  const [err, setErr] = useState<string | null>(null);
  // keep inputs in step when the centre is picked on the map
  const key = circle ? `${circle.lat},${circle.lon},${circle.radiusKm}` : "";
  const [seen, setSeen] = useState(key);
  if (key !== seen) { setSeen(key); if (circle) { setLat(String(circle.lat)); setLon(String(circle.lon)); setRad(String(circle.radiusKm)); } }

  const apply = () => {
    const la = parseFloat(lat), lo = parseFloat(lon), r = parseFloat(rad);
    if (!isFinite(la) || Math.abs(la) > 90) return setErr("Latitude must be a number between -90 and 90.");
    if (!isFinite(lo) || Math.abs(lo) > 180) return setErr("Longitude must be a number between -180 and 180.");
    if (!isFinite(r) || r <= 0 || r > 20000) return setErr("Radius must be between 0 and 20,000 km.");
    setErr(null);
    const area: Area = { type: "circle", lat: la, lon: lo, radiusKm: r };
    setFilters((f) => ({ ...f, area }));
    onFit(area);
  };
  const kinds = { terrain: 0, rock: 0, geo2: 0 };
  for (const r of result.records) kinds[r.kind]++;

  return (
    <div className="panel">
      <p className="lede">Limits the loaded records to a place. The count is of records already computed; no new analysis is run for the area.</p>

      <h3>Distance from a point</h3>
      <div className="row3">
        <label>Latitude<input inputMode="decimal" value={lat} onChange={(e) => setLat(e.target.value)} placeholder="40.33" /></label>
        <label>Longitude<input inputMode="decimal" value={lon} onChange={(e) => setLon(e.target.value)} placeholder="-74.60" /></label>
        <label>Radius, km<input inputMode="decimal" value={rad} onChange={(e) => setRad(e.target.value)} /></label>
      </div>
      <div className="btnrow">
        <button className="primary" onClick={apply}>Apply</button>
        <button className={drawMode === "point" ? "on" : ""} onClick={() => setDrawMode(drawMode === "point" ? null : "point")}>Pick centre on map</button>
        {location && <button onClick={() => { setLat(location.lat.toFixed(4)); setLon(location.lon.toFixed(4)); }}>Use selected location</button>}
      </div>
      {err && <p className="warn">{err}</p>}

      <h3>Draw on the map</h3>
      <div className="btnrow">
        <button className={drawMode === "rect" ? "on" : ""} onClick={() => setDrawMode(drawMode === "rect" ? null : "rect")}>Rectangle</button>
        <button className={drawMode === "polygon" ? "on" : ""} onClick={() => setDrawMode(drawMode === "polygon" ? null : "polygon")}>Polygon</button>
      </div>
      <p className="muted small">Country and state outlines are not offered: the loaded data has no boundary files, and a rectangle would misstate a border.</p>

      <h3>Evidence</h3>
      <label className="check"><input type="checkbox" checked={filters.insideYardstick} onChange={(e) => setFilters((f) => ({ ...f, insideYardstick: e.target.checked }))} /> Terrain: inside the reference yardstick only</label>
      <div className="check tiers">Rock-type tier:
        {["G1", "G2", "G4"].map((t) => (<label key={t}><input type="checkbox" checked={filters.tiers.includes(t)} onChange={(e) => setFilters((f) => ({ ...f, tiers: e.target.checked ? [...f.tiers, t] : f.tiers.filter((x) => x !== t) }))} /> {t}</label>))}
      </div>
      <p className="muted small">An evidence filter keeps only records that carry that value. Records from other pathways are left out as "not applicable", not as failures.</p>

      <div className="resulthead">
        <strong>{result.records.length}</strong> of {atlas.counts.total} loaded records match
        {activeFilterCount(filters) > 0 && <button className="link" onClick={() => setFilters(DEFAULT_FILTERS)}>Reset</button>}
      </div>
      {a ? <p className="active">Area: {describeArea(a)} <button className="link" onClick={() => setFilters((f) => ({ ...f, area: null }))}>Remove area</button> <button className="link" onClick={() => onFit(a)}>Zoom to area</button></p> : <p className="muted small">No area set. All places are included.</p>}
      {result.records.length === 0 ? (
        <p className="empty">No loaded record falls inside this selection. That means nothing was nominated here in the loaded run, not that the area was analysed and rejected. Turn on the coverage layer to see what the terrain run processed.</p>
      ) : (
        <>
          <p className="muted small">{kinds.terrain} terrain windows · {kinds.rock} rock-type boxes · {kinds.geo2} mapped units{result.notApplicable ? ` · ${result.notApplicable} not applicable to the evidence filter` : ""}</p>
          <button onClick={onShowList}>List these records</button>
        </>
      )}
    </div>
  );
}
