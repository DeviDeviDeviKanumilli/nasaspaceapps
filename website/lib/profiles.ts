// Team-defined exploration scenarios. These are NOT NASA base selections and carry no score.
// Each scenario points at reference IDs that exist in the loaded bundle; the UI checks that they are present.

export type DimStatus = "measured" | "proxy" | "not measured";

export interface ProfileDimension {
  name: string;
  status: DimStatus;
  note: string;
}

export interface BaseProfile {
  id: string;
  body: "Moon" | "Mars";
  title: string;
  question: string;
  /** Reference IDs used to filter Earth records. */
  references: string[];
  /** Record kinds the filter applies to. */
  kinds: ("terrain" | "rock" | "geo2")[];
  relatedReferences: { id: string; why: string }[];
  dimensions: ProfileDimension[];
  notEstablished: string[];
  context: { label: string; url: string }[];
}

const LUNAR_UNMEASURED: ProfileDimension[] = [
  { name: "Illumination and power", status: "not measured", note: "No sun-visibility or horizon modelling is in this run. Polar lighting has no Earth equivalent." },
  { name: "Water ice and cold traps", status: "not measured", note: "No volatile, temperature or permanently-shadowed-region data are used." },
  { name: "Thermal environment", status: "not measured", note: "Not modelled; Earth sites cannot reproduce it." },
  { name: "Communications (line of sight to Earth)", status: "not measured", note: "Not modelled." },
  { name: "Rock and crater hazards at lander scale", status: "not measured", note: "The smallest baseline is 400 m on a 100 m grid; metre-scale hazards are below it." },
  { name: "Regolith mechanics and dust", status: "not measured", note: "Not measured; lunar regolith is listed as not comparable." },
  { name: "Access and logistics on Earth", status: "not measured", note: "Road access and land ownership of terrain windows are not evaluated in the terrain pathway." },
];

