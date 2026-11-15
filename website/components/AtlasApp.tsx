"use client";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import Globe, { type Area, type CameraInfo, type DrawMode, type GlobeHandle, type GlobeStatus, type HoverInfo, type Layers } from "./Globe";
import { FindPanel, ProfilesPanel, AreaPanel } from "./Panels";
import { Inspector, LocationCard, ClusterList } from "./Inspector";
import Workspace, { type WorkspaceState } from "./Workspace";
import { loadAtlas } from "@/lib/adapter";
import { applyFilters, DEFAULT_FILTERS, activeFilterCount, type Filters } from "@/lib/filter";
import { formatLatLon, niceScale, parseCoordinates } from "@/lib/geo";
import { APP_NAME, BASE_PATH } from "@/lib/config";
import type { Atlas, AtlasRecord } from "@/lib/types";

export type Mode = "explore" | "find" | "profiles" | "area";
type Loc = { lat: number; lon: number; label?: string };
type Place = { name: string; lat: number; lon: number; box: [number, number, number, number] | null };

export default function AtlasApp() {
  const [atlas, setAtlas] = useState<Atlas | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [mode, setMode] = useState<Mode>("explore");
  const [filters, setFilters] = useState<Filters>(DEFAULT_FILTERS);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [location, setLocation] = useState<Loc | null>(null);
  const [clusterIds, setClusterIds] = useState<string[] | null>(null);
  const [workspace, setWorkspace] = useState<WorkspaceState | null>(null);
  const [profileId, setProfileId] = useState<string | null>(null);
  const [drawMode, setDrawMode] = useState<DrawMode>(null);
  const [layers, setLayers] = useState<Layers>({ imagery: "satellite", labels: true, coverage: false, footprints: true, relief: true });
  const [layersOpen, setLayersOpen] = useState(false);
  const [hover, setHover] = useState<HoverInfo | null>(null);
  const [cam, setCam] = useState<CameraInfo | null>(null);
  const [cursor, setCursor] = useState<{ lat: number; lon: number } | null>(null);
  const [gstatus, setGstatus] = useState<GlobeStatus | null>(null);
  const [fatal, setFatal] = useState<string | null>(null);
  const [reducedMotion, setReducedMotion] = useState(false);
  const globe = useRef<GlobeHandle>(null);

  // ---- load data + URL state ----
  useEffect(() => {
    setReducedMotion(window.matchMedia("(prefers-reduced-motion: reduce)").matches);
    loadAtlas(BASE_PATH).then((a) => {
      setAtlas(a);
      const q = new URLSearchParams(window.location.search);
      const rid = q.get("record");
      if (rid && a.byId.has(rid)) {
        setSelectedId(rid);
        if (q.get("view") === "data") setWorkspace({ type: "record", id: rid, tab: "comparison" });
        setTimeout(() => { const r = a.byId.get(rid); if (r) globe.current?.flyToRecord(r); }, 2500);
      }
      const ref = q.get("reference");
      if (ref && (a.terrainRefs.has(ref) || a.geoRefs.has(ref))) setWorkspace({ type: "reference", id: ref });
    }).catch((e: Error) => setLoadError(e.message));
  }, []);
  useEffect(() => {
    if (!atlas) return;
    const q = new URLSearchParams();
    if (selectedId) q.set("record", selectedId);
    if (workspace?.type === "record") q.set("view", "data");
    if (workspace?.type === "reference") q.set("reference", workspace.id);
    const s = q.toString();
    window.history.replaceState(null, "", `${window.location.pathname}${s ? `?${s}` : ""}`);
  }, [atlas, selectedId, workspace]);

  const result = useMemo(() => (atlas ? applyFilters(atlas, filters) : null), [atlas, filters]);
  const selected = atlas && selectedId ? atlas.byId.get(selectedId) ?? null : null;

  const selectRecord = useCallback((id: string, fly = true) => {
    if (!atlas) return;
    const r = atlas.byId.get(id);
    if (!r) return;
    setSelectedId(id);
    setLocation(null);
    setClusterIds(null);
    setHover(null);
    if (fly) globe.current?.flyToRecord(r);
  }, [atlas]);

  const goToLocation = useCallback((lat: number, lon: number, label?: string, box?: [number, number, number, number] | null) => {
    setLocation({ lat, lon, label });
    setSelectedId(null);
    setClusterIds(null);
    if (box) globe.current?.flyToBox(box[0], box[1], box[2], box[3]);
    else globe.current?.flyToPoint(lat, lon, 90_000);
  }, []);

  const onMapClick = useCallback((lat: number, lon: number) => {
    setLocation({ lat, lon });
    setSelectedId(null);
    setClusterIds(null);
  }, []);

  const onDrawPoint = useCallback((lat: number, lon: number) => {
    setDrawMode(null);
    setFilters((f) => ({ ...f, area: { type: "circle", lat: +lat.toFixed(4), lon: +lon.toFixed(4), radiusKm: f.area?.type === "circle" ? f.area.radiusKm : 150 } }));
  }, []);
  const onDrawArea = useCallback((area: Area) => { setDrawMode(null); setFilters((f) => ({ ...f, area })); }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if (drawMode) { setDrawMode(null); return; }
      if (workspace) { setWorkspace(null); return; }
      if (layersOpen) { setLayersOpen(false); return; }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [drawMode, workspace, layersOpen]);

  if (loadError) {
    return (
      <main className="fatal">
        <h1>{APP_NAME}</h1>
        <p>The results bundle could not be loaded, so there is nothing to show.</p>
        <p className="muted">{loadError}</p>
        <button onClick={() => window.location.reload()}>Try again</button>
      </main>
    );
  }
  if (!atlas || !result) return <main className="loading" aria-busy="true"><span>Loading results…</span></main>;

  const scale = cam?.metersPerPixel ? niceScale(cam.metersPerPixel * 110) : null;
  const nFilters = activeFilterCount(filters);
  const railOpen = mode !== "explore";
  const sideOpen = !!(selected || location || clusterIds);
  const run = atlas.bundle.run;
  const tileCounts = run?.tiles ?? {};
  const tilesMissing = Object.entries(tileCounts).filter(([k]) => /missing|failed/i.test(k)).reduce((a, [, v]) => a + v, 0);
  const tilesListed = Object.values(tileCounts).reduce((a, b) => a + b, 0);
  const tilesDone = tilesListed - tilesMissing;
  const lons = atlas.coverage.map((t) => t.west), lats = atlas.coverage.map((t) => t.south);
  const isGlobal = atlas.coverage.length > 0 && Math.max(...lons) - Math.min(...lons) >= 300 && Math.max(...lats) - Math.min(...lats) >= 120;
  const runName = isGlobal ? "global terrain run" : "terrain run";
  const runText = !run?.tiles ? `${runName}: tile counts not recorded` : `${runName}: ${tilesDone.toLocaleString("en-US")} tiles processed`;

  return (
    <div className={`app${railOpen ? " rail-open" : ""}${sideOpen ? " side-open" : ""}${drawMode ? " drawing" : ""}`}>
      {fatal ? (
        <div className="noglobe"><p>{fatal}</p></div>
      ) : (
        <Globe
          ref={globe} atlas={atlas} visibleIds={result.ids} selected={selected} location={location} area={filters.area} drawMode={drawMode} layers={layers} reducedMotion={reducedMotion}
          onSelect={(id) => selectRecord(id)} onClusterAtPoint={(ids) => { setClusterIds(ids); setSelectedId(null); setLocation(null); }}
          onMapClick={onMapClick} onDrawPoint={onDrawPoint} onDrawArea={onDrawArea} onHover={setHover} onCamera={setCam} onCursor={setCursor} onStatus={setGstatus} onFatal={setFatal}
        />
      )}

      <header className="topbar">
        <div className="brand" title="Team Vancomycin, NASA Space Apps Challenge 2026">{APP_NAME}</div>
        <nav aria-label="Modes">
          <button className={mode === "explore" ? "on" : ""} onClick={() => setMode("explore")}>Explore Earth</button>
          <button className={mode === "find" ? "on" : ""} onClick={() => setMode(mode === "find" ? "explore" : "find")}>Find analogs{nFilters ? <span className="dot" aria-label={`${nFilters} filters active`} /> : null}</button>
          <button className={mode === "profiles" ? "on" : ""} onClick={() => setMode(mode === "profiles" ? "explore" : "profiles")}>Base profiles</button>
          <button className={mode === "area" ? "on" : ""} onClick={() => setMode(mode === "area" ? "explore" : "area")}>Search area{filters.area ? <span className="dot" /> : null}</button>
          <Link href="/methods/" className="navlink">Data &amp; methods</Link>
        </nav>
        <SearchBox atlas={atlas} onRecord={(id) => selectRecord(id)} onLocation={goToLocation} onReference={(id) => setWorkspace({ type: "reference", id })} />
      </header>

      {railOpen && (
        <aside className="rail" aria-label={mode === "find" ? "Find analogs" : mode === "profiles" ? "Base profiles" : "Search area"}>
          <div className="phead"><span>{mode === "find" ? "Find analogs" : mode === "profiles" ? "Base profiles" : "Search area"}</span><button className="close" aria-label="Close panel" onClick={() => { setMode("explore"); setDrawMode(null); }}>×</button></div>
          <div className="pbody">
          {mode === "find" && <FindPanel atlas={atlas} filters={filters} setFilters={setFilters} result={result} selectedId={selectedId} location={location} onSelect={(id) => selectRecord(id)} onReference={(id) => setWorkspace({ type: "reference", id })} onArea={() => setMode("area")} />}
          {mode === "profiles" && <ProfilesPanel atlas={atlas} profileId={profileId} setProfileId={setProfileId} onReference={(id) => setWorkspace({ type: "reference", id })} onShow={(refs, kinds) => { setFilters((f) => ({ ...f, body: "all", refs, kinds: { terrain: kinds.includes("terrain"), rock: kinds.includes("rock"), geo2: kinds.includes("geo2") }, insideYardstick: false, tiers: [] })); setMode("find"); }} />}
          {mode === "area" && <AreaPanel atlas={atlas} filters={filters} setFilters={setFilters} result={result} drawMode={drawMode} setDrawMode={setDrawMode} location={location} onShowList={() => setMode("find")} onFit={(a) => { if (a.type === "circle") { const d = a.radiusKm / 111; globe.current?.flyToBox(a.lon - d / Math.cos(a.lat * Math.PI / 180), a.lat - d, a.lon + d / Math.cos(a.lat * Math.PI / 180), a.lat + d); } else if (a.type === "rect") globe.current?.flyToBox(a.west, a.south, a.east, a.north); else { const xs = a.ring.map((p) => p[0]), ys = a.ring.map((p) => p[1]); globe.current?.flyToBox(Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)); } }} />}
          </div>
        </aside>
      )}

      {sideOpen && (
        <aside className="side" aria-label="Details">
          <div className="phead"><span>{selected ? "Record" : clusterIds ? "Records at this place" : "Location"}</span><button className="close" aria-label="Close details" onClick={() => { setSelectedId(null); setLocation(null); setClusterIds(null); }}>×</button></div>
          <div className="pbody">
          {selected && <Inspector atlas={atlas} rec={selected} onData={(tab) => setWorkspace({ type: "record", id: selected.id, tab: tab ?? "comparison" })} onReference={(id) => setWorkspace({ type: "reference", id })} onFly={() => globe.current?.flyToRecord(selected)} />}
          {!selected && clusterIds && <ClusterList atlas={atlas} ids={clusterIds} onSelect={(id) => selectRecord(id, false)} />}
          {!selected && !clusterIds && location && <LocationCard atlas={atlas} loc={location} onSelect={(id) => selectRecord(id)} onUseAsCentre={() => { setFilters((f) => ({ ...f, area: { type: "circle", lat: +location.lat.toFixed(4), lon: +location.lon.toFixed(4), radiusKm: f.area?.type === "circle" ? f.area.radiusKm : 150 } })); setMode("area"); }} onFly={() => globe.current?.flyToPoint(location.lat, location.lon, 60_000)} />}
          </div>
        </aside>
      )}

      {drawMode && (
        <div className="drawhint" role="status">
          {drawMode === "point" ? "Click the map to set the centre." : drawMode === "rect" ? "Click two opposite corners of the rectangle." : "Click to add corners. Double-click or press Enter to finish."}
          <button onClick={() => setDrawMode(null)}>Cancel</button>
        </div>
      )}

      {!fatal && (
        <div className="mapctl" aria-label="Map controls">
          <button className="compass" title="Reset to north-up" aria-label="Reset to north-up" onClick={() => globe.current?.resetNorth()}>
            <svg viewBox="0 0 32 32" width="26" height="26" style={{ transform: `rotate(${-(cam?.heading ?? 0)}deg)` }} aria-hidden="true"><path d="M16 4 L21 16 L16 14 L11 16 Z" fill="#E4573D" /><path d="M16 28 L21 16 L16 18 L11 16 Z" fill="#F3F5F4" /></svg>
          </button>
          <button title="Tilt between top-down and oblique view (or drag with Shift held)" aria-label="Toggle tilt" onClick={() => globe.current?.toggleTilt()}>{cam && cam.pitch > -80 ? "2D" : "3D"}</button>
          <button title="Zoom in" aria-label="Zoom in" onClick={() => globe.current?.zoom(0.5)}>+</button>
          <button title="Zoom out" aria-label="Zoom out" onClick={() => globe.current?.zoom(2)}>−</button>
          <button title="Whole Earth" aria-label="Whole Earth view" onClick={() => globe.current?.flyHome()}>
            <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" strokeWidth="1.6" /><path d="M3.5 12h17M12 3.5c3 3 3 14 0 17M12 3.5c-3 3-3 14 0 17" fill="none" stroke="currentColor" strokeWidth="1.3" /></svg>
          </button>
          <button className={layersOpen ? "on" : ""} title="Map layers" aria-label="Map layers" aria-expanded={layersOpen} onClick={() => setLayersOpen((v) => !v)}>
            <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path d="M12 4 3 9l9 5 9-5-9-5Zm-9 9 9 5 9-5M3 17l9 5 9-5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" /></svg>
          </button>
        </div>
      )}
      {layersOpen && (
        <div className="layers" role="dialog" aria-label="Map layers">
          <h3>Base map</h3>
          <label><input type="radio" name="img" checked={layers.imagery === "satellite"} onChange={() => setLayers((l) => ({ ...l, imagery: "satellite" }))} /> Satellite imagery <span className="muted">Esri World Imagery</span></label>
          <label><input type="radio" name="img" checked={layers.imagery === "bluemarble"} onChange={() => setLayers((l) => ({ ...l, imagery: "bluemarble" }))} /> Blue Marble <span className="muted">NASA GIBS, 500 m</span></label>
          <label><input type="checkbox" checked={layers.labels} onChange={(e) => setLayers((l) => ({ ...l, labels: e.target.checked }))} /> Borders and place names</label>
          <label><input type="checkbox" checked={layers.relief} onChange={(e) => setLayers((l) => ({ ...l, relief: e.target.checked }))} /> 3D relief {gstatus?.relief === "unavailable" ? <span className="warn">unavailable</span> : null}</label>
          <h3>Results</h3>
          <label><input type="checkbox" checked={layers.footprints} onChange={(e) => setLayers((l) => ({ ...l, footprints: e.target.checked }))} /> Record footprints when zoomed in</label>
          <label><input type="checkbox" checked={layers.coverage} onChange={(e) => setLayers((l) => ({ ...l, coverage: e.target.checked }))} /> Analysis coverage</label>
          {layers.coverage && <CoverageLegend atlas={atlas} />}
          <h3>Symbols</h3>
          <ul className="legend">
            <li><i className="sym circle moon" /> Terrain window, Moon reference</li>
            <li><i className="sym circle mars" /> Terrain window, Mars reference</li>
            <li><i className="sym square mars" /> Rock-type screening box (GLiM)</li>
            <li><i className="sym diamond mars" /> Mapped geologic unit (geo-2.0), representative point</li>
            <li><i className="sym cluster" /> Several records; the ring shows the Moon/Mars split</li>
          </ul>
          {gstatus?.imageryNote ? <p className="warn">{gstatus.imageryNote}</p> : null}
        </div>
      )}

      <footer className="statusbar">
        <button className="runchip" onClick={() => { setLayers((l) => ({ ...l, coverage: !l.coverage })); setLayersOpen(true); }} title={`Run statement: ${run?.manifest_describe_as ?? "missing"}. Click to show which 1-degree tiles the terrain run processed.`}>
          <strong>{result.records.length === atlas.counts.total ? `${atlas.counts.total} loaded records` : `${result.records.length} of ${atlas.counts.total} records shown`}</strong>
          <span> · {runText}</span>
        </button>
        <div className="spacer" />
        {cursor && <span className="coords">{formatLatLon(cursor.lat, cursor.lon, 3)}</span>}
        {cam && <span className="alt">eye {cam.height >= 10_000 ? `${Math.round(cam.height / 1000).toLocaleString("en-US")} km` : `${Math.round(cam.height).toLocaleString("en-US")} m`}</span>}
        {scale && cam?.metersPerPixel ? (<span className="scalebar" aria-label={`Scale bar: ${scale.label}`}><i style={{ width: `${scale.meters / cam.metersPerPixel}px` }} />{scale.label}</span>) : null}
      </footer>

      {hover && !drawMode && <HoverTip atlas={atlas} hover={hover} />}
      {workspace && <Workspace atlas={atlas} state={workspace} setState={setWorkspace} onShowOnMap={(id) => { setWorkspace(null); selectRecord(id); }} onReference={(id) => setWorkspace({ type: "reference", id })} onShowRecords={(refId) => { setWorkspace(null); setFilters((f) => ({ ...f, body: "all", refs: [refId], kinds: { terrain: true, rock: true, geo2: true }, insideYardstick: false, tiers: [] })); setMode("find"); }} />}
    </div>
  );
}

