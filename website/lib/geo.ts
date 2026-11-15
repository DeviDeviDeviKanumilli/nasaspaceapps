// Small geographic helpers (WGS84 sphere approximations are stated where used).

export const R_KM = 6371.0088;
const rad = (d: number) => (d * Math.PI) / 180;

/** Great-circle distance in km (spherical mean radius; good to ~0.3%). */
export function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat = rad(lat2 - lat1);
  const dLon = rad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R_KM * Math.asin(Math.min(1, Math.sqrt(a)));
}

/** Ray-casting point-in-polygon on lon/lat (adequate for small rings away from the antimeridian). */
export function pointInRing(lon: number, lat: number, ring: [number, number][]): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if (yi > lat !== yj > lat && lon < ((xj - xi) * (lat - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

export function formatLat(lat: number, digits = 4): string {
  return `${Math.abs(lat).toFixed(digits)}° ${lat >= 0 ? "N" : "S"}`;
}
export function formatLon(lon: number, digits = 4): string {
  return `${Math.abs(lon).toFixed(digits)}° ${lon >= 0 ? "E" : "W"}`;
}
export function formatLatLon(lat: number, lon: number, digits = 4): string {
  return `${formatLat(lat, digits)}, ${formatLon(lon, digits)}`;
}

/** Parses "40.33, -74.6", "40.33N 74.6W", "40°19'48\"N 74°36'W". Returns null when the text is not a coordinate pair. */
export function parseCoordinates(text: string): { lat: number; lon: number } | null {
  const t = text.trim();
  if (!t) return null;
  const dms = /(-?\d+(?:\.\d+)?)\s*°?\s*(?:(\d+(?:\.\d+)?)\s*['′]\s*)?(?:(\d+(?:\.\d+)?)\s*["″]\s*)?([NSEW])?/gi;
  const parts: { v: number; h: string | null }[] = [];
  let m: RegExpExecArray | null;
  const cleaned = t.replace(/[,;]/g, " ");
  while ((m = dms.exec(cleaned)) !== null) {
    if (m[0].trim() === "") { dms.lastIndex++; continue; }
    const deg = parseFloat(m[1]);
    const min = m[2] ? parseFloat(m[2]) : 0;
    const sec = m[3] ? parseFloat(m[3]) : 0;
    const sign = deg < 0 ? -1 : 1;
    const v = sign * (Math.abs(deg) + min / 60 + sec / 3600);
    parts.push({ v, h: m[4] ? m[4].toUpperCase() : null });
  }
  if (parts.length !== 2) return null;
  // Reject inputs with other words (place names containing numbers).
  if (/[a-df-mo-rt-vx-z]{2,}/i.test(t.replace(/[NSEW]/gi, ""))) return null;
  let lat: number, lon: number;
  const [a, b] = parts;
  if (a.h && "EW".includes(a.h) && (!b.h || "NS".includes(b.h))) {
    lon = a.v * (a.h === "W" ? -1 : 1);
    lat = b.v * (b.h === "S" ? -1 : 1);
  } else {
    lat = a.v * (a.h === "S" ? -1 : 1);
    lon = b.v * (b.h === "W" ? -1 : 1);
  }
  if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
  return { lat, lon };
}

/** Copernicus GLO tile name for the 1-degree cell containing a point, e.g. Copernicus_DSM_COG_30_N40_00_W075_00_DEM. */
export function tileKey(lat: number, lon: number): string {
  const la = Math.floor(lat);
  const lo = Math.floor(lon);
  return `${la >= 0 ? "N" : "S"}${String(Math.abs(la)).padStart(2, "0")}_${lo >= 0 ? "E" : "W"}${String(Math.abs(lo)).padStart(3, "0")}`;
}

/** Parses the south-west corner from a Copernicus tile name. Returns null if the name does not follow the convention. */
export function parseTileName(name: string): { south: number; west: number; key: string } | null {
  const m = /_([NS])(\d{2})_00_([EW])(\d{3})_00_DEM$/.exec(name);
  if (!m) return null;
  const south = parseInt(m[2], 10) * (m[1] === "N" ? 1 : -1);
  const west = parseInt(m[4], 10) * (m[3] === "E" ? 1 : -1);
  return { south, west, key: `${m[1]}${m[2]}_${m[3]}${m[4]}` };
}

export function niceScale(maxMeters: number): { meters: number; label: string } {
  const steps = [1, 2, 5];
  const pow = Math.pow(10, Math.floor(Math.log10(maxMeters)));
  let best = pow;
  for (const s of steps) if (s * pow <= maxMeters) best = s * pow;
  const label = best >= 1000 ? `${best / 1000} km` : `${best} m`;
  return { meters: best, label };
}
