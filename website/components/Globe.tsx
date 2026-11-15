"use client";
// CesiumJS globe: imagery + terrain streaming, clustered records, exact footprints, coverage layer, area drawing.
// Cesium is loaded as a prebuilt script from /cesium (copied from node_modules at build time); types come from the package.
import { forwardRef, useEffect, useImperativeHandle, useRef } from "react";
import type * as CesiumNS from "cesium";
import type { Atlas, AtlasRecord } from "@/lib/types";
import { BASE_PATH } from "@/lib/config";

export type Area =
  | { type: "circle"; lat: number; lon: number; radiusKm: number }
  | { type: "rect"; west: number; south: number; east: number; north: number }
  | { type: "polygon"; ring: [number, number][] };

export type DrawMode = null | "point" | "rect" | "polygon";

export interface Layers {
  imagery: "satellite" | "bluemarble";
  labels: boolean;
  coverage: boolean;
  footprints: boolean;
  relief: boolean;
}

export interface CameraInfo {
  heading: number;
  pitch: number;
  height: number;
  metersPerPixel: number | null;
}

export interface GlobeStatus {
  imagery: "satellite" | "bluemarble" | "offline" | "loading";
  /** what is being drawn, for the layers panel */
  stack: string;
  imageryNote: string | null;
  relief: "on" | "off" | "unavailable" | "loading";
}

export interface HoverInfo {
  x: number;
  y: number;
  ids: string[];
}

export interface GlobeHandle {
  flyToRecord(rec: AtlasRecord): void;
  flyToPoint(lat: number, lon: number, rangeM?: number): void;
  flyToBox(west: number, south: number, east: number, north: number): void;
  flyHome(): void;
  zoom(factor: number): void;
  resetNorth(): void;
  toggleTilt(): void;
}

interface Props {
  atlas: Atlas;
  visibleIds: Set<string>;
  selected: AtlasRecord | null;
  location: { lat: number; lon: number } | null;
  area: Area | null;
  drawMode: DrawMode;
  layers: Layers;
  reducedMotion: boolean;
  onSelect(id: string): void;
  onClusterAtPoint(ids: string[]): void;
  onMapClick(lat: number, lon: number): void;
  onDrawPoint(lat: number, lon: number): void;
  onDrawArea(area: Area): void;
  onHover(h: HoverInfo | null): void;
  onCamera(c: CameraInfo): void;
  onCursor(c: { lat: number; lon: number } | null): void;
  onStatus(s: GlobeStatus): void;
  onFatal(message: string): void;
}

const MOON = "#567C94";
const MARS = "#B66F54";
const MOON_LINE = "#A9C4D6"; // lighter tints for thin lines over imagery
const MARS_LINE = "#E3A88F";
const GIBS_GEO = "https://gibs.earthdata.nasa.gov/wmts/epsg4326/best/BlueMarble_ShadedRelief_Bathymetry/default/2004-08/500m/{gz}/{y}/{x}.jpeg";
const ESRI_IMAGERY = "https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}";
const ESRI_LABELS = "https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}";
const ESRI_TERRAIN = "https://elevation3d.arcgis.com/arcgis/rest/services/WorldElevation3D/Terrain3D/ImageServer";

let cesiumPromise: Promise<typeof CesiumNS> | null = null;
function loadCesium(): Promise<typeof CesiumNS> {
  if (cesiumPromise) return cesiumPromise;
  cesiumPromise = new Promise((resolve, reject) => {
    const w = window as unknown as { Cesium?: typeof CesiumNS; CESIUM_BASE_URL?: string };
    if (w.Cesium) return resolve(w.Cesium);
    w.CESIUM_BASE_URL = `${BASE_PATH}/cesium/`;
    const css = document.createElement("link");
    css.rel = "stylesheet";
    css.href = `${BASE_PATH}/cesium/Widgets/widgets.css`;
    document.head.appendChild(css);
    const s = document.createElement("script");
    s.src = `${BASE_PATH}/cesium/Cesium.js`;
    s.async = true;
    s.onload = () => (w.Cesium ? resolve(w.Cesium) : reject(new Error("The 3D engine loaded but did not initialise.")));
    s.onerror = () => reject(new Error("The 3D engine script could not be loaded."));
    document.head.appendChild(s);
  });
  return cesiumPromise;
}

function probeImage(url: string, ms = 7000): Promise<boolean> {
  return new Promise((resolve) => {
    const img = new Image();
    const t = setTimeout(() => { img.src = ""; resolve(false); }, ms);
    img.crossOrigin = "anonymous";
    img.onload = () => { clearTimeout(t); resolve(true); };
    img.onerror = () => { clearTimeout(t); resolve(false); };
    img.src = url;
  });
}