export const PROFILES: BaseProfile[] = [
  {
    id: "lunar-polar-access",
    body: "Moon",
    title: "Lunar polar accessible terrain",
    question: "Where on Earth does kilometre-scale terrain resemble the gentler ground inside the lunar south-pole reference sites?",
    references: ["MZ-FLAT"],
    kinds: ["terrain"],
    relatedReferences: [
      { id: "M-CR", why: "one of the four PGDA site boxes the flat-terrain class was pooled from" },
      { id: "M-MA", why: "one of the four PGDA site boxes the flat-terrain class was pooled from" },
    ],
    dimensions: [
      { name: "Slope distribution, 400 m to 3.2 km", status: "measured", note: "Plane-fit slope quantiles at four baselines, compared with the reference by Wasserstein distance (degrees)." },
      { name: "Roughness, 400 m to 3.2 km", status: "measured", note: "Detrended roughness (log10) at the same baselines." },
      { name: "Connected gentle terrain", status: "measured", note: "Largest connected share of the window below slope thresholds from 5° to 25°, at the 800 m baseline. Geometry only; not a trafficability test." },
      { name: "Bare ground on Earth", status: "measured", note: "ESA WorldCover bare/sparse fraction of the window; vegetated, built and water cells are masked out." },
      ...LUNAR_UNMEASURED,
    ],
    notEstablished: [
      "MZ-FLAT is a team-defined terrain class (at least 60% of 400 m slopes at or below 10°), not a NASA landing or habitat classification.",
      "A 400 m slope cannot certify a landing or walking surface.",
      "No Earth record here is claimed to be suitable for a base, a landing or a hardware test.",
    ],
    context: [
      { label: "NASA Moon to Mars Architecture", url: "https://www.nasa.gov/architecture/" },
      { label: "NASA: Artemis III candidate landing regions (2024 update)", url: "https://www.nasa.gov/news-release/nasa-provides-update-on-artemis-iii-moon-landing-regions/" },
    ],
  },
  {
    id: "lunar-high-relief",
    body: "Moon",
    title: "Lunar high-relief traverse",
    question: "Where on Earth does kilometre-scale terrain resemble the steep rim and massif slopes of the lunar south-pole reference sites?",
    references: ["MZ-STEEP"],
    kinds: ["terrain"],
    relatedReferences: [
      { id: "M-SR", why: "Shackleton rim site box (pooled into the steep class)" },
      { id: "M-DG", why: "de Gerlache rim site box (pooled into the steep class)" },
    ],
    dimensions: [
      { name: "Slope distribution, 400 m to 3.2 km", status: "measured", note: "Plane-fit slope quantiles at four baselines, compared with the reference (degrees)." },
      { name: "Roughness, 400 m to 3.2 km", status: "measured", note: "Detrended roughness (log10) at the same baselines." },
      { name: "Connected paths below slope thresholds", status: "measured", note: "Connectivity curve at the 800 m baseline, as geometry. It does not model a vehicle." },
      { name: "Traction, slip and wheel–soil interaction", status: "not measured", note: "Not measured; 1/6 gravity and lunar regolith are not comparable." },
      ...LUNAR_UNMEASURED,
    ],
    notEstablished: [
      "MZ-STEEP is a team-defined terrain class (at least 40% of 400 m slopes between 15° and 30°), not a NASA classification.",
      "Lunar relief is kilometres high; an Earth window can match slope statistics without matching absolute relief.",
      "No traverse, vehicle or safety assessment is implied.",
    ],
    context: [
      { label: "NASA Moon to Mars Architecture", url: "https://www.nasa.gov/architecture/" },
      { label: "NASA: candidate regions for Artemis III (2022)", url: "https://www.nasa.gov/news-release/nasa-identifies-candidate-regions-for-landing-next-americans-on-moon/" },
    ],
  },
  {
    id: "mars-landing-geometry",
    body: "Mars",
    title: "Mars landing-region geometry",
    question: "Where on Earth does kilometre-scale terrain resemble the ground around two Mars landing sites, at the resolution of the Mars elevation model?",
    references: ["R-IS", "R-JZ"],
    kinds: ["terrain"],
    relatedReferences: [],
    dimensions: [
      { name: "Slope distribution, 1.6 km and 3.2 km", status: "measured", note: "The Mars elevation model is 200 m/pixel, so only the two longer baselines are compared." },
      { name: "Roughness, 1.6 km and 3.2 km", status: "measured", note: "Detrended roughness (log10) at the same two baselines." },
      { name: "Bare ground on Earth", status: "measured", note: "ESA WorldCover bare/sparse fraction of the window." },
      { name: "Rock type under the window", status: "proxy", note: "GLiM rock-class shares are attached to each terrain window as context; they are 1:1M–1:5M map classes, not site lithology." },
      { name: "Rock abundance and size-frequency", status: "not measured", note: "Below the resolution of both elevation models." },
      { name: "Atmosphere, entry, descent and landing constraints", status: "not measured", note: "Not modelled. No landing-ellipse safety is implied." },
      { name: "Dust, thermal inertia, surface mechanics", status: "not measured", note: "Not measured." },
      { name: "Buried ice and other resources", status: "not measured", note: "Not evaluated in this run." },
    ],
    notEstablished: [
      "R-IS (InSight) is weakly discriminating: flat plains at 1.6–3.2 km resemble many places on Earth.",
      "R-JZ and R-IS are 1° boxes around the sites, not mission landing ellipses.",
      "Matching terrain statistics does not make a place safe to land on.",
    ],
    context: [{ label: "NASA Moon to Mars Architecture", url: "https://www.nasa.gov/architecture/" }],
  },
  {
    id: "mars-ancient-water",
    body: "Mars",
    title: "Mars ancient-water science access",
    question: "Which mapped rock units near the study areas record the same kind of evidence as the ancient lake deposits studied by rovers at Gale and Jezero craters?",
    references: ["MARS-LAKE"],
    kinds: ["geo2"],
    relatedReferences: [{ id: "R-JZ", why: "broad rock-type screening for Jezero-type rock (GLiM); a coarser, separate pathway" }],
    dimensions: [
      { name: "Fine-grained clastic rock (mudstone)", status: "measured", note: "Mapped lithology from USGS SGMC structured fields (major or minor), sometimes corroborated by Macrostrat. A map classification, not a hand-sample." },
      { name: "Lake depositional setting", status: "measured", note: "Recorded in the map-unit description, or inferred from at least two independent sedimentary indicators plus basin context; the record states which." },
      { name: "Desiccation cracks, cyclic and laminated bedding, clay, evaporite", status: "measured", note: "Recorded when the map-unit description mentions them ('mapped mention'). Not measured mineralogy or a field observation." },
      { name: "Igneous neighbours and intrusive contacts", status: "measured", note: "Computed from polygon adjacency: shared boundary with lava-flow units and share of area within 500 m of an intrusion." },
      { name: "Possible outcrop", status: "proxy", note: "Ground steeper than 25° on a ~20 m DEM inside the unit. A proxy; not confirmed rock." },
      { name: "Public access", status: "proxy", note: "Steep ground on PAD-US 'Open access' land. Trails may not reach it." },
      { name: "Mineralogy from spectra", status: "not measured", note: "No orbital or field spectra are used." },
      { name: "Outcrop-scale sedimentary structures", status: "not measured", note: "No field observation is part of the loaded results." },
      { name: "Water or ice resources, base suitability", status: "not measured", note: "Out of scope. Fossil mudcracks record an ancient lake drying; they are not present-day water." },
    ],
    notEstablished: [
      "This pathway searched two regions only (Newark basin and the held-out Hartford basin). It is not a global geological run.",
      "A qualifying unit is a mapped unit whose recorded properties meet the reference's required properties. It is not a verified field site.",
      "Age, basin setting, fluid chemistry and burial history differ from Mars and are listed as not comparable.",
    ],
    context: [{ label: "NASA Moon to Mars Architecture", url: "https://www.nasa.gov/architecture/" }],
  },
];