function CoverageLegend({ atlas }: { atlas: Atlas }) {
  const t = atlas.bundle.run?.tiles ?? {};
  const missing = Object.entries(t).filter(([k]) => /missing|failed/i.test(k)).reduce((a, [, v]) => a + v, 0);
  return (
    <div className="covlegend">
      <ul className="legend">
        <li><i className="cov c1" /> Processed, has eligible windows <span className="muted">{t.windows ?? "?"} tiles</span></li>
        <li><i className="cov c2" /> Processed, no window passed the validity test <span className="muted">{t.no_valid_windows ?? "?"}</span></li>
        <li><i className="cov c3" /> Skipped: land cover rules out every window <span className="muted">{t.skipped_landcover ?? "?"}</span></li>
        <li><i className="cov c0" /> Everywhere else: no result in this run{missing ? <span className="muted">{missing} listed tiles failed or were not run</span> : null}</li>
        <li><i className="cov ring" /> Dashed circles: regional geology study areas</li>
      </ul>
      <p className="muted">Run statement: {atlas.bundle.run?.manifest_describe_as ?? "coverage statement missing"}. Uncoloured land and ocean have no terrain result. Rock-type screening used a global lithology map and is not limited to these tiles.</p>
    </div>
  );
}

function HoverTip({ atlas, hover }: { atlas: Atlas; hover: HoverInfo }) {
  const recs = hover.ids.map((i) => atlas.byId.get(i)).filter(Boolean) as AtlasRecord[];
  if (!recs.length) return null;
  let body: React.ReactNode;
  if (recs.length === 1) {
    const r = recs[0];
    body = (<><strong>{r.title}</strong><span>{r.pathwayLabel} · {r.referenceId} ({r.body})</span></>);
  } else {
    const k = { terrain: 0, rock: 0, geo2: 0 };
    for (const r of recs) k[r.kind]++;
    const parts = [k.terrain ? `${k.terrain} terrain` : "", k.rock ? `${k.rock} rock-type` : "", k.geo2 ? `${k.geo2} mapped units` : ""].filter(Boolean).join(" · ");
    body = (<><strong>{recs.length} records</strong><span>{parts}</span><span className="muted">Click to zoom in</span></>);
  }
  return <div className="tip" style={{ left: hover.x + 14, top: hover.y + 14 }} role="tooltip">{body}</div>;
}