// ---- marker artwork (drawn once per style, cached) ----
const iconCache = new Map<string, HTMLCanvasElement>();
function markerIcon(kind: AtlasRecord["kind"], body: string): HTMLCanvasElement {
  const key = `${kind}-${body}`;
  const hit = iconCache.get(key);
  if (hit) return hit;
  const s = 40; // 2x canvas for a 20 px sprite
  const c = document.createElement("canvas");
  c.width = c.height = s;
  const g = c.getContext("2d")!;
  const m = s / 2;
  const shape = (r: number) => {
    g.beginPath();
    if (kind === "terrain") g.arc(m, m, r, 0, Math.PI * 2);
    else if (kind === "rock") g.rect(m - r * 0.9, m - r * 0.9, r * 1.8, r * 1.8);
    else { const d = r * 1.25; g.moveTo(m, m - d); g.lineTo(m + d, m); g.lineTo(m, m + d); g.lineTo(m - d, m); g.closePath(); }
  };
  shape(11.5); g.fillStyle = "rgba(5,9,11,0.55)"; g.fill();      // hairline dark edge
  shape(10); g.fillStyle = "#FFFFFF"; g.fill();                    // 1.5 px light outline
  shape(7); g.fillStyle = body === "Moon" ? MOON : MARS; g.fill(); // 9-10 px centre
  iconCache.set(key, c);
  return c;
}
function clusterIcon(n: number, moonShare: number): HTMLCanvasElement {
  const bucket = Math.round(moonShare * 8);
  const key = `c-${n}-${bucket}`;
  const hit = iconCache.get(key);
  if (hit) return hit;
  const d = n < 10 ? 26 : n < 100 ? 28 : 30; // on-screen diameter in px
  const s = (d + 4) * 2;
  const c = document.createElement("canvas");
  c.width = c.height = s;
  const g = c.getContext("2d")!;
  const cx = s / 2, r = d - 2;
  g.beginPath(); g.arc(cx, cx, r, 0, Math.PI * 2); g.fillStyle = "rgba(17,27,32,0.92)"; g.fill();
  const a0 = -Math.PI / 2;
  const a1 = a0 + Math.PI * 2 * (bucket / 8);
  g.lineWidth = 3; // 1.5 px rim on screen, split by the Moon/Mars share of the records inside
  if (bucket > 0) { g.beginPath(); g.arc(cx, cx, r, a0, a1); g.strokeStyle = MOON_LINE; g.stroke(); }
  if (bucket < 8) { g.beginPath(); g.arc(cx, cx, r, a1, a0 + Math.PI * 2); g.strokeStyle = MARS_LINE; g.stroke(); }
  g.fillStyle = "#F5F7F7";
  g.font = `600 ${n < 100 ? 22 : 20}px ui-monospace, "SF Mono", Menlo, Consolas, monospace`;
  g.textAlign = "center"; g.textBaseline = "middle";
  g.fillText(String(n), cx, cx + 1);
  iconCache.set(key, c);
  return c;
}
function ringIcon(): HTMLCanvasElement {
  const hit = iconCache.get("ring");
  if (hit) return hit;
  const s = 56;
  const c = document.createElement("canvas");
  c.width = c.height = s;
  const g = c.getContext("2d")!;
  g.beginPath(); g.arc(s / 2, s / 2, 20, 0, Math.PI * 2); g.lineWidth = 7; g.strokeStyle = "rgba(5,9,11,0.6)"; g.stroke();
  g.beginPath(); g.arc(s / 2, s / 2, 20, 0, Math.PI * 2); g.lineWidth = 3.5; g.strokeStyle = "#F7F8F5"; g.stroke();
  iconCache.set("ring", c);
  return c;
}
function pinIcon(): HTMLCanvasElement {
  const hit = iconCache.get("pin");
  if (hit) return hit;
  const s = 56;
  const c = document.createElement("canvas");
  c.width = c.height = s;
  const g = c.getContext("2d")!;
  const m = s / 2;
  for (const [w, col] of [[7, "rgba(5,9,11,0.7)"], [3, "#F7F8F5"]] as [number, string][]) {
    g.lineWidth = w; g.strokeStyle = col;
    g.beginPath(); g.moveTo(m, 6); g.lineTo(m, m - 8); g.moveTo(m, m + 8); g.lineTo(m, s - 6); g.moveTo(6, m); g.lineTo(m - 8, m); g.moveTo(m + 8, m); g.lineTo(s - 6, m); g.stroke();
  }
  g.fillStyle = "#F7F8F5"; g.beginPath(); g.arc(m, m, 2.6, 0, Math.PI * 2); g.fill();
  iconCache.set("pin", c);
  return c;
}
function smallSquare(): HTMLCanvasElement {
  const hit = iconCache.get("sq");
  if (hit) return hit;
  const c = document.createElement("canvas");
  c.width = c.height = 24;
  const g = c.getContext("2d")!;
  g.fillStyle = "rgba(5,9,11,0.6)"; g.fillRect(4, 4, 16, 16);
  g.fillStyle = "#F7F8F5"; g.fillRect(6, 6, 12, 12);
  iconCache.set("sq", c);
  return c;
}

function circleRing(lat: number, lon: number, radiusKm: number, n = 120): [number, number][] {
  const R = 6371.0088;
  const d = radiusKm / R;
  const la1 = (lat * Math.PI) / 180;
  const lo1 = (lon * Math.PI) / 180;
  const out: [number, number][] = [];
  for (let i = 0; i <= n; i++) {
    const b = (i / n) * 2 * Math.PI;
    const la2 = Math.asin(Math.sin(la1) * Math.cos(d) + Math.cos(la1) * Math.sin(d) * Math.cos(b));
    const lo2 = lo1 + Math.atan2(Math.sin(b) * Math.sin(d) * Math.cos(la1), Math.cos(d) - Math.sin(la1) * Math.sin(la2));
    out.push([(((lo2 * 180) / Math.PI + 540) % 360) - 180, (la2 * 180) / Math.PI]);
  }
  return out;
}
export function areaRing(a: Area): [number, number][] {
  if (a.type === "circle") return circleRing(a.lat, a.lon, a.radiusKm);
  if (a.type === "rect") {
    const out: [number, number][] = [];
    const n = 24;
    for (let i = 0; i <= n; i++) out.push([a.west + ((a.east - a.west) * i) / n, a.south]);
    for (let i = 0; i <= n; i++) out.push([a.east, a.south + ((a.north - a.south) * i) / n]);
    for (let i = 0; i <= n; i++) out.push([a.east - ((a.east - a.west) * i) / n, a.north]);
    for (let i = 0; i <= n; i++) out.push([a.west, a.north - ((a.north - a.south) * i) / n]);
    return out;
  }
  return [...a.ring, a.ring[0]];
}

const HOME = { lon: -78, lat: 12, height: 17_000_000 };

