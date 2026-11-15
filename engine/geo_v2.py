"""Process-aware geological evidence engine (geo-2.0) — 14/15 Nov 2026.

What is new compared with the v0.3 rock-type pathway (keyword / class lookup):
  1. Planetary references are structured lists of OBSERVED or INTERPRETED properties from published
     rover/orbital studies (each with source and evidence type). The Earth search investigates exactly
     those properties; nothing else is compared.
  2. Earth evidence is extracted per map unit into separate dimensions with a controlled vocabulary:
     lithology (from the STRUCTURED lithology hierarchy of the USGS State Geologic Map Compilation,
     ranked major/minor), emplacement (volcanic vs intrusive, from the lithology hierarchy and text),
     depositional environment, sedimentary structures, minerals and alteration (from the state-survey
     unit descriptions, with negation guards). Every hit keeps its source field and the matched text.
  3. Independent corroboration from Macrostrat stratigraphic columns (lithology and depositional
     environment). Source disagreements are recorded, and database defaults ("inferred ...") are not
     treated as observations.
  4. Measured spatial context from the map polygons: perimeter shared with lava flows, intrusions,
     marine units; area within 500 m of an intrusive contact (thermal overprint risk).
  5. A candidate must show every CORE property of the reference and no CORE contradiction; all other
     properties are reported individually as recorded / corroborated / contradicted / not recorded.
     No scores, weights or percentages.
  6. Source scale -> positional uncertainty of mapped contacts.
No LLM is involved at run time: interpretations come only from the rules below.
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import re, json, math
from functools import lru_cache

# ---------------------------------------------------------------- controlled vocabulary
NEG = re.compile(r"\b(no|not|without|absent|lacking|lacks|rare|unlike)\b[^.;]{0,30}$", re.I)

TEXT_VOCAB = {
    # dimension: {code: regex}
    "environment": {
        "LACUSTRINE": r"lacustrine|\bplaya\b|lake[- ](deposits?|beds?|sediments?|sequences?|cycles?|mudflat|level)|deposited in (an? |the )?(\w+ )?lakes?\b",
        "FLUVIAL": r"\bfluvial|alluvial|braided|meandering|channel[- ]?fill|stream[- ]deposit",
        "DELTAIC": r"\bdelta(ic)?\b",
        "MARINE": r"(?<!non-)(?<!non )(?<!non)\bmarine\b|turbidite|\bshelf\b|glauconit|\bforaminifer|\bshallow[- ]sea|\bnearshore|\boffshore",
        "EOLIAN": r"eolian|aeolian|wind[- ]blown|\bdunes?\b",
        "GLACIAL": r"glacial|\btill\b|outwash|moraine|varve",
    },
    "emplacement": {
        "EXTRUSIVE": r"\blava|\bflows?\b|pillow|vesicul|amygdal|pahoehoe|extrusive",
        "INTRUSIVE": r"\bsill\b|\bdikes?\b|\bdykes?\b|intrusi(ve|on)|pluton",
    },
    "structure": {
        "DESICCATION": r"mud[- ]?cracks?|desiccation|shrinkage cracks",
        "CYCLIC": r"\bcycl(ic|es?)\b|rhythmic|van houten",
        "LAMINATED": r"laminat|varve",
        "PILLOWS": r"pillow",
        "RIPPLES": r"ripple",
        "DARK_LAMINATED": r"microlaminat|black[^.;]{0,60}(laminat|shale|siltstone|mudstone|argillite)",
        "AQUATIC_FOSSILS": r"\bfish\b|ostracod|conchostracan|clam shrimp",
    },
    "mineral": {
        "CARBONATE": r"dolomit|calcite|calcare|carbonate|magnesite",
        "EVAPORITE": r"evaporit|gypsum|anhydrite|glauberite|halite|salt[- ]crystal|pseudomorph",
        "CLAY": r"\bclay|smectite|illite|kaolin",
        "ANALCIME": r"analcime|zeolite",
        "SERPENTINE": r"serpentin|antigorite|chrysotile",
        "OLIVINE": r"olivine|dunite|peridotite|harzburgite",
        "MAGNETITE": r"magnetite",
    },
    "alteration": {
        "SERPENTINIZATION": r"serpentiniz|alteration of peridotite|altered (dunite|peridotite)|products of alteration",
        "CONTACT_METAMORPHISM": r"hornfels|baked|contact[- ]metamorph|thermally metamorphos",
        "HYDROTHERMAL": r"hydrothermal",
    },
}

LITH_RULES = [  # (code, test on the structured TOTAL_LITH hierarchy string)
    ("FINE_CLASTIC", lambda t: re.search(r"Mudstone|Shale|Siltstone|Argillite|Claystone|Fine-detrital|\bClay\b|\bSilt\b", t)),
    ("COARSE_CLASTIC", lambda t: re.search(r"Sandstone|Conglomerate|Arkose|Coarse-detrital|\bSand\b|Gravel", t)),
    ("CARBONATE_ROCK", lambda t: re.search(r"Carbonate|Limestone|Dolostone|Marble", t)),
    ("EVAPORITE_ROCK", lambda t: re.search(r"Evaporite", t)),
    ("MAFIC_VOLCANIC", lambda t: re.search(r"Igneous - Volcanic - Mafic|Basalt", t) and "Plutonic" not in t and "Hypabyssal" not in t),
    ("MAFIC_INTRUSIVE", lambda t: re.search(r"Gabbro|Diabase|Dolerite|Norite|Igneous - Hypabyssal - Mafic|Igneous - Plutonic - Gabbroic", t)),
    ("ULTRAMAFIC", lambda t: re.search(r"Ultramafic|Serpentinite|Peridotite|Dunite|Pyroxenite|Metaultramafic", t)),
    ("OLIVINE_RICH_ULTRAMAFIC", lambda t: re.search(r"Serpentinite|Peridotite|Dunite|Harzburgite|Wehrlite", t)),
]

# ---------------------------------------------------------------- planetary references (published observations)
SRC = {
    "Grotzinger2014": "Grotzinger J.P. et al. (2014) A habitable fluvio-lacustrine environment at Yellowknife Bay, Gale crater, Mars. Science 343, 1242777. doi:10.1126/science.1242777",
    "Grotzinger2015": "Grotzinger J.P. et al. (2015) Deposition, exhumation, and paleoclimate of an ancient lake deposit, Gale crater, Mars. Science 350, aac7575. doi:10.1126/science.aac7575",
    "Vaniman2014": "Vaniman D.T. et al. (2014) Mineralogy of a mudstone at Yellowknife Bay, Gale crater, Mars. Science 343, 1243480. doi:10.1126/science.1243480",
    "Stein2018": "Stein N. et al. (2018) Desiccation cracks provide evidence of lake drying on Mars, Sutton Island member, Murray formation, Gale crater. Geology 46, 515-518. doi:10.1130/G40005.1",
    "Rapin2023": "Rapin W. et al. (2023) Sustained wet-dry cycling on early Mars. Nature 620, 299-302. doi:10.1038/s41586-023-06220-3",
    "Nachon2014": "Nachon M. et al. (2014) Calcium sulfate veins characterized by ChemCam/Curiosity at Gale crater, Mars. JGR Planets 119, 1991-2016.",
    "Mangold2021": "Mangold N. et al. (2021) Perseverance rover reveals an ancient delta-lake system and flood deposits at Jezero crater, Mars. Science 374, 711-717. doi:10.1126/science.abl4051",
    "Farley2022": "Farley K.A. et al. (2022) Aqueously altered igneous rocks sampled on the floor of Jezero crater, Mars. Science 377, eabo2196. doi:10.1126/science.abo2196",
    "Liu2022": "Liu Y. et al. (2022) An olivine cumulate outcrop on the floor of Jezero crater, Mars. Science 377, 1513-1519. doi:10.1126/science.abo2756",
    "Tosca2025": "Tosca N.J. et al. (2025) In situ evidence for serpentinization within the Maaz formation, Jezero crater, Mars. Science Advances 11, eadr8793. doi:10.1126/sciadv.adr8793",
    "Beyssac2023": "Beyssac O. et al. (2023) Petrological traverse of the olivine cumulate Seitah formation at Jezero crater, Mars. JGR Planets 128, e2022JE007638. doi:10.1029/2022JE007638",
    "Tutolo2023": "Tutolo B.M. & Tosca N.J. (2023) Observational constraints on the process and products of Martian serpentinization. Science Advances 9, eadd8472. doi:10.1126/sciadv.add8472",
    "Clave2023": "Clave E. et al. (2023) Carbonate detection with SuperCam in igneous rocks on the floor of Jezero crater, Mars. JGR Planets 128, e2022JE007463. doi:10.1029/2022JE007463",
    "Golombek2020": "Golombek M. et al. (2020) Geology of the InSight landing site on Mars. Nature Communications 11, 1014. doi:10.1038/s41467-020-14679-1",
}

# role: core (must be recorded on Earth) | supporting | contradiction (core counter-evidence) | caution (flag only)
# evidence_type: observed (rover/orbiter measurement) | interpreted (published interpretation of observations)
#                | inferred (a consequence derived from an interpretation, not measured, e.g. H2 production)
# site: the Mars location an observation comes from, when a reference combines more than one
PLANETARY = {
    "MARS-LAKE": dict(
        name="Martian crater-lake mudstones (Gale crater; Jezero crater delta-lake system)",
        location=[dict(site="Gale crater, Murray formation / Yellowknife Bay", lat=-4.6, lon=137.4),
                  dict(site="Jezero crater western delta", lat=18.4, lon=77.4)],
        properties=[
            dict(dim="lithology", code="FINE_CLASTIC", role="core", evidence_type="observed", src=["Grotzinger2014", "Grotzinger2015"],
                 statement="fine-grained mudstone and siltstone"),
            dict(dim="environment", code="LACUSTRINE", role="core", evidence_type="interpreted", src=["Grotzinger2014", "Grotzinger2015", "Mangold2021"],
                 statement="deposited in long-lived crater lakes"),
            dict(dim="environment", code="MARINE", role="contradiction", evidence_type="interpreted", src=["Grotzinger2015"],
                 statement="no ocean-margin setting in these crater lakes: marine deposits are a different process"),
            dict(dim="structure", code="DESICCATION", role="supporting", evidence_type="observed", src=["Stein2018"],
                 statement="desiccation cracks recording lake drying"),
            dict(dim="structure", code="CYCLIC", role="supporting", evidence_type="observed", src=["Rapin2023"],
                 statement="repeated wet-dry cycles (polygonal salt-enriched patterns)"),
            dict(dim="structure", code="LAMINATED", role="supporting", evidence_type="observed", src=["Grotzinger2015"],
                 statement="finely laminated mudstone"),
            dict(dim="mineral", code="CLAY", role="supporting", evidence_type="observed", src=["Vaniman2014"],
                 statement="clay minerals (smectite) in mudstone (CheMin XRD)"),
            dict(dim="mineral", code="EVAPORITE", role="supporting", evidence_type="observed", src=["Nachon2014"],
                 statement="calcium-sulfate veins (later diagenetic, not primary lake salts)"),
            dict(dim="context", code="VOLCANIC_NEIGHBOUR", role="supporting", evidence_type="observed", src=["Farley2022", "Mangold2021"],
                 statement="at Jezero the lake-delta deposits sit on igneous crater-floor units"),
            dict(dim="alteration", code="CONTACT_METAMORPHISM", role="caution", evidence_type="not_applicable", src=[],
                 statement="Earth-only check: heating by nearby intrusions changes mudstones; not reported at Gale/Jezero lake beds"),
        ],
        not_comparable=["age (~3.5-3.8 billion years)", "impact-crater basin setting", "Martian atmospheric and fluid chemistry",
                        "Fe-rich Martian mineral compositions", "burial and diagenesis history", "biology (Earth lake beds contain fossils)"]),
    "MARS-SERP": dict(
        name="Jezero crater floor: olivine cumulate (Seitah formation) and serpentinized igneous rock (Maaz formation)",
        location=[dict(site="Seitah formation, Jezero", lat=18.44, lon=77.45), dict(site="Maaz formation, Jezero", lat=18.44, lon=77.45)],
        site_note=("Two different Mars rocks. Seitah is an olivine cumulate, weakly altered, with small amounts of Mg-Fe carbonate. "
                   "The in situ serpentinization evidence (Tosca 2025) is from the overlying Maaz formation, a pyroxene-plagioclase igneous unit, "
                   "not from the Seitah cumulate. An Earth serpentinite combines the Seitah rock type with the Maaz process; "
                   "no single Mars site in these sources shows both."),
        properties=[
            dict(dim="lithology", code="OLIVINE_RICH_ULTRAMAFIC", role="core", evidence_type="observed", site="Seitah", src=["Liu2022", "Beyssac2023"],
                 statement="olivine cumulate (olivine-rich ultramafic rock); pyroxenite/hornblendite/gabbro are different rocks"),
            dict(dim="mineral", code="OLIVINE", role="supporting", evidence_type="observed", site="Seitah", src=["Liu2022", "Beyssac2023"],
                 statement="abundant millimetre olivine"),
            dict(dim="mineral", code="CARBONATE", role="supporting", evidence_type="observed", site="Seitah", src=["Clave2023"],
                 statement="Mg-Fe carbonate (magnesite-siderite), low abundance, detected with olivine"),
            dict(dim="mineral", code="SERPENTINE", role="supporting", evidence_type="observed", site="Maaz", src=["Tosca2025"],
                 statement="Fe-rich serpentine in Maaz igneous rocks (not in the Seitah cumulate)"),
            dict(dim="alteration", code="SERPENTINIZATION", role="supporting", evidence_type="interpreted", site="Maaz", src=["Tosca2025"],
                 statement="serpentinization of olivine in Maaz rocks, interpreted from in situ mineralogy and chemistry"),
            dict(dim="process", code="H2_PRODUCTION", role="not_compared", evidence_type="inferred", site="Maaz", src=["Tosca2025", "Tutolo2023"],
                 statement="hydrogen production is inferred from the serpentinization reaction; it was not measured"),
        ],
        not_comparable=["Fe-rich (Mars) vs Mg-rich (Earth mantle) olivine and serpentine: Fe-olivine yields Fe-serpentine and about five times "
                        "more H2 than terrestrial peridotite (Tutolo2023)", "tectonic setting (Earth: mountain belt)",
                        "age and fluid chemistry", "humid weathering and vegetation on Earth"]),
    "MARS-LAVA": dict(
        name="Basaltic lava plains and crater-floor lavas (InSight landing site; Jezero Maaz formation)",
        location=[dict(site="InSight, Elysium Planitia", lat=4.502, lon=135.623), dict(site="Jezero Maaz formation", lat=18.44, lon=77.45)],
        properties=[
            dict(dim="lithology", code="MAFIC_VOLCANIC", role="core", evidence_type="observed", src=["Farley2022", "Golombek2020"],
                 statement="basaltic igneous rock"),
            dict(dim="emplacement", code="EXTRUSIVE", role="core", evidence_type="interpreted", src=["Golombek2020", "Farley2022"],
                 statement="erupted as lava flows at the surface"),
            dict(dim="emplacement", code="INTRUSIVE", role="contradiction", evidence_type="interpreted", src=["Golombek2020"],
                 statement="an intrusion (sill/dike) cooled underground: a different emplacement process"),
            dict(dim="structure", code="PILLOWS", role="earth_only", evidence_type="not_applicable", src=[],
                 statement="Earth-side indicator of lava meeting water (relevant to Jezero's later lake); not observed on Mars"),
            dict(dim="context", code="LAKE_NEIGHBOUR", role="supporting", evidence_type="observed", src=["Mangold2021"],
                 statement="at Jezero, lake-delta sediments overlie the crater-floor igneous units"),
        ],
        not_comparable=["regolith and dust cover", "impact gardening", "age", "Martian basalt chemistry"]),
}


def text_hits(text, field):
    """Controlled-vocabulary hits with negation guard. Returns list of (dim, code, field, snippet)."""
    out = []
    if not text:
        return out
    for dim, voc in TEXT_VOCAB.items():
        for code, rx in voc.items():
            for m in re.finditer(rx, text, re.I):
                pre = text[max(0, m.start() - 40):m.start()]
                if NEG.search(pre):
                    continue
                out.append((dim, code, field, text[max(0, m.start() - 50):m.end() + 50].replace("\n", " ")))
                break
    return out


def lith_codes(lith_rows):
    """lith_rows: list of (rank, total_lith). Returns {code: 'major'|'minor'}."""
    out = {}
    for rank, t in lith_rows:
        for code, f in LITH_RULES:
            if t and f(t):
                r = "major" if "major" in str(rank).lower() else "minor"   # includes "Indeterminate, major"
                if out.get(code) != "major":
                    out[code] = r
    return out


def scale_from_reference(ref):
    m = re.search(r"1:\s*([\d,]{4,})", ref or "")
    return int(m.group(1).replace(",", "")) if m else None


# ---------------------------------------------------------------- Macrostrat corroboration
@lru_cache(maxsize=None)
def macrostrat(name):
    """Name query only. Returns every Macrostrat unit with this stratigraphic name, with its column position and age,
    so that the caller can reject homonyms far away or of a different age (see macrostrat_match)."""
    import requests
    base = re.sub(r"\b(Formation|Fm|Group|Member|Basalt|undivided)\b.*$", "", name or "").strip(" ,-")
    if not base or len(base) < 4:
        return None
    try:
        d = requests.get("https://macrostrat.org/api/v2/units", params=dict(strat_name=base, response="long"), timeout=40).json()["success"]["data"]
    except Exception:
        return None
    units = [dict(col_id=u.get("col_id"), strat_name=u.get("strat_name_long"), clat=u.get("clat"), clng=u.get("clng"),
                  t_age=u.get("t_age"), b_age=u.get("b_age"), lith=sorted({l["name"] for l in u.get("lith", [])}),
                  environ=sorted({e["name"] for e in u.get("environ", []) if not e["name"].startswith("inferred")}),
                  environ_database_default=sorted({e["name"] for e in u.get("environ", []) if e["name"].startswith("inferred")}))
             for u in d]
    return dict(query=base, units=units)


# geologic time names -> (young, old) Ma, ICS 2023 boundaries (rounded); used only for an age-overlap check
PERIODS = [("Quaternary", 0, 2.6), ("Tertiary", 2.6, 66), ("Neogene", 2.6, 23), ("Paleogene", 23, 66), ("Cenozoic", 0, 66),
           ("Cretaceous", 66, 145), ("Jurassic", 145, 201.4), ("Triassic", 201.4, 251.9), ("Mesozoic", 66, 251.9),
           ("Permian", 251.9, 298.9), ("Pennsylvanian", 298.9, 323.2), ("Mississippian", 323.2, 358.9), ("Carboniferous", 298.9, 358.9),
           ("Devonian", 358.9, 419.2), ("Silurian", 419.2, 443.8), ("Ordovician", 443.8, 485.4), ("Cambrian", 485.4, 538.8),
           ("Paleozoic", 251.9, 538.8), ("Neoproterozoic", 538.8, 1000), ("Mesoproterozoic", 1000, 1600), ("Paleoproterozoic", 1600, 2500),
           ("Proterozoic", 538.8, 2500), ("Precambrian", 538.8, 4000), ("Archean", 2500, 4000)]


def age_range(unit_age):
    hits = [(y, o) for n, y, o in PERIODS if re.search(n, unit_age or "", re.I)]
    return (min(h[0] for h in hits), max(h[1] for h in hits)) if hits else None


def macrostrat_match(ms, lat=None, lon=None, unit_age=None, max_km=150.0, age_tol_ma=10.0):
    """Keep only Macrostrat units whose column lies within max_km of the map unit AND whose age overlaps the map unit's age.
    Without a location, nothing is accepted (an unconstrained name match is never used as evidence)."""
    if not ms or not ms.get("units"):
        return dict(query=ms and ms.get("query"), name_matches=0, accepted=[], rejected=[])
    ar = age_range(unit_age); acc, rej = [], []
    for u in ms["units"]:
        why = []
        if lat is None or u["clat"] is None:
            why.append("no location to check")
        else:
            km = 6371 * math.acos(min(1, math.sin(math.radians(lat)) * math.sin(math.radians(u["clat"])) +
                                      math.cos(math.radians(lat)) * math.cos(math.radians(u["clat"])) * math.cos(math.radians(lon - u["clng"]))))
            if km > max_km:
                why.append(f"column {km:.0f} km away")
        if ar and u["t_age"] is not None and not (u["t_age"] <= ar[1] + age_tol_ma and u["b_age"] >= ar[0] - age_tol_ma):
            why.append(f"age {u['t_age']:.0f}-{u['b_age']:.0f} Ma outside map age {ar[0]:.0f}-{ar[1]:.0f} Ma")
        (rej if why else acc).append(dict(col_id=u["col_id"], strat_name=u["strat_name"], **({"reason": "; ".join(why)} if why else {})))
    keep = [u for u in ms["units"] if any(a["col_id"] == u["col_id"] and a["strat_name"] == u["strat_name"] for a in acc)]
    return dict(query=ms["query"], name_matches=len(ms["units"]), age_checked=ar is not None, accepted=acc, rejected=rej,
                lith=sorted({l for u in keep for l in u["lith"]}), environ=sorted({e for u in keep for e in u["environ"]}),
                environ_database_default=sorted({e for u in keep for e in u["environ_database_default"]}))


MS_ENV = {"LACUSTRINE": r"lacustrine|lake|playa", "FLUVIAL": r"fluvial|alluvial", "MARINE": r"(?<!non-)(?<!non )(?<!non)marine|offshore|shelf|subtidal|lagoon|shoreface",
          "DELTAIC": r"delta", "EOLIAN": r"eolian|dune", "GLACIAL": r"glacial"}
MS_LITH = {"FINE_CLASTIC": r"mudstone|shale|siltstone|argillite|claystone|^clay$|^silt$", "MAFIC_VOLCANIC": r"basalt",
           "ULTRAMAFIC": r"serpentinite|peridotite|dunite|ultramafic", "MAFIC_INTRUSIVE": r"gabbro|diabase|dolerite"}


def evidence_profile(unit_name, unitdesc, lith_com, lith_rows, reference, use_macrostrat=True, location=None, unit_age=None):
    """All evidence for one map unit, with provenance. Pure function of the inputs (plus Macrostrat)."""
    prof = dict(lithology={}, environment={}, emplacement={}, structure={}, mineral={}, alteration={}, conflicts=[], traces=[],
                macrostrat_only={})
    for code, rank in lith_codes(lith_rows).items():
        prof["lithology"][code] = dict(source="SGMC structured lithology", rank=rank)
    if "EVAPORITE_ROCK" in prof["lithology"]:
        prof["mineral"].setdefault("EVAPORITE", dict(source="SGMC structured lithology (Evaporite)"))
    alltext = " ".join(filter(None, [unit_name, unitdesc, lith_com]))
    name_is_pyx = bool(re.search(r"pyroxenite|hornblendite", unit_name or "", re.I)) and not re.search(r"serpentin|peridot|dunite", unit_name or "", re.I)
    if "ULTRAMAFIC" in prof["lithology"] and "OLIVINE_RICH_ULTRAMAFIC" not in prof["lithology"] and not name_is_pyx and \
            re.search(r"serpentin|peridotite|dunite", alltext, re.I) and prof["lithology"]["ULTRAMAFIC"]["rank"] == "major":
        prof["lithology"]["OLIVINE_RICH_ULTRAMAFIC"] = dict(source="SGMC structured lithology (Ultramafic, major) + description names serpentinite/peridotite/dunite", rank="major")
    # emplacement from structured lithology
    if "MAFIC_VOLCANIC" in prof["lithology"]:
        prof["emplacement"]["EXTRUSIVE"] = dict(source="SGMC structured lithology (Igneous-Volcanic)")
    if "MAFIC_INTRUSIVE" in prof["lithology"] and "MAFIC_VOLCANIC" not in prof["lithology"]:
        prof["emplacement"]["INTRUSIVE"] = dict(source="SGMC structured lithology (Plutonic/Hypabyssal)")
    for field, text in (("unit description", unitdesc), ("lithology comment", lith_com), ("unit name", unit_name)):
        for dim, code, f, snip in text_hits(text, field):
            if code not in prof[dim]:
                prof[dim][code] = dict(source=f"SGMC {f}", text=snip)
            prof["traces"].append(dict(dim=dim, code=code, field=f, text=snip))
    # rock names that are intrusive by definition: judged from the UNIT NAME only (descriptions of thick lava flows
    # often say "grading to gabbro in the interior", which is not an intrusion)
    m = re.search(r"diabase|dolerite|gabbro|\bsills?\b|\bdikes?\b", unit_name or "", re.I)
    if m and "INTRUSIVE" not in prof["emplacement"]:
        prof["emplacement"]["INTRUSIVE"] = dict(source="SGMC unit name", text=unit_name)
    if "EXTRUSIVE" in prof["emplacement"] and "INTRUSIVE" in prof["emplacement"]:
        prof["conflicts"].append("structured lithology says volcanic, but the unit name/description indicates an intrusion "
                                 "(e.g. 'diabase', 'sill'); intrusive evidence is kept as a contradiction")
    ms = macrostrat_match(macrostrat(unit_name), *(location or (None, None)), unit_age=unit_age) if use_macrostrat else None
    prof["macrostrat"] = ms
    if ms and ms.get("accepted"):        # only geographically and stratigraphically matched units are used
        for code, rx in MS_ENV.items():
            if any(re.search(rx, e, re.I) for e in ms["environ"]):
                if code in prof["environment"]:
                    prof["environment"][code]["corroborated_by"] = "Macrostrat environ"
                else:   # Macrostrat alone never establishes a core property or a contradiction: kept apart, shown, not used
                    prof["macrostrat_only"].setdefault(code, dict(source="Macrostrat environ only (matched by name, place and age)"))
        for code, rx in MS_LITH.items():
            if any(re.search(rx, l, re.I) for l in ms["lith"]) and code in prof["lithology"]:
                prof["lithology"][code]["corroborated_by"] = "Macrostrat lith"
        if "LACUSTRINE" in prof["environment"] and any(re.search(MS_ENV["MARINE"], e, re.I) for e in ms.get("environ_database_default", [])):
            prof["conflicts"].append("Macrostrat database default environment 'inferred marine' disagrees with the state map; "
                                     "treated as a database default, not an observation")
        envs = [c for c in ("LACUSTRINE", "MARINE") if c in prof["environment"]]
        if len(envs) == 2:
            prof["conflicts"].append("both lacustrine and marine environments recorded")
    scale = scale_from_reference(reference)
    prof["source"] = dict(reference=reference, scale=scale,
                          contact_position_uncertainty_m=None if not scale else round(0.0005 * scale))
    return prof


def is_lava_unit(profile):
    """A lava-flow unit for neighbour context: volcanic lithology and NOT identified as an intrusion
    (SGMC codes Palisade Diabase as Volcanic-Basalt; its name identifies it as an intrusion)."""
    return "MAFIC_VOLCANIC" in profile["lithology"] and "INTRUSIVE" not in profile["emplacement"]


LAKE_FEATURES = [("structure", "DESICCATION"), ("structure", "CYCLIC"), ("structure", "DARK_LAMINATED"),
                 ("mineral", "EVAPORITE"), ("structure", "AQUATIC_FOSSILS")]


def infer_lacustrine(profile, context):
    """Process inference (not a keyword): a unit whose MAJOR lithology is fine-grained clastic (and not a major carbonate) with >= 2 independent standing-water /
    lake-drying indicators, no marine evidence, inside a continental basin context (shares a boundary with
    a mapped lake unit or with lava flows, or lies within 10 km of a mapped lake unit). Returns evidence or None."""
    if "LACUSTRINE" in profile["environment"] or "MARINE" in profile["environment"]:
        return None
    if profile["lithology"].get("FINE_CLASTIC", {}).get("rank") != "major":      # mudrock must be a major lithology
        return None
    if profile["lithology"].get("CARBONATE_ROCK", {}).get("rank") == "major":    # carbonate platforms (e.g. tidal-flat dolomite) excluded
        return None
    feats = [c for d, c in LAKE_FEATURES if profile[d].get(c)]
    basin = context.get("LAKE_NEIGHBOUR") or context.get("VOLCANIC_NEIGHBOUR") or context.get("within_10km_of_mapped_lake_unit")
    if len(feats) >= 2 and basin:
        return dict(source="inferred: sedimentology + basin context", indicators=feats,
                    basin_context=[k for k in ("LAKE_NEIGHBOUR", "VOLCANIC_NEIGHBOUR", "within_10km_of_mapped_lake_unit") if context.get(k)])
    return None


def compare(profile, context, ref_id):
    """Property-by-property comparison with a planetary reference. Returns (qualifies, rows)."""
    ref = PLANETARY[ref_id]; rows = []; core_ok = True; core_contra = False
    for p in ref["properties"]:
        if p["dim"] == "context":
            v = context.get(p["code"])
            status = "not computed" if v is None else ("recorded (measured spatial relationship)" if v else "not recorded")
            rows.append(dict(property=p["code"], dimension="context", role=p["role"], planetary=p["statement"],
                             planetary_evidence=p["evidence_type"], sources=p["src"], earth_status=status, earth_value=v))
            continue
        if p["role"] == "not_compared":
            rows.append(dict(property=p["code"], dimension=p["dim"], role=p["role"], planetary=p["statement"], site=p.get("site"),
                             planetary_evidence=p["evidence_type"], sources=p["src"], earth_status="not compared (no Earth map property)",
                             earth_evidence=None))
            continue
        e = profile[p["dim"]].get(p["code"])
        if p["role"] == "contradiction":
            status = "CONTRADICTION recorded" if e else "no contradiction recorded"
            core_contra |= bool(e)
        elif p["role"] == "caution":
            share = context.get("share_within_500m_of_intrusive_contact")
            status = ("recorded in map text" if e else "not in map text") + (f"; {share:.0%} of area within 500 m of an intrusive contact" if share is not None else "")
        else:
            if e:
                status = "corroborated (2 sources)" if e.get("corroborated_by") else f"recorded ({e['source']})"
            else:
                status = ("not recorded (Macrostrat alone lists it; not used)" if profile.get("macrostrat_only", {}).get(p["code"])
                          else "not recorded")
            if p["role"] == "core" and not e:
                core_ok = False
        rows.append(dict(property=p["code"], dimension=p["dim"], role=p["role"], planetary=p["statement"], site=p.get("site"),
                         planetary_evidence=p["evidence_type"], sources=p["src"], earth_status=status,
                         earth_evidence=e))
    return core_ok and not core_contra, rows


TEMPLATES = {
    "qualifies": "Meets every core property of {ref} ({cores}) with no core contradiction.",
    "fails_core": "Does not meet core properties of {ref}: missing {missing}.",
    "contradiction": "Core contradiction for {ref}: {contra}.",
}