function SearchBox({ atlas, onRecord, onLocation, onReference }: { atlas: Atlas; onRecord(id: string): void; onLocation(lat: number, lon: number, label?: string, box?: [number, number, number, number] | null): void; onReference(id: string): void }) {
  const [q, setQ] = useState("");
  const [open, setOpen] = useState(false);
  const [places, setPlaces] = useState<Place[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const box = useRef<HTMLDivElement>(null);
  const coords = parseCoordinates(q);
  const text = q.trim().toLowerCase();
  const local = useMemo(() => {
    if (text.length < 2 || coords) return { recs: [] as AtlasRecord[], refs: [] as { id: string; label: string }[] };
    const recs = atlas.records.filter((r) => r.id.toLowerCase().includes(text) || r.title.toLowerCase().includes(text) || r.subtitle.toLowerCase().includes(text)).slice(0, 6);
    const refs = [...[...atlas.terrainRefs.values()].map((r) => ({ id: r.id, label: r.description ?? r.id })), ...[...atlas.geoRefs.values()].map((r) => ({ id: r.id, label: r.name }))].filter((r) => r.id.toLowerCase().includes(text) || r.label.toLowerCase().includes(text)).slice(0, 4);
    return { recs, refs };
  }, [atlas, text, coords]);

  useEffect(() => {
    const f = (e: MouseEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener("mousedown", f);
    return () => document.removeEventListener("mousedown", f);
  }, []);

  const searchPlace = async () => {
    setBusy(true); setErr(null); setPlaces(null);
    try {
      const res = await fetch(`https://nominatim.openstreetmap.org/search?format=jsonv2&limit=5&q=${encodeURIComponent(q.trim())}`, { headers: { Accept: "application/json" } });
      if (!res.ok) throw new Error(String(res.status));
      const js = (await res.json()) as { display_name: string; lat: string; lon: string; boundingbox?: string[] }[];
      setPlaces(js.map((p) => ({ name: p.display_name, lat: parseFloat(p.lat), lon: parseFloat(p.lon), box: p.boundingbox && p.boundingbox.length === 4 ? [parseFloat(p.boundingbox[2]), parseFloat(p.boundingbox[0]), parseFloat(p.boundingbox[3]), parseFloat(p.boundingbox[1])] : null })));
    } catch {
      setErr("Place-name search could not be reached. Coordinates such as 40.33, -74.60 still work.");
    } finally {
      setBusy(false);
    }
  };
  const submit = () => {
    if (coords) { onLocation(coords.lat, coords.lon); setOpen(false); return; }
    if (text.length >= 2) searchPlace();
  };

  return (
    <div className="search" ref={box}>
      <input
        type="search" value={q} placeholder="Search a place, coordinates or record ID" aria-label="Search a place, coordinates or record ID"
        onChange={(e) => { setQ(e.target.value); setOpen(true); setPlaces(null); setErr(null); }} onFocus={() => setOpen(true)}
        onKeyDown={(e) => { if (e.key === "Enter") submit(); if (e.key === "Escape") setOpen(false); }}
      />
      {open && q.trim().length >= 2 && (
        <div className="results" role="listbox">
          {coords && <button role="option" aria-selected="false" onClick={() => { onLocation(coords.lat, coords.lon); setOpen(false); }}><strong>Go to {formatLatLon(coords.lat, coords.lon)}</strong><span>Coordinate. Navigation only; no analysis is run.</span></button>}
          {local.refs.map((r) => (<button key={r.id} role="option" aria-selected="false" onClick={() => { onReference(r.id); setOpen(false); }}><strong>{r.id}</strong><span>Planetary reference · {r.label}</span></button>))}
          {local.recs.map((r) => (<button key={r.id} role="option" aria-selected="false" onClick={() => { onRecord(r.id); setOpen(false); }}><strong>{r.title}</strong><span>{r.pathwayLabel} · {r.subtitle}</span></button>))}
          {!coords && (<button className="place" onClick={searchPlace} disabled={busy}><strong>{busy ? "Searching places…" : `Search places for "${q.trim()}"`}</strong><span>OpenStreetMap Nominatim · press Enter</span></button>)}
          {places && places.length === 0 && <p className="muted">No place found with that name.</p>}
          {places?.map((p) => (<button key={`${p.lat},${p.lon}`} role="option" aria-selected="false" onClick={() => { onLocation(p.lat, p.lon, p.name, p.box); setOpen(false); }}><strong>{p.name}</strong><span>{formatLatLon(p.lat, p.lon, 3)} · place</span></button>))}
          {err && <p className="warn">{err}</p>}
        </div>
      )}
    </div>
  );
}