const Globe = forwardRef<GlobeHandle, Props>(function Globe(props, ref) {
  const el = useRef<HTMLDivElement>(null);
  const creditEl = useRef<HTMLDivElement>(null);
  const P = useRef(props);
  P.current = props;
  const S = useRef<{
    C: typeof CesiumNS;
    viewer: CesiumNS.Viewer;
    recordsDS: CesiumNS.CustomDataSource;
    footDS: CesiumNS.CustomDataSource;
    overlayDS: CesiumNS.CustomDataSource;
    entities: Map<string, CesiumNS.Entity>;
    foot: Map<string, CesiumNS.Entity>;
    base?: CesiumNS.ImageryLayer;
    underlay?: CesiumNS.ImageryLayer;
    offline?: boolean;
    labels?: CesiumNS.ImageryLayer;
    coverage?: CesiumNS.ImageryLayer;
    terrain?: CesiumNS.TerrainProvider;
    ellipsoidTerrain: CesiumNS.TerrainProvider;
    status: GlobeStatus;
    draw: { pts: [number, number][]; cursor: [number, number] | null };
    available: { satellite: boolean; bluemarble: boolean };
  } | null>(null);

  // ---------- initialise once ----------
  useEffect(() => {
    let destroyed = false;
    let cleanup: (() => void) | null = null;
    (async () => {
      let C: typeof CesiumNS;
      try {
        C = await loadCesium();
      } catch (e) {
        P.current.onFatal((e as Error).message);
        return;
      }
      if (destroyed || !el.current) return;
      let viewer: CesiumNS.Viewer;
      try {
        viewer = new C.Viewer(el.current, {
          baseLayer: false as unknown as CesiumNS.ImageryLayer,
          baseLayerPicker: false, geocoder: false, homeButton: false, sceneModePicker: false, navigationHelpButton: false,
          animation: false, timeline: false, fullscreenButton: false, infoBox: false, selectionIndicator: false,
          requestRenderMode: true, maximumRenderTimeChange: Infinity,
          creditContainer: creditEl.current ?? undefined,
          msaaSamples: 4,
        });
        viewer.scene.globe.maximumScreenSpaceError = 1.6;
      } catch (e) {
        P.current.onFatal("This browser could not start WebGL, which the 3D globe needs. The record list, measurements and sources remain available.");
        return;
      }
      const scene = viewer.scene;
      // Software or very weak GPUs: trade sharpness for responsiveness instead of freezing.
      try {
        const gl = (scene.canvas.getContext("webgl2") || scene.canvas.getContext("webgl")) as WebGLRenderingContext | null;
        const ext = gl?.getExtension("WEBGL_debug_renderer_info");
        const renderer = ext && gl ? String(gl.getParameter(ext.UNMASKED_RENDERER_WEBGL)) : "";
        if (/swiftshader|llvmpipe|software/i.test(renderer)) {
          scene.msaaSamples = 1;
          scene.globe.maximumScreenSpaceError = 3;
        } else {
          // Real GPUs: render at the display's native pixel density (capped at 2x) so imagery and markers are sharp.
          viewer.useBrowserRecommendedResolution = false;
          viewer.resolutionScale = Math.min(window.devicePixelRatio || 1, 2) / (window.devicePixelRatio || 1);
        }
      } catch { /* keep defaults */ }
      scene.backgroundColor = C.Color.fromCssColorString("#05090B");
      scene.globe.baseColor = C.Color.fromCssColorString("#0d1b29");
      scene.globe.enableLighting = false;
      scene.globe.showGroundAtmosphere = true;
      scene.globe.depthTestAgainstTerrain = true;
      scene.globe.tileCacheSize = 400; // keep ancestor tiles so imagery does not drop back to coarse levels while panning
      if (scene.sun) scene.sun.show = false;
      if (scene.moon) scene.moon.show = false;
      if (scene.skyAtmosphere) scene.skyAtmosphere.show = true;
      if (scene.skyBox) scene.skyBox.show = false; // plain near-black space; the imagery sets the tone
      scene.fog.enabled = true;
      scene.highDynamicRange = false;
      const ctrl = scene.screenSpaceCameraController;
      ctrl.minimumZoomDistance = 120;
      ctrl.maximumZoomDistance = 45_000_000;
      ctrl.tiltEventTypes = [
        C.CameraEventType.MIDDLE_DRAG, C.CameraEventType.PINCH,
        { eventType: C.CameraEventType.LEFT_DRAG, modifier: C.KeyboardEventModifier.CTRL },
        { eventType: C.CameraEventType.LEFT_DRAG, modifier: C.KeyboardEventModifier.SHIFT },
        { eventType: C.CameraEventType.RIGHT_DRAG, modifier: C.KeyboardEventModifier.CTRL },
      ];
      viewer.cesiumWidget.screenSpaceEventHandler.removeInputAction(C.ScreenSpaceEventType.LEFT_DOUBLE_CLICK);
      viewer.camera.setView({ destination: C.Cartesian3.fromDegrees(HOME.lon, HOME.lat, HOME.height) });

      // More parallel tile requests per imagery host than Cesium's default of 6, so a new view fills in quickly.
      C.RequestScheduler.requestsByServer["services.arcgisonline.com:443"] = 16;
      C.RequestScheduler.requestsByServer["gibs.earthdata.nasa.gov:443"] = 12;
      const recordsDS = new C.CustomDataSource("records");
      const footDS = new C.CustomDataSource("footprints");
      const overlayDS = new C.CustomDataSource("overlay");
      await viewer.dataSources.add(footDS);
      await viewer.dataSources.add(recordsDS);
      await viewer.dataSources.add(overlayDS);

      const status: GlobeStatus = { imagery: "loading", stack: "checking imagery services", imageryNote: null, relief: "loading" };
      const st = {
        C, viewer, recordsDS, footDS, overlayDS,
        entities: new Map<string, CesiumNS.Entity>(), foot: new Map<string, CesiumNS.Entity>(),
        ellipsoidTerrain: new C.EllipsoidTerrainProvider(), status,
        draw: { pts: [] as [number, number][], cursor: null as [number, number] | null },
        available: { satellite: false, bluemarble: false },
      };
      S.current = st;
      (window as unknown as { __globe?: unknown }).__globe = { viewer, Cesium: C }; // handle for automated browser tests

      // ---- records, clustered ----
      const atlas = P.current.atlas;
      for (const r of atlas.records) {
        const e = recordsDS.entities.add({
          id: r.id,
          position: C.Cartesian3.fromDegrees(r.lon, r.lat),
          billboard: {
            image: markerIcon(r.kind, r.body),
            scale: 0.5,
            verticalOrigin: C.VerticalOrigin.CENTER,
            heightReference: C.HeightReference.CLAMP_TO_GROUND,
            disableDepthTestDistance: Number.POSITIVE_INFINITY,
          },
        });
        st.entities.set(r.id, e);
        if (r.ring) {
          const f = footDS.entities.add({
            id: `fp:${r.id}`,
            polyline: {
              positions: C.Cartesian3.fromDegreesArray(r.ring.flat()),
              width: 1,
              clampToGround: true,
              material: C.Color.fromCssColorString(r.body === "Moon" ? MOON_LINE : MARS_LINE).withAlpha(0.8),
              distanceDisplayCondition: new C.DistanceDisplayCondition(0, 900_000),
            },
          });
          st.foot.set(r.id, f);
        }
      }
      const cl = recordsDS.clustering;
      cl.enabled = true;
      cl.pixelRange = 46;
      cl.minimumClusterSize = 2;
      cl.clusterBillboards = true;
      cl.clusterLabels = false;
      cl.clusterPoints = false;
      cl.clusterEvent.addEventListener((ents: CesiumNS.Entity[], cluster: { billboard: CesiumNS.Billboard; label: CesiumNS.Label; point: CesiumNS.PointPrimitive }) => {
        let moon = 0;
        for (const e of ents) if (atlas.byId.get(e.id)?.body === "Moon") moon++;
        cluster.label.show = false;
        cluster.billboard.show = true;
        cluster.billboard.id = cluster.label.id;
        cluster.billboard.image = clusterIcon(ents.length, moon / ents.length) as unknown as string;
        cluster.billboard.scale = 0.5;
        cluster.billboard.verticalOrigin = C.VerticalOrigin.CENTER;
        cluster.billboard.disableDepthTestDistance = Number.POSITIVE_INFINITY;
      });

      // ---- input ----
      const handler = new C.ScreenSpaceEventHandler(scene.canvas);
      let clickTimer: ReturnType<typeof setTimeout> | null = null;
      const pickLL = (pos: CesiumNS.Cartesian2): [number, number] | null => {
        let cart: CesiumNS.Cartesian3 | undefined;
        const ray = viewer.camera.getPickRay(pos);
        if (ray) cart = scene.globe.pick(ray, scene);
        if (!cart) cart = viewer.camera.pickEllipsoid(pos, scene.globe.ellipsoid);
        if (!cart) return null;
        const c = C.Cartographic.fromCartesian(cart);
        return [C.Math.toDegrees(c.longitude), C.Math.toDegrees(c.latitude)];
      };
      const pickIds = (pos: CesiumNS.Cartesian2): string[] | null => {
        const picked = scene.pick(pos);
        if (!picked || picked.id === undefined) return null;
        const id = picked.id;
        if (Array.isArray(id)) return (id as CesiumNS.Entity[]).map((e) => e.id).filter((x) => atlas.byId.has(x));
        const eid: string | undefined = typeof id === "string" ? id : id.id;
        if (!eid) return null;
        if (atlas.byId.has(eid)) return [eid];
        if (eid.startsWith("fp:") && atlas.byId.has(eid.slice(3))) return [eid.slice(3)];
        return null;
      };
      handler.setInputAction((ev: { position: CesiumNS.Cartesian2 }) => {
        const p = P.current;
        p.onHover(null);
        if (p.drawMode) {
          const ll = pickLL(ev.position);
          if (!ll) return;
          if (p.drawMode === "point") { p.onDrawPoint(ll[1], ll[0]); return; }
          const d = st.draw;
          if (p.drawMode === "rect") {
            d.pts.push(ll);
            if (d.pts.length === 2) {
              const [a, b] = d.pts;
              d.pts = []; d.cursor = null;
              p.onDrawArea({ type: "rect", west: Math.min(a[0], b[0]), east: Math.max(a[0], b[0]), south: Math.min(a[1], b[1]), north: Math.max(a[1], b[1]) });
            }
          } else {
            d.pts.push(ll);
          }
          renderDraft();
          return;
        }
        const ids = pickIds(ev.position);
        if (ids && ids.length === 1) { p.onSelect(ids[0]); return; }
        if (ids && ids.length > 1) {
          const recs = ids.map((i) => atlas.byId.get(i)!);
          let w = 180, e = -180, s = 90, n = -90;
          for (const r of recs) { w = Math.min(w, r.lon); e = Math.max(e, r.lon); s = Math.min(s, r.lat); n = Math.max(n, r.lat); }
          const spanKm = Math.max((n - s) * 111, (e - w) * 111 * Math.cos(((s + n) / 2) * Math.PI / 180));
          const height = viewer.camera.positionCartographic.height;
          if (spanKm < 6 || height < 60_000) { p.onClusterAtPoint(ids); return; }
          const pad = Math.max(0.15, Math.max(n - s, e - w) * 0.35);
          viewer.camera.flyTo({ destination: C.Rectangle.fromDegrees(w - pad, Math.max(-89, s - pad), e + pad, Math.min(89, n + pad)), duration: p.reducedMotion ? 0 : 1.1 });
          return;
        }
        const ll = pickLL(ev.position);
        if (!ll) return;
        // wait briefly so a double-click (zoom) does not also select a location
        if (clickTimer) clearTimeout(clickTimer);
        clickTimer = setTimeout(() => { clickTimer = null; P.current.onMapClick(ll[1], ll[0]); }, 260);
      }, C.ScreenSpaceEventType.LEFT_CLICK);
      handler.setInputAction((ev: { position: CesiumNS.Cartesian2 }) => {
        const p = P.current;
        if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
        if (p.drawMode === "polygon") { finishPolygon(); return; }
        if (p.drawMode) return;
        const ll = pickLL(ev.position);
        if (!ll) return;
        const h = viewer.camera.positionCartographic.height;
        flyToPointInternal(ll[1], ll[0], Math.max(400, h * 0.45), false);
      }, C.ScreenSpaceEventType.LEFT_DOUBLE_CLICK);
      let lastMove = 0;
      handler.setInputAction((ev: { endPosition: CesiumNS.Cartesian2 }) => {
        const now = performance.now();
        if (now - lastMove < 40) return;
        lastMove = now;
        const p = P.current;
        const ll = pickLL(ev.endPosition);
        p.onCursor(ll ? { lat: ll[1], lon: ll[0] } : null);
        if (p.drawMode) {
          scene.canvas.style.cursor = "crosshair";
          if (p.drawMode !== "point" && st.draw.pts.length) { st.draw.cursor = ll; renderDraft(); }
          p.onHover(null);
          return;
        }
        const ids = pickIds(ev.endPosition);
        scene.canvas.style.cursor = ids ? "pointer" : "";
        p.onHover(ids ? { x: ev.endPosition.x, y: ev.endPosition.y, ids } : null);
      }, C.ScreenSpaceEventType.MOUSE_MOVE);

      const finishPolygon = () => {
        const d = st.draw;
        // the double-click also produced two single clicks at the same place: drop duplicates
        const pts = d.pts.filter((p, i) => i === 0 || Math.abs(p[0] - d.pts[i - 1][0]) > 1e-7 || Math.abs(p[1] - d.pts[i - 1][1]) > 1e-7);
        d.pts = []; d.cursor = null;
        renderDraft();
        if (pts.length >= 3) P.current.onDrawArea({ type: "polygon", ring: pts });
      };
      const onKey = (e: KeyboardEvent) => {
        if (!P.current.drawMode) return;
        if (e.key === "Enter" && P.current.drawMode === "polygon") finishPolygon();
        if (e.key === "Escape") { st.draw.pts = []; st.draw.cursor = null; renderDraft(); }
      };
      window.addEventListener("keydown", onKey);

      const renderDraft = () => {
        const id = "draft";
        overlayDS.entities.removeById(id);
        const d = st.draw;
        const mode = P.current.drawMode;
        if (!d.pts.length || !mode) { scene.requestRender(); return; }
        let ring: [number, number][] = [];
        if (mode === "rect" && d.cursor) {
          const a = d.pts[0], b = d.cursor;
          ring = areaRing({ type: "rect", west: Math.min(a[0], b[0]), east: Math.max(a[0], b[0]), south: Math.min(a[1], b[1]), north: Math.max(a[1], b[1]) });
        } else if (mode === "polygon") {
          ring = [...d.pts, ...(d.cursor ? [d.cursor] : []), d.pts[0]];
        }
        if (ring.length >= 2) {
          overlayDS.entities.add({ id, polyline: { positions: C.Cartesian3.fromDegreesArray(ring.flat()), width: 1.5, clampToGround: true, material: new C.PolylineDashMaterialProperty({ color: C.Color.fromCssColorString("#F7F8F5"), dashLength: 12 }) } });
        }
        scene.requestRender();
      };

      // ---- camera reporting ----
      const report = () => {
        const cam = viewer.camera;
        const w = scene.canvas.clientWidth, h = scene.canvas.clientHeight;
        let mpp: number | null = null;
        const a = cam.pickEllipsoid(new C.Cartesian2(w / 2 - 50, h / 2), scene.globe.ellipsoid);
        const b = cam.pickEllipsoid(new C.Cartesian2(w / 2 + 50, h / 2), scene.globe.ellipsoid);
        if (a && b) {
          const g = new C.EllipsoidGeodesic(C.Cartographic.fromCartesian(a), C.Cartographic.fromCartesian(b));
          mpp = g.surfaceDistance / 100;
        }
        P.current.onCamera({ heading: C.Math.toDegrees(cam.heading), pitch: C.Math.toDegrees(cam.pitch), height: cam.positionCartographic.height, metersPerPixel: mpp });
      };
      viewer.camera.moveStart.addEventListener(() => P.current.onHover(null));
      let lastActivity = performance.now();
      const touch = () => { lastActivity = performance.now(); };
      viewer.camera.changed.addEventListener(touch);
      viewer.camera.moveEnd.addEventListener(touch);
      viewer.imageryLayers.layerAdded.addEventListener(touch);
      scene.globe.tileLoadProgressEvent.addEventListener(touch); // progress counts as activity
      scene.postRender.addEventListener(() => {
        // In request-render mode Cesium stops drawing when the camera stops, which can strand half-loaded tiles.
        // Keep drawing while tiles are still arriving; give up after 60 s with no progress so an unreachable tile cannot spin forever.
        if (!scene.globe.tilesLoaded && performance.now() - lastActivity < 60_000) scene.requestRender();
      });
      viewer.camera.percentageChanged = 0.005;
      viewer.camera.changed.addEventListener(report);
      viewer.camera.moveEnd.addEventListener(report);
      report();

      // ---- helpers used by the imperative handle ----
      const flyToPointInternal = (lat: number, lon: number, rangeM: number, tilt: boolean) => {
        const cam = viewer.camera;
        const carto = C.Cartographic.fromDegrees(lon, lat);
        const hgt = scene.globe.getHeight(carto) ?? 0;
        const target = C.Cartesian3.fromDegrees(lon, lat, hgt);
        const pitch = tilt ? C.Math.toRadians(-50) : Math.min(cam.pitch, C.Math.toRadians(-35));
        cam.flyToBoundingSphere(new C.BoundingSphere(target, 1), {
          offset: new C.HeadingPitchRange(cam.heading, rangeM > 2_000_000 ? C.Math.toRadians(-90) : pitch, rangeM),
          duration: P.current.reducedMotion ? 0 : undefined,
        });
      };
      (st as unknown as { fly: typeof flyToPointInternal }).fly = flyToPointInternal;

      // ---- imagery and terrain, with fallbacks ----
      const [okSat, okBM] = await Promise.all([
        probeImage(ESRI_IMAGERY.replace("{z}", "2").replace("{y}", "1").replace("{x}", "1")),
        probeImage(GIBS_GEO.replace("{gz}", "3").replace("{y}", "1").replace("{x}", "2")),
      ]);
      if (destroyed) return;
      st.available = { satellite: okSat, bluemarble: okBM };
      applyImagery();
      applyRelief();
      applyCoverage();
      applyVisibility();
      applySelection();
      applyArea();
      applyLocation();
      scene.requestRender();

      cleanup = () => {
        window.removeEventListener("keydown", onKey);
        handler.destroy();
        viewer.destroy();
      };
    })();
    return () => { destroyed = true; S.current = null; if (cleanup) cleanup(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ---------- reactive layers ----------
  const pushStatus = () => { const s = S.current; if (s) P.current.onStatus({ ...s.status }); };

  const applyImagery = () => {
    const s = S.current; if (!s) return;
    const { C, viewer } = s;
    const want = P.current.layers.imagery;
    // Stack, bottom to top: [Natural Earth, only when nothing online is reachable] [NASA Blue Marble, whole globe incl. poles] [Esri World Imagery].
    // Blue Marble stays underneath the satellite layer, so areas whose high-resolution tiles are still streaming (and the
    // polar caps that web-mercator imagery cannot cover) show real, credited imagery instead of an empty or flat surface.
    if (s.available.bluemarble && !s.underlay) {
      s.underlay = viewer.imageryLayers.addImageryProvider(new C.UrlTemplateImageryProvider({
        url: GIBS_GEO,
        tilingScheme: new C.GeographicTilingScheme({ numberOfLevelZeroTilesX: 10, numberOfLevelZeroTilesY: 5 }),
        tileWidth: 512, tileHeight: 512, maximumLevel: 4,
        customTags: { gz: (_p: unknown, _x: number, _y: number, level: number) => String(level + 3) },
        credit: new C.Credit("NASA Blue Marble: NASA GIBS / ESDIS", true),
      }), 0);
    }
    if (!s.available.bluemarble && !s.offline) {
      s.offline = true;
      C.TileMapServiceImageryProvider.fromUrl(C.buildModuleUrl("Assets/Textures/NaturalEarthII")).then((p) => {
        if (!S.current) return;
        viewer.imageryLayers.addImageryProvider(p, 0);
        viewer.scene.requestRender();
      }).catch(() => undefined);
    }
    const showSat = want === "satellite" && s.available.satellite;
    if (showSat && !s.base) {
      s.base = viewer.imageryLayers.addImageryProvider(new C.UrlTemplateImageryProvider({ url: ESRI_IMAGERY, maximumLevel: 19, credit: new C.Credit("Imagery: Esri, Maxar, Earthstar Geographics, and the GIS User Community", true) }), s.underlay ? 1 : 0);
    } else if (!showSat && s.base) {
      viewer.imageryLayers.remove(s.base, true); s.base = undefined;
    }
    if (showSat) {
      s.status.imagery = "satellite";
      s.status.stack = s.available.bluemarble ? "Esri World Imagery, over NASA Blue Marble while tiles load and at the poles" : "Esri World Imagery";
      s.status.imageryNote = s.available.bluemarble ? null : "NASA Blue Marble could not be reached; areas still loading and the polar caps may look blank.";
    } else if (s.available.bluemarble) {
      s.status.imagery = "bluemarble";
      s.status.stack = "NASA Blue Marble (500 m)";
      s.status.imageryNote = want === "satellite" ? "High-resolution satellite imagery could not be reached. Showing NASA Blue Marble (500 m); close-up views will look soft." : null;
    } else {
      s.status.imagery = "offline";
      s.status.stack = "Natural Earth II (built-in, low resolution)";
      s.status.imageryNote = "Online imagery could not be reached. Showing the built-in low-resolution Natural Earth map; zooming in will look coarse.";
    }
    applyLabels();
    pushStatus();
    viewer.scene.requestRender();
  };

  const applyLabels = () => {
    const s = S.current; if (!s) return;
    const { C, viewer } = s;
    const want = P.current.layers.labels && s.available.satellite;
    if (want && !s.labels) {
      s.labels = new C.ImageryLayer(new C.UrlTemplateImageryProvider({ url: ESRI_LABELS, maximumLevel: 13, credit: new C.Credit("Boundaries and places: Esri, HERE, Garmin, © OpenStreetMap contributors", true) }), { minimumTerrainLevel: 4, alpha: 0.92 });
      viewer.imageryLayers.add(s.labels);
    } else if (!want && s.labels) {
      viewer.imageryLayers.remove(s.labels, true); s.labels = undefined;
    }
    if (s.coverage) viewer.imageryLayers.raiseToTop(s.coverage);
    viewer.scene.requestRender();
  };

  const applyRelief = () => {
    const s = S.current; if (!s) return;
    const { C, viewer } = s;
    if (!P.current.layers.relief) {
      viewer.terrainProvider = s.ellipsoidTerrain; s.status.relief = "off"; pushStatus(); viewer.scene.requestRender(); return;
    }
    if (s.terrain) { viewer.terrainProvider = s.terrain; s.status.relief = "on"; pushStatus(); viewer.scene.requestRender(); return; }
    s.status.relief = "loading"; pushStatus();
    C.ArcGISTiledElevationTerrainProvider.fromUrl(ESRI_TERRAIN).then((tp) => {
      if (!S.current) return;
      S.current.terrain = tp;
      if (P.current.layers.relief) { viewer.terrainProvider = tp; S.current.status.relief = "on"; }
      pushStatus(); viewer.scene.requestRender();
    }).catch(() => {
      if (!S.current) return;
      S.current.status.relief = "unavailable"; pushStatus();
    });
  };

  const applyCoverage = () => {
    const s = S.current; if (!s) return;
    const { C, viewer, overlayDS } = s;
    const atlas = P.current.atlas;
    if (s.coverage) { viewer.imageryLayers.remove(s.coverage, true); s.coverage = undefined; }
    for (const r of atlas.bundle.geology_v2?.regions ?? []) overlayDS.entities.removeById(`region:${r.id}`);
    if (!P.current.layers.coverage || !atlas.coverage.length) { viewer.scene.requestRender(); return; }
    let w = 180, e = -180, so = 90, n = -90;
    for (const t of atlas.coverage) { w = Math.min(w, t.west); e = Math.max(e, t.west + 1); so = Math.min(so, t.south); n = Math.max(n, t.south + 1); }
    const k = Math.max(4, Math.min(24, Math.floor(4096 / Math.max(1, e - w)))); // keep the texture within common GPU limits
    const cv = document.createElement("canvas");
    cv.width = (e - w) * k; cv.height = (n - so) * k;
    const g = cv.getContext("2d")!;
    for (const t of atlas.coverage) {
      const x = (t.west - w) * k, y = (n - t.south - 1) * k;
      g.fillStyle = t.status === "windows" ? "rgba(120,200,170,0.30)" : t.status === "no_valid_windows" ? "rgba(200,205,210,0.22)" : "rgba(30,34,40,0.50)";
      g.fillRect(x, y, k, k);
      if (k >= 10) { g.strokeStyle = "rgba(240,245,244,0.28)"; g.lineWidth = 1; g.strokeRect(x + 0.5, y + 0.5, k - 1, k - 1); }
    }
    s.coverage = viewer.imageryLayers.addImageryProvider(new C.SingleTileImageryProvider({ url: cv.toDataURL("image/png"), rectangle: C.Rectangle.fromDegrees(w, so, e, n), tileWidth: cv.width, tileHeight: cv.height }));
    s.coverage.magnificationFilter = C.TextureMagnificationFilter.NEAREST;
    s.coverage.minificationFilter = C.TextureMinificationFilter.NEAREST;
    for (const r of atlas.bundle.geology_v2?.regions ?? []) {
      overlayDS.entities.add({
        id: `region:${r.id}`,
        polyline: { positions: C.Cartesian3.fromDegreesArray(circleRing(r.centre[0], r.centre[1], r.radius_km).flat()), width: 2, clampToGround: true, material: new C.PolylineDashMaterialProperty({ color: C.Color.fromCssColorString(MARS_LINE), dashLength: 10 }) },
      });
    }
    viewer.scene.requestRender();
  };

  const applyVisibility = () => {
    const s = S.current; if (!s) return;
    const vis = P.current.visibleIds;
    const showFoot = P.current.layers.footprints;
    for (const [id, e] of s.entities) e.show = vis.has(id);
    for (const [id, f] of s.foot) f.show = showFoot && vis.has(id);
    // force the clusterer to rebuild
    const cl = s.recordsDS.clustering;
    const pr = cl.pixelRange;
    cl.pixelRange = pr + 1;
    cl.pixelRange = pr;
    s.viewer.scene.requestRender();
  };

  const applySelection = () => {
    const s = S.current; if (!s) return;
    const { C, overlayDS, viewer } = s;
    for (const id of ["sel:ring", "sel:foot", "sel:fill", "sel:look0", "sel:look1", "sel:look2"]) overlayDS.entities.removeById(id);
    const r = P.current.selected;
    if (r) {
      overlayDS.entities.add({
        id: "sel:ring", position: C.Cartesian3.fromDegrees(r.lon, r.lat),
        billboard: { image: ringIcon(), scale: 0.5, verticalOrigin: C.VerticalOrigin.CENTER, heightReference: C.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: 4_000_000 },
      });
      if (r.ring) {
        const pos = C.Cartesian3.fromDegreesArray(r.ring.flat());
        overlayDS.entities.add({ id: "sel:fill", polygon: { hierarchy: new C.PolygonHierarchy(pos), material: C.Color.fromCssColorString("#F7F8F5").withAlpha(0.06), classificationType: C.ClassificationType.TERRAIN } });
        overlayDS.entities.add({ id: "sel:foot", polyline: { positions: pos, width: 2, clampToGround: true, material: C.Color.fromCssColorString("#F7F8F5") } });
      }
      if (r.kind === "geo2") {
        const look = (r.raw as { look_here?: { lat: number; lon: number }[] }).look_here ?? [];
        look.slice(0, 3).forEach((p, i) => {
          overlayDS.entities.add({
            id: `sel:look${i}`, position: C.Cartesian3.fromDegrees(p.lon, p.lat),
            billboard: { image: smallSquare(), scale: 0.5, verticalOrigin: C.VerticalOrigin.CENTER, heightReference: C.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: 4_000_000 },
          });
        });
      }
    }
    viewer.scene.requestRender();
  };

  const applyArea = () => {
    const s = S.current; if (!s) return;
    const { C, overlayDS, viewer } = s;
    overlayDS.entities.removeById("area");
    overlayDS.entities.removeById("area:fill");
    const a = P.current.area;
    if (a) {
      const pos = C.Cartesian3.fromDegreesArray(areaRing(a).flat());
      overlayDS.entities.add({ id: "area:fill", polygon: { hierarchy: new C.PolygonHierarchy(pos), material: C.Color.fromCssColorString("#F7F8F5").withAlpha(0.07), classificationType: C.ClassificationType.TERRAIN } });
      overlayDS.entities.add({ id: "area", polyline: { positions: pos, width: 1.5, clampToGround: true, material: C.Color.fromCssColorString("#F7F8F5") } });
    }
    viewer.scene.requestRender();
  };

  const applyLocation = () => {
    const s = S.current; if (!s) return;
    const { C, overlayDS, viewer } = s;
    overlayDS.entities.removeById("loc");
    const l = P.current.location;
    if (l) {
      overlayDS.entities.add({ id: "loc", position: C.Cartesian3.fromDegrees(l.lon, l.lat), billboard: { image: pinIcon(), scale: 0.5, verticalOrigin: C.VerticalOrigin.CENTER, heightReference: C.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: 4_000_000 } });
    }
    viewer.scene.requestRender();
  };

  useEffect(applyVisibility, [props.visibleIds, props.layers.footprints]);
  useEffect(applySelection, [props.selected]);
  useEffect(applyArea, [props.area]);
  useEffect(applyLocation, [props.location]);
  useEffect(applyImagery, [props.layers.imagery]);
  useEffect(applyLabels, [props.layers.labels]);
  useEffect(applyRelief, [props.layers.relief]);
  useEffect(applyCoverage, [props.layers.coverage]);
  useEffect(() => {
    const s = S.current; if (!s) return;
    s.draw.pts = []; s.draw.cursor = null;
    s.overlayDS.entities.removeById("draft");
    if (!props.drawMode) s.viewer.scene.canvas.style.cursor = "";
    s.viewer.scene.requestRender();
  }, [props.drawMode]);

  useImperativeHandle(ref, () => ({
    flyToRecord(rec) {
      const s = S.current; if (!s) return;
      const fly = (s as unknown as { fly: (a: number, b: number, c: number, d: boolean) => void }).fly;
      fly(rec.lat, rec.lon, rec.kind === "geo2" ? 26_000 : 34_000, true);
    },
    flyToPoint(lat, lon, rangeM = 60_000) {
      const s = S.current; if (!s) return;
      (s as unknown as { fly: (a: number, b: number, c: number, d: boolean) => void }).fly(lat, lon, rangeM, false);
    },
    flyToBox(west, south, east, north) {
      const s = S.current; if (!s) return;
      const padX = Math.max(0.02, (east - west) * 0.15), padY = Math.max(0.02, (north - south) * 0.15);
      s.viewer.camera.flyTo({ destination: s.C.Rectangle.fromDegrees(west - padX, Math.max(-89.9, south - padY), east + padX, Math.min(89.9, north + padY)), duration: P.current.reducedMotion ? 0 : undefined });
    },
    flyHome() {
      const s = S.current; if (!s) return;
      s.viewer.camera.flyTo({ destination: s.C.Cartesian3.fromDegrees(HOME.lon, HOME.lat, HOME.height), duration: P.current.reducedMotion ? 0 : 1.4 });
    },
    zoom(factor) {
      const s = S.current; if (!s) return;
      const cam = s.viewer.camera;
      const h = cam.positionCartographic.height;
      const total = h * (1 - factor);
      if (P.current.reducedMotion) { cam.moveForward(total); s.viewer.scene.requestRender(); return; }
      const t0 = performance.now();
      let done = 0;
      const step = (t: number) => {
        if (!S.current) return;
        const k = Math.min(1, (t - t0) / 260);
        const ease = 1 - Math.pow(1 - k, 3);
        cam.moveForward(total * ease - done);
        done = total * ease;
        s.viewer.scene.requestRender();
        if (k < 1) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    },
    resetNorth() {
      const s = S.current; if (!s) return;
      const { C, viewer } = s;
      const cam = viewer.camera;
      const cv = viewer.scene.canvas;
      const center = cam.pickEllipsoid(new C.Cartesian2(cv.clientWidth / 2, cv.clientHeight / 2), viewer.scene.globe.ellipsoid);
      if (!center) { cam.flyTo({ destination: cam.positionWC.clone(), orientation: { heading: 0, pitch: cam.pitch, roll: 0 }, duration: 0.5 }); return; }
      const range = C.Cartesian3.distance(cam.positionWC, center);
      cam.flyToBoundingSphere(new C.BoundingSphere(center, 1), { offset: new C.HeadingPitchRange(0, cam.pitch, range), duration: P.current.reducedMotion ? 0 : 0.6 });
    },
    toggleTilt() {
      const s = S.current; if (!s) return;
      const { C, viewer } = s;
      const cam = viewer.camera;
      const cv = viewer.scene.canvas;
      const center = cam.pickEllipsoid(new C.Cartesian2(cv.clientWidth / 2, cv.clientHeight / 2), viewer.scene.globe.ellipsoid);
      if (!center) return;
      const range = Math.min(C.Cartesian3.distance(cam.positionWC, center), 6_000_000);
      const top = cam.pitch < C.Math.toRadians(-80);
      cam.flyToBoundingSphere(new C.BoundingSphere(center, 1), { offset: new C.HeadingPitchRange(cam.heading, C.Math.toRadians(top ? -45 : -90), range), duration: P.current.reducedMotion ? 0 : 0.8 });
    },
  }), []);

  return (
    <>
      <div ref={el} className="globe" aria-label="Interactive 3D globe of Earth showing the loaded analog records" role="application" />
      <div ref={creditEl} className="credits" />
    </>
  );
});

export default Globe;
