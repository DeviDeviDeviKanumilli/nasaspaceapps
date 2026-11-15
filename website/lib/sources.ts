// Central dataset and software catalogue. Every URL here was opened and resolved on 2026-11-15 (publisher pages that
// block automated checks resolve through their DOI). "usedFor" states the dataset's role in the loaded run.

export type SourceRole = "analysis input" | "planetary reference" | "corroboration" | "field proxy" | "independent cross-check" | "display only" | "software";

export interface SourceEntry {
  key: string;
  name: string;
  provider: string;
  product: string;
  role: SourceRole;
  usedFor: string;
  resolution: string;
  license: string;
  url: string;
  urlLabel: string;
  citation?: string;
  citationUrl?: string;
  pathways: ("terrain" | "rock" | "geo2" | "display")[];
  nasa?: boolean;
}

export const SOURCES: SourceEntry[] = [
  {
    key: "cop-dem",
    name: "Copernicus DEM GLO-90",
    provider: "European Space Agency / Copernicus (Airbus)",
    product: "Copernicus DSM COG, 3 arc-second (GLO-90), s3://copernicus-dem-90m, release as served on the run date",
    role: "analysis input",
    usedFor: "Earth elevation for every terrain window: resampled to a 100 m grid, then plane-fit slope and roughness at 400, 800, 1600 and 3200 m.",
    resolution: "~90 m posting; analysed at 100 m",
    license: "Free and open under the Copernicus DEM licence; attribution: © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018, provided under COPERNICUS by the European Union and ESA; all rights reserved.",
    url: "https://registry.opendata.aws/copernicus-dem/",
    urlLabel: "AWS Open Data registry entry",
    citation: "European Space Agency (2024). Copernicus Global Digital Elevation Model. doi:10.5270/ESA-c5d3d65",
    citationUrl: "https://doi.org/10.5270/ESA-c5d3d65",
    pathways: ["terrain"],
  },
  {
    key: "worldcover",
    name: "ESA WorldCover 2021 v200",
    provider: "European Space Agency",
    product: "WorldCover 10 m 2021 v200, s3://esa-worldcover/v200/2021/map, read at the 20 m overview",
    role: "analysis input",
    usedFor: "Land-cover mask (tree, crop, built-up, water, wetland and mangrove cells are excluded), bare-ground fraction and snow/ice fraction of each window.",
    resolution: "10 m product, 20 m overview used",
    license: "CC BY 4.0. © ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium.",
    url: "https://esa-worldcover.org/en",
    urlLabel: "ESA WorldCover",
    citation: "Zanaga, D. et al. (2022). ESA WorldCover 10 m 2021 v200. doi:10.5281/zenodo.7254221",
    citationUrl: "https://doi.org/10.5281/zenodo.7254221",
    pathways: ["terrain", "rock"],
  },
  {
    key: "lola",
    name: "LOLA south-pole elevation model, 20 m/pixel",
    provider: "NASA Goddard Space Flight Center, Planetary Geodesy Data Archive (PGDA)",
    product: "LDEM_80S_20MPP_ADJ (PGDA product 90); site outlines from PGDA product 78",
    role: "planetary reference",
    usedFor: "Slope and roughness distributions of the four lunar south-pole reference sites (M-CR, M-SR, M-DG, M-MA) and the pooled MZ-FLAT and MZ-STEEP zone classes.",
    resolution: "20 m/pixel; aggregated to 100 m for comparison with Earth",
    license: "NASA data, public domain; cite the product authors.",
    url: "https://pgda.gsfc.nasa.gov/products/90",
    urlLabel: "PGDA product 90",
    citation: "Barker, M.K. et al. (2021). Improved LOLA elevation maps for south pole landing sites. Planetary and Space Science 203, 105119. doi:10.1016/j.pss.2020.105119",
    citationUrl: "https://doi.org/10.1016/j.pss.2020.105119",
    pathways: ["terrain"],
    nasa: true,
  },
  {
    key: "pgda78",
    name: "Lunar south-pole site outlines",
    provider: "NASA Goddard Space Flight Center, PGDA",
    product: "PGDA product 78 (high-resolution LOLA topography for lunar south-pole sites)",
    role: "planetary reference",
    usedFor: "Boundaries of the lunar reference sites (Site01 Connecting Ridge, Site04 Shackleton rim, Site11 de Gerlache rim, Site23 Malapert massif).",
    resolution: "site boxes of a few km to tens of km",
    license: "NASA data, public domain.",
    url: "https://pgda.gsfc.nasa.gov/products/78",
    urlLabel: "PGDA product 78",
    pathways: ["terrain"],
    nasa: true,
  },
  {
    key: "mars-dem",
    name: "Mars MGS MOLA – MEX HRSC blended DEM, 200 m, v2",
    provider: "USGS Astrogeology Science Center (NASA MGS MOLA and ESA Mars Express HRSC data)",
    product: "Mars_HRSC_MOLA_BlendDEM_Global_200mp_v2",
    role: "planetary reference",
    usedFor: "Slope and roughness distributions of the Mars reference boxes R-JZ (Jezero crater) and R-IS (InSight landing site), at 1600 and 3200 m baselines only.",
    resolution: "200 m/pixel",
    license: "Public domain (USGS Astrogeology); cite the product authors.",
    url: "https://astrogeology.usgs.gov/search/map/mars_mgs_mola_mex_hrsc_blended_dem_global_200m",
    urlLabel: "USGS Astrogeology product page",
    citation: "Fergason, R.L., Hare, T.M. & Laura, J. (2018). HRSC and MOLA Blended Digital Elevation Model at 200 m v2. USGS Astrogeology PDS Annex.",
    pathways: ["terrain"],
    nasa: true,
  },
  {
    key: "glim",
    name: "Global Lithological Map (GLiM)",
    provider: "Hartmann & Moosdorf, Universität Hamburg",
    product: "GLiM v1.0, rasterised by this project at 0.01°",
    role: "analysis input",
    usedFor: "Rock-type screening pathway: share of each 0.1° box mapped as the target rock class, and the co-located partner class.",
    resolution: "source maps about 1:1,000,000 to 1:5,000,000; 0.01° raster (~1 km)",
    license: "CC BY 3.0 (PANGAEA).",
    url: "https://doi.org/10.1594/PANGAEA.788537",
    urlLabel: "PANGAEA data record",
    citation: "Hartmann, J. & Moosdorf, N. (2012). The new global lithological map database GLiM. Geochemistry, Geophysics, Geosystems 13, Q12004. doi:10.1029/2012GC004370",
    citationUrl: "https://doi.org/10.1029/2012GC004370",
    pathways: ["rock"],
  },
  {
    key: "sgmc",
    name: "USGS State Geologic Map Compilation (SGMC) v1.1",
    provider: "U.S. Geological Survey",
    product: "SGMC geodatabase v1.1: unit polygons, unit descriptions, structured lithology, ages, source references",
    role: "analysis input",
    usedFor: "geo-2.0 regional geology: mapped lithology (major/minor), unit-description evidence, unit age, neighbour and intrusive-contact relationships, map scale.",
    resolution: "source maps 1:100,000 to 1:250,000 in the two study regions",
    license: "Public domain (USGS).",
    url: "https://doi.org/10.3133/ds1052",
    urlLabel: "USGS Data Series 1052",
    citation: "Horton, J.D., San Juan, C.A. & Stoeser, D.B. (2017). The State Geologic Map Compilation (SGMC) geodatabase of the conterminous United States. USGS Data Series 1052. doi:10.3133/ds1052",
    citationUrl: "https://doi.org/10.3133/ds1052",
    pathways: ["geo2"],
  },
  {
    key: "macrostrat",
    name: "Macrostrat API v2",
    provider: "Macrostrat, University of Wisconsin–Madison",
    product: "Stratigraphic units by name, accepted only within 150 km of the map unit and with overlapping age",
    role: "corroboration",
    usedFor: "Second source for lithology and depositional environment in geo-2.0. It can corroborate a map-derived property but never establishes one alone; entries marked 'inferred' are database defaults and are not used.",
    resolution: "stratigraphic columns (regional)",
    license: "CC BY 4.0.",
    url: "https://macrostrat.org/api/v2",
    urlLabel: "Macrostrat API",
    pathways: ["geo2", "rock"],
  },
  {
    key: "3dep",
    name: "USGS 3D Elevation Program (3DEP) 1/3 arc-second DEM",
    provider: "U.S. Geological Survey",
    product: "3DEP 1/3 arc-second seamless DEM, read at a ~20 m overview",
    role: "field proxy",
    usedFor: "geo-2.0 exposure proxy: ground steeper than 25° inside a mapped unit. A proxy for possible outcrop, not confirmed rock.",
    resolution: "~10 m product, ~20 m overview used",
    license: "Public domain (USGS).",
    url: "https://www.usgs.gov/3d-elevation-program",
    urlLabel: "USGS 3DEP",
    pathways: ["geo2"],
  },
  {
    key: "padus",
    name: "USGS PAD-US Public Access layer",
    provider: "U.S. Geological Survey, Gap Analysis Project",
    product: "PADUS_Public_Access feature service, 'Open access' areas only",
    role: "field proxy",
    usedFor: "geo-2.0 access proxy: whether steep ground lies on land recorded as open to the public. Trails may not reach those cells.",
    resolution: "parcel polygons",
    license: "Public domain (USGS).",
    url: "https://services.arcgis.com/v01gqwM5QqNysAAi/arcgis/rest/services/PADUS_Public_Access/FeatureServer/0",
    urlLabel: "Feature service queried by the engine",
    pathways: ["geo2"],
  },
  {
    key: "sourland-guide",
    name: "Sourland Conservancy, Sourland Geology Hike (revised guide)",
    provider: "Sourland Conservancy",
    product: "Published trail guide describing Lockatong argillite with fossil mudcracks on the Ridge Trail",
    role: "independent cross-check",
    usedFor: "Cross-check only: the guide was not an input. The engine's selection of the Lockatong unit inside Sourland Mountain Preserve was compared with it afterwards. Stop coordinates are not verified by this project.",
    resolution: "trail-stop descriptions",
    license: "Cited as a published document; not redistributed.",
    url: "",
    urlLabel: "",
    pathways: ["geo2"],
  },
  {
    key: "esri-imagery",
    name: "Esri World Imagery",
    provider: "Esri and its data contributors (credits shown on the map for the area in view)",
    product: "World_Imagery map service",
    role: "display only",
    usedFor: "Satellite and aerial base map on the globe. It is not an input to any analysis on this site.",
    resolution: "varies by place (sub-metre to 15 m)",
    license: "Esri Master Agreement / World Imagery terms of use; attribution shown on the map.",
    url: "https://www.arcgis.com/home/item.html?id=10df2279f9684e4a9f6a7f08febac2a9",
    urlLabel: "World Imagery item page",
    pathways: ["display"],
  },
  {
    key: "esri-terrain",
    name: "Esri World Elevation (Terrain 3D)",
    provider: "Esri and its data contributors",
    product: "WorldElevation3D/Terrain3D image service",
    role: "display only",
    usedFor: "3D relief of the globe when tilting the view. It is not the DEM used for the terrain measurements (that is Copernicus GLO-90).",
    resolution: "varies by place",
    license: "Esri terms of use; attribution shown on the map.",
    url: "https://elevation3d.arcgis.com/arcgis/rest/services/WorldElevation3D/Terrain3D/ImageServer",
    urlLabel: "Service endpoint",
    pathways: ["display"],
  },
  {
    key: "gibs",
    name: "NASA GIBS Blue Marble",
    provider: "NASA Earth Science Data and Information System (ESDIS), Global Imagery Browse Services",
    product: "BlueMarble_ShadedRelief_Bathymetry, 500 m",
    role: "display only",
    usedFor: "Alternative base map, and the automatic fallback when the high-resolution imagery service cannot be reached.",
    resolution: "500 m",
    license: "NASA imagery, free to use; acknowledge NASA GIBS.",
    url: "https://nasa-gibs.github.io/gibs-api-docs/",
    urlLabel: "GIBS API documentation",
    pathways: ["display"],
    nasa: true,
  },
  {
    key: "nominatim",
    name: "OpenStreetMap Nominatim",
    provider: "OpenStreetMap Foundation and contributors",
    product: "Nominatim search API",
    role: "display only",
    usedFor: "Place-name search (one request per submitted search). Coordinates typed directly never leave the browser.",
    resolution: "n/a",
    license: "Data © OpenStreetMap contributors, ODbL 1.0.",
    url: "https://www.openstreetmap.org/copyright",
    urlLabel: "OpenStreetMap copyright",
    pathways: ["display"],
  },
  {
    key: "cesium",
    name: "CesiumJS",
    provider: "Cesium GS, Inc. and contributors",
    product: "CesiumJS open-source 3D globe engine",
    role: "software",
    usedFor: "Globe rendering, camera, terrain and imagery streaming.",
    resolution: "n/a",
    license: "Apache 2.0.",
    url: "https://cesium.com/platform/cesiumjs/",
    urlLabel: "CesiumJS",
    pathways: ["display"],
  },
];

