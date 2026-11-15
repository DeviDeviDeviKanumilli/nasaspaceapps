"use client";
// Full-window research workspace: "Data for this site" and planetary reference detail. Opened on request only.
import { useEffect, useRef } from "react";
import type { Atlas, Candidate, GeoUnit } from "@/lib/types";
import { formatLatLon } from "@/lib/geo";
import { exportCsv, exportJson, exportObject } from "@/lib/export";
import { ComparisonTable, GeoMeasurements, IdentityTable, Limits, ReferenceDetail, RockMeasurements, SourcesTable, TerrainMeasurements, WhyIdentified } from "./RecordViews";
import Link from "next/link";

export type WorkspaceState = { type: "record"; id: string; tab: string } | { type: "reference"; id: string };

const TABS: [string, string][] = [["comparison", "Comparison"], ["measurements", "Earth measurements"], ["why", "Why found"], ["sources", "Dataset sources"], ["record", "Record"], ["limits", "Limits"]];

export default function Workspace({ atlas, state, setState, onShowOnMap, onReference, onShowRecords }: {
  atlas: Atlas; state: WorkspaceState; setState(s: WorkspaceState | null): void; onShowOnMap(id: string): void; onReference(id: string): void; onShowRecords(refId: string): void;
}) {
  const closeRef = useRef<HTMLButtonElement>(null);
  useEffect(() => { closeRef.current?.focus(); }, [state.type, state.id]);

  if (state.type === "reference") {
    const t = atlas.terrainRefs.get(state.id);
    const g = atlas.geoRefs.get(state.id);
    const n = atlas.records.filter((r) => r.referenceId === state.id).length;
    return (
      <div className="workspace" role="dialog" aria-modal="true" aria-label={`Planetary reference ${state.id}`}>
        <header>
          <button ref={closeRef} className="backbtn" onClick={() => setState(null)}>← Back to map</button>
          <div className="wtitle"><span className={`grouplab ${(t?.body ?? "Mars").toLowerCase()}`}>{t?.body ?? (g ? "Mars" : "")} · planetary reference</span><h1>{state.id}{t?.description ? ` — ${t.description}` : ""}</h1></div>
          <div className="wactions"><button className="primary" disabled={n === 0} onClick={() => onShowRecords(state.id)}>Show {n} Earth records</button></div>
        </header>
        <div className="wbody single">
          <p className="muted">A reference is a measured comparator region on the Moon or Mars. It is not a selected landing or base site.</p>
          <ReferenceDetail atlas={atlas} id={state.id} />
        </div>
      </div>
    );
  }

  const rec = atlas.byId.get(state.id);
  if (!rec) return null;
  const tab = state.tab;
  const bodyName = rec.body === "Moon" ? "Moon" : "Mars";
  const json = JSON.stringify(exportObject(atlas, rec), null, 2);
  return (
    <div className="workspace" role="dialog" aria-modal="true" aria-label={`Data for ${rec.title}`}>
      <header>
        <button ref={closeRef} className="backbtn" onClick={() => setState(null)}>← Back to map</button>
        <div className="wtitle"><span className={`grouplab ${rec.body.toLowerCase()}`}>{rec.pathwayLabel} · data for this site</span><h1>{rec.title}</h1><p className="sub">{formatLatLon(rec.lat, rec.lon)} · compared with <button className="link" onClick={() => onReference(rec.referenceId)}>{rec.referenceId}</button> ({bodyName})</p></div>
        <div className="wactions">
          <button onClick={() => onShowOnMap(rec.id)}>Show on map</button>
          <button onClick={() => exportJson(atlas, rec)}>Export JSON</button>
          <button onClick={() => exportCsv(rec)}>Export CSV</button>
        </div>
      </header>
      <nav className="tabs" role="tablist">
        {TABS.map(([k, label]) => (<button key={k} role="tab" aria-selected={tab === k} className={tab === k ? "on" : ""} onClick={() => setState({ ...state, tab: k })}>{k === "comparison" ? `Earth ↔ ${bodyName}` : label}</button>))}
      </nav>
      <div className="wbody">
        <aside className="wid"><h3>Identity</h3><IdentityTable atlas={atlas} rec={rec} /></aside>
        <section className="wmain" role="tabpanel">
          {tab === "comparison" && (
            rec.kind === "terrain" ? (
              <>
                <h2>Slope at each baseline: this Earth window against {rec.referenceId}</h2>
                <TerrainMeasurements rec={rec} part="comparison" />
                <p className="muted">Earth and {bodyName} slopes are computed the same way (plane fit over the baseline on a {rec.body === "Moon" ? "100 m" : "200 m"} grid), so they can be compared at the same baseline. Sensor-scale roughness from a field camera cannot be compared with these values.</p>
                <h3>Cannot be compared</h3>
                <ul>{((rec.raw as Candidate).evidence?.not_comparable ?? []).map((x) => <li key={x}>{x}</li>)}</ul>
              </>
            ) : rec.kind === "rock" ? (
              <>
                <h2>Rock-type screening against {rec.referenceId}</h2>
                <WhyIdentified atlas={atlas} rec={rec} />
                <p className="muted">This is a process analogy from a small-scale lithology map, not a quantitative comparison with {bodyName} rocks.</p>
                <h3>Cannot be compared</h3>
                <ul>{((rec.raw as Candidate).evidence?.not_comparable ?? []).map((x) => <li key={x}>{x}</li>)}</ul>
              </>
            ) : (
              <>
                <h2>Property by property: Mars observations against this unit's map record</h2>
                <ComparisonTable atlas={atlas} rows={(rec.raw as GeoUnit).comparison ?? []} />
                <p className="muted">"Observed" is a rover or orbiter measurement; "interpreted" is a published interpretation; "inferred" is a consequence that was not measured. The Earth column quotes the state geologic map. There is no match score.</p>
                <h3>Cannot be compared</h3>
                <ul>{((rec.raw as GeoUnit).not_comparable ?? []).map((x) => <li key={x}>{x}</li>)}</ul>
              </>
            )
          )}
          {tab === "measurements" && (
            <>
              <h2>Earth-side values in this record</h2>
              {rec.kind === "terrain" && <TerrainMeasurements rec={rec} part="earth" />}
              {rec.kind === "rock" && <RockMeasurements rec={rec} />}
              {rec.kind === "geo2" && <GeoMeasurements atlas={atlas} rec={rec} />}
            </>
          )}
          {tab === "why" && (<><h2>Why this record was nominated</h2><WhyIdentified atlas={atlas} rec={rec} /></>)}
          {tab === "sources" && (
            <>
              <h2>Where each value comes from</h2>
              <SourcesTable rec={rec} />
              <p><Link href="/methods/">Full dataset catalogue, licences and methods →</Link></p>
            </>
          )}
          {tab === "record" && (
            <>
              <h2>Stored record</h2>
              <p className="muted">The record exactly as stored in the results bundle, with the map outline derived for display and the run lineage. This is a computed summary. Raw source pixels and map polygons are not included in this record.</p>
              <div className="btnrow"><button onClick={() => exportJson(atlas, rec)}>Export JSON</button><button onClick={() => exportCsv(rec)}>Export CSV</button><button onClick={() => navigator.clipboard?.writeText(json)}>Copy</button></div>
              <pre className="json" tabIndex={0}>{json}</pre>
            </>
          )}
          {tab === "limits" && (<><h2>Limits</h2><Limits atlas={atlas} rec={rec} /></>)}
        </section>
      </div>
    </div>
  );
}
