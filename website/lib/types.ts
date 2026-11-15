// Types for the engine bundle (schema 1.0 + optional geology_v2 block) and the unified atlas record.
// Every field is optional at runtime: the adapter validates and labels what is missing instead of assuming zero.

export type Band = { p10?: number; p25?: number; p50?: number; p75?: number; p90?: number };

export interface TerrainReference {
  id: string;
  body: string;
  ref_type?: string;
  description?: string;
  exploration_purpose?: string;
  baselines_m?: number[];
  grid_m?: number;
  slope_bands_deg?: Record<string, Band>;
  connectivity_curve?: Record<string, number>;
  not_comparable?: string[];
  warnings?: string[];
  yardstick?: Record<string, unknown> | null;
}

export interface CandidateProperty {
  property: string;
  unit?: string;
  value?: number | null;
  reference_band?: Band;
  outcome?: string;
}

export interface Candidate {
  id: string;
  pathway: string;
  reference: string;
  rank_rule?: string;
  pareto_front?: number;
  position: { lat: number; lon: number };
  footprint?: Record<string, unknown>;
  distances?: {
    worst_scale_slope_W1_deg?: number;
    worst_scale_log10_roughness_W1?: number;
    connectivity_distance?: number;
    by_baseline_deg?: Record<string, number>;
  };
  inside_yardstick?: boolean;
  properties?: CandidateProperty[];
  land_cover?: { valid_fraction?: number; bare_fraction?: number; snow_ice_fraction?: number };
  cross_pathway?: Record<string, Record<string, unknown>>;
  evidence?: { supporting?: string[]; contradicting?: string[]; unmeasured?: string[]; not_comparable?: string[] };
  evidence_ladder?: Record<string, boolean | string>;
  tier?: string;
  values?: Record<string, number>;
}

export interface ComparisonRow {
  property: string;
  role: string;
  role_label?: string;
  mars_site?: string | null;
  mars_evidence_type?: string;
  mars_statement?: string;
  citations?: string[];
  earth_status?: string;
  earth_source?: string | null;
  earth_text?: string | null;
}

export interface GeoUnit {
  id: string;
  region: string;
  reference: string;
  unit_name: string;
  unit_link: string;
  state?: string;
  unit_age?: string | null;
  polygons?: number;
  area_km2?: number;
  nearest_distance_km?: number | null;
  nearest_point?: [number, number] | null;
  steep_ground_km2?: number;
  public_steep_ground_km2?: number;
  public_lands_with_steep_ground?: string[];
  look_here?: { lat: number; lon: number; steep_public_m2?: number }[];
  exposure_checked_polygons?: number;
  how_core_was_established?: { property: string; earth_status: string }[];
  supporting_recorded?: string[];
  supporting_total?: number;
  conflicts?: string[];
  spatial_context?: Record<string, boolean | number>;
  macrostrat?: { name_matches?: number | null; accepted?: number; rejected?: { strat_name?: string; reason?: string }[] };
  map_source?: { reference?: string | null; scale?: number | null; contact_position_uncertainty_m?: number | null };
  comparison?: ComparisonRow[];
  representative_polygon?: number;
  exposure_note?: string;
  not_comparable?: string[];
  unmeasured?: string[];
}

export interface GeoReference {
  id: string;
  name: string;
  site_note?: string | null;
  locations?: { site?: string; lat?: number; lon?: number }[];
  not_comparable?: string[];
  properties?: {
    code: string;
    role: string;
    role_label?: string;
    mars_site?: string | null;
    evidence_type?: string;
    statement?: string;
    citations?: string[];
  }[];
}

export interface FeaturedCase {
  id: string;
  region: string;
  reference: string;
  title: string;
  outcome: string;
  unit_name: string;
  unit_link: string;
  preserve_area_km2?: number;
  polygon_area_km2?: number;
  share_within_500m_of_intrusive_contact?: number;
  units_mapped_in_preserve?: [string, string][];
  conflicts?: string[];
  note?: string;
  comparison?: ComparisonRow[];
}

export interface GeoRegion {
  id: string;
  role: string;
  centre: [number, number];
  radius_km: number;
  created?: string;
  n_polygons?: number;
  n_units?: number;
  datasets?: Record<string, string>;
}

export interface GeologyV2 {
  block_version?: string;
  regions?: GeoRegion[];
  references?: GeoReference[];
  featured?: FeaturedCase[];
  units?: GeoUnit[];
  controls?: { region: string; reference: string; method: string; precision?: number | null; recall?: number | null; false_positives?: unknown[]; missed?: unknown[] }[];
  citations?: Record<string, string>;
  limitations?: string[];
  display_rules?: string[];
}

export interface RunInfo {
  manifest_describe_as?: string;
  created_utc?: string;
  tiles?: Record<string, number>;
  windows?: Record<string, number>;
  software?: Record<string, string>;
  parameters?: Record<string, unknown>;
  datasets?: Record<string, string>;
  known_coverage_limits?: string[];
}

export interface Bundle {
  schema_version?: string;
  outcome_vocabulary?: string[];
  run?: RunInfo;
  geology_run?: Record<string, unknown>;
  references?: TerrainReference[];
  candidates?: Candidate[];
  coverage?: Record<string, number | string>;
  regional_state_geology?: Record<string, unknown> | null;
  limitations?: string[];
  geology_v2?: GeologyV2;
}

export type RecordKind = "terrain" | "rock" | "geo2";

/** One mappable record. `raw` is the untouched engine record. */
export interface AtlasRecord {
  id: string;
  kind: RecordKind;
  pathwayLabel: string;
  referenceId: string;
  body: "Moon" | "Mars" | "Unknown";
  lat: number;
  lon: number;
  title: string;
  subtitle: string;
  /** What the map position means for this record. */
  positionMeaning: string;
  ring?: [number, number][];
  ringKind?: string;
  raw: Candidate | GeoUnit;
}

export interface CoverageTile {
  name: string;
  south: number;
  west: number;
  status: "windows" | "no_valid_windows" | "skipped_landcover" | "other";
  windows: number | null;
  rawStatus: number | string;
}

export interface Atlas {
  bundle: Bundle;
  records: AtlasRecord[];
  byId: Map<string, AtlasRecord>;
  terrainRefs: Map<string, TerrainReference>;
  geoRefs: Map<string, GeoReference>;
  coverage: CoverageTile[];
  coverageByKey: Map<string, CoverageTile>;
  counts: { terrain: number; rock: number; geo2: number; total: number };
  issues: string[];
  geometryNote: string | null;
}