export const SOURCE_BY_KEY = new Map(SOURCES.map((s) => [s.key, s]));

export const REPO_URL = "https://github.com/DeviDeviDeviKanumilli/nasaspaceapps";

/** Extracts a DOI link from a citation string such as "... doi:10.1126/science.1242777". */
export function doiUrl(citation: string): string | null {
  const m = /doi:\s*(10\.\d{4,9}\/[^\s]+)/i.exec(citation);
  return m ? `https://doi.org/${m[1].replace(/[.,;]$/, "")}` : null;
}

/** Engine source: lat/lon of the Mars reference boxes (engine/build_refs.py). Lunar sites are PGDA outlines near the south pole. */
export const REFERENCE_LOCATIONS: Record<string, { body: string; text: string; source: string }> = {
  "R-JZ": { body: "Mars", text: "1° box centred 18.44° N, 77.45° E (Jezero crater)", source: "engine/build_refs.py" },
  "R-IS": { body: "Mars", text: "1° box centred 4.502° N, 135.623° E (InSight landing site, Elysium Planitia)", source: "engine/build_refs.py" },
  "M-CR": { body: "Moon", text: "PGDA Site01 outline, lunar south-pole region (Connecting Ridge)", source: "PGDA product 78" },
  "M-SR": { body: "Moon", text: "PGDA Site04 outline, lunar south-pole region (Shackleton rim)", source: "PGDA product 78" },
  "M-DG": { body: "Moon", text: "PGDA Site11 outline, lunar south-pole region (de Gerlache rim)", source: "PGDA product 78" },
  "M-MA": { body: "Moon", text: "PGDA Site23 outline, lunar south-pole region (Malapert massif)", source: "PGDA product 78" },
  "MZ-FLAT": { body: "Moon", text: "Pooled 10 km windows from the four PGDA sites where at least 60% of 400 m slopes are 10° or less", source: "engine/build_zone_refs.py" },
  "MZ-STEEP": { body: "Moon", text: "Pooled 10 km windows from the four PGDA sites where at least 40% of 400 m slopes are 15–30°", source: "engine/build_zone_refs.py" },
};

export const GLIM_CLASSES: Record<string, string> = {
  su: "unconsolidated sediments", ss: "siliciclastic sedimentary", sm: "mixed sedimentary", sc: "carbonate sedimentary", py: "pyroclastics",
  ev: "evaporites", mt: "metamorphics", pa: "acid plutonic", pi: "intermediate plutonic", pb: "basic plutonic", va: "acid volcanic",
  vi: "intermediate volcanic", vb: "basic volcanic", ig: "ice and glaciers", wb: "water bodies", nd: "no data",
};
