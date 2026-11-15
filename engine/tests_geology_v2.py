"""Unit tests for the geology engine geo-2.0 (geo_v2.py). Offline: Macrostrat is disabled.
Run:  python3 tests_geology_v2.py            (pure-function tests)
      python3 tests_geology_v2.py OUT.json   (also checks a regional_geology_v2 output file)
"""
import json
import sys

import geo_v2 as G

FAILS = []


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def prof(name, desc, rows, com=""):
    return G.evidence_profile(name, desc, com, rows, "Drake et al., 1996, 1:100,000", use_macrostrat=False)


# 1 negation guard: "no evidence of lake deposits" must not record LACUSTRINE
p = prof("Test Fm", "Red sandstone; no evidence of lacustrine deposition.", [("Major", "Sedimentary - Clastic - Sandstone")])
check("negation guard blocks 'no evidence of lacustrine'", "LACUSTRINE" not in p["environment"])
p = prof("Test Fm", "Black shale deposited in a lake; mudcracks.", [("Major", "Sedimentary - Clastic - Mudstone - Shale")])
check("positive lake text is recorded", "LACUSTRINE" in p["environment"])

# 2 intrusive vs extrusive on real SGMC wording
palisade = prof("Palisade Diabase", "Medium- to coarse-grained, dark-gray to grayish-black diabase.", [("Major", "Igneous - Volcanic - Mafic-volcanic - Basalt")])
check("Palisade Diabase (coded Volcanic-Basalt in SGMC) gets INTRUSIVE from its name", "INTRUSIVE" in palisade["emplacement"])
check("Palisade Diabase conflict is recorded", any("intrusion" in c for c in palisade["conflicts"]))
ok, _ = G.compare(palisade, {}, "MARS-LAVA")
check("Palisade Diabase does not qualify as MARS-LAVA", not ok)
holyoke = prof("Holyoke Basalt", "Greenish-gray to black, fine- to coarse-grained, grading from basalt near contacts to gabbro in the interior.",
               [("Major", "Igneous - Volcanic - Mafic-volcanic - Basalt")])
ok, _ = G.compare(holyoke, {}, "MARS-LAVA")
check("thick lava flow that mentions 'gabbro in the interior' still qualifies as MARS-LAVA", ok)
orange = prof("Orange Mountain Basalt", "Three major lava-flow sequences; lower flow pillowed.", [("Major", "Igneous - Volcanic - Mafic-volcanic - Basalt")])
ok, rows = G.compare(orange, {}, "MARS-LAVA")
check("Orange Mountain Basalt qualifies as MARS-LAVA", ok)
check("pillows recorded (Earth-only indicator, not counted as Mars support)",
      any(r["property"] == "PILLOWS" and r["role"] == "earth_only" and not r["earth_status"].startswith("not") for r in rows))

# 3 serpentinite vs pyroxenite
serp = prof("Serpentinite", "Chiefly serpentinite with altered dunite and peridotite; magnesite veins.", [("Major", "Igneous - Plutonic - Ultramafic - Serpentinite")])
check("serpentinite is OLIVINE_RICH_ULTRAMAFIC", "OLIVINE_RICH_ULTRAMAFIC" in serp["lithology"])
check("serpentinite qualifies as MARS-SERP", G.compare(serp, {}, "MARS-SERP")[0])
pyx = prof("Olivine pyroxenite", "Olivine pyroxenite; peridotite inclusions.", [("Major", "Igneous - Plutonic - Ultramafic")])
check("unit named pyroxenite is not OLIVINE_RICH_ULTRAMAFIC", "OLIVINE_RICH_ULTRAMAFIC" not in pyx["lithology"])
gab = prof("Gabbro", "Hornblende gabbro.", [("Major", "Igneous - Plutonic - Gabbroic - Gabbro")])
check("gabbro does not qualify as MARS-SERP", not G.compare(gab, {}, "MARS-SERP")[0])

# 4 lacustrine inference (sedimentology + basin context), no lake word in the text
lock = prof("Lockatong Formation", "Cyclically deposited sequences of laminated black mudstone and argillite with desiccation cracks.",
            [("Major", "Sedimentary - Clastic - Mudstone"), ("Minor", "Metamorphic - Metasedimentary - Metaclastic - Argillite")])
check("Lockatong text has no lake word", "LACUSTRINE" not in lock["environment"])
check("inferred lacustrine with basin context", G.infer_lacustrine(lock, {"VOLCANIC_NEIGHBOUR": True}) is not None)
check("no inference without basin context", G.infer_lacustrine(lock, {}) is None)
dolo = prof("Allentown Dolomite", "Dolomite with minor shale; mud cracks, ripple marks, rhythmically bedded.",
            [("Major", "Sedimentary - Carbonate - Dolostone"), ("Minor", "Sedimentary - Clastic - Mudstone - Shale")])
check("tidal-flat dolomite with mudcracks is not inferred lacustrine", G.infer_lacustrine(dolo, {"LAKE_NEIGHBOUR": True}) is None)
marine = prof("Navesink Formation", "Glauconitic marine clay and silt, laminated, with cycles.", [("Major", "Sedimentary - Clastic - Mudstone")])
check("marine evidence blocks the inference", G.infer_lacustrine(marine, {"LAKE_NEIGHBOUR": True}) is None)
one = prof("Some Shale", "Black laminated shale.", [("Major", "Sedimentary - Clastic - Mudstone - Shale")])
check("one indicator is not enough", G.infer_lacustrine(one, {"LAKE_NEIGHBOUR": True}) is None)
evap = prof("Boonton Formation", "Siltstone with mudcracks and gypsum pseudomorphs.",
            [("Major", "Sedimentary - Clastic - Siltstone"), ("Minor", "Sedimentary - Chemical - Evaporite - Gypsum")])
check("structured Evaporite lithology becomes EVAPORITE mineral evidence", "EVAPORITE" in evap["mineral"])

import re
check("Macrostrat 'non-marine' is not MARINE (bug found by the held-out Hartford test)", not re.search(G.MS_ENV["MARINE"], "non-marine", re.I))
check("'nonmarine' in map text is not MARINE", "MARINE" not in prof("X", "Nonmarine red beds; non-marine shale.", [("Major", "Sedimentary - Clastic - Mudstone")])["environment"])
check("'marine' still recorded", "MARINE" in prof("X", "Shallow marine shale.", [("Major", "Sedimentary - Clastic - Mudstone")])["environment"])

# 5 scale parsing / positional uncertainty
check("scale 1:100,000 parsed", G.scale_from_reference("Drake et al., 1996, Bedrock geologic map, 1:100,000") == 100000)
check("scale 1:250000 parsed", G.scale_from_reference("Berg 1980 scale 1:250000") == 250000)
check("no scale -> None", G.scale_from_reference("Unpublished compilation") is None)

# 6 every planetary property has a role, evidence type and a citation that exists
for rid, ref in G.PLANETARY.items():
    for x in ref["properties"]:
        planetary_claim = x["role"] in ("core", "supporting", "contradiction")
        if x["role"] == "not_compared":
            ok = x["evidence_type"] in ("observed", "interpreted", "inferred") and x["src"] and all(s in G.SRC for s in x["src"])
        else:
            ok = (x["evidence_type"] in ("observed", "interpreted", "inferred") and x["src"] and all(s in G.SRC for s in x["src"])) if planetary_claim \
                else (x["role"] in ("caution", "earth_only") and x["evidence_type"] == "not_applicable" and "Earth" in x["statement"])
        if not ok:
            check(f"{rid}/{x['code']} provenance complete", False)
check("all planetary properties carry role, evidence type and resolvable citations", True)

# 7 review corrections (15 Nov)
# 7a Palisade Diabase is not a lava neighbour (regression): toy map, mudstone polygon touching a diabase sill coded as basalt
import geopandas as gpd
from shapely.geometry import box
import regional_geology_v2 as RG
mud = prof("Test Mudstone", "Laminated black mudstone with desiccation cracks; cyclic.", [("Major", "Sedimentary - Clastic - Mudstone")])
profs = {"MUD": mud, "PAL": palisade, "ORG": orange}
toy = gpd.GeoDataFrame(dict(UNIT_LINK=["MUD", "PAL"]), geometry=[box(0, 0, 1000, 1000), box(1000, 0, 2000, 1000)], crs=5070)
ctx = RG.make_context(toy, profs)(0)
check("Palisade Diabase (coded basalt) is not a lava neighbour", ctx["VOLCANIC_NEIGHBOUR"] is False)
check("...so the mudstone is not inferred lacustrine from it", G.infer_lacustrine(mud, ctx) is None)
toy2 = gpd.GeoDataFrame(dict(UNIT_LINK=["MUD", "ORG"]), geometry=[box(0, 0, 1000, 1000), box(1000, 0, 2000, 1000)], crs=5070)
check("Orange Mountain Basalt is a lava neighbour", RG.make_context(toy2, profs)(0)["VOLCANIC_NEIGHBOUR"] is True)
check("is_lava_unit: Palisade False, Orange Mountain True", not G.is_lava_unit(palisade) and G.is_lava_unit(orange))

# 7b Macrostrat: homonyms rejected by place/age; name-only matches never establish core properties
fake = dict(query="Sugarloaf", units=[
    dict(col_id=1, strat_name="Sugarloaf Formation", clat=42.5, clng=-72.6, t_age=195, b_age=222, lith=["shale"], environ=["lacustrine"], environ_database_default=[]),
    dict(col_id=2, strat_name="Sugarloaf Quartzite", clat=34.2, clng=-116.9, t_age=596, b_age=617, lith=["quartzite"], environ=["marine"], environ_database_default=[])])
m = G.macrostrat_match(fake, 42.45, -72.6, "Lower Jurassic")
check("same-name unit 3,900 km away and 400 Myr older is rejected", [a["col_id"] for a in m["accepted"]] == [1] and m["rejected"][0]["col_id"] == 2)
check("nothing accepted without a location", G.macrostrat_match(fake, unit_age="Lower Jurassic")["accepted"] == [])
G.macrostrat.cache_clear()
_orig = G.macrostrat
G.macrostrat = lambda name: fake
p_ms = G.evidence_profile("Sugarloaf Formation", "Red arkose and siltstone.", "", [("Major", "Sedimentary - Clastic - Siltstone")], None,
                          use_macrostrat=True, location=(42.45, -72.6), unit_age="Lower Jurassic")
G.macrostrat = _orig
check("Macrostrat-only 'lacustrine' is kept apart and does not set the environment",
      "LACUSTRINE" not in p_ms["environment"] and "LACUSTRINE" in p_ms["macrostrat_only"])
check("...so it cannot satisfy the MARS-LAKE core", not G.compare(p_ms, {}, "MARS-LAKE")[0])

# 7c MARS-SERP keeps Seitah and Maaz apart; H2 is inferred, minerals observed
sp = {x["code"]: x for x in G.PLANETARY["MARS-SERP"]["properties"]}
check("olivine cumulate is Seitah, observed", sp["OLIVINE_RICH_ULTRAMAFIC"]["site"] == "Seitah" and sp["OLIVINE_RICH_ULTRAMAFIC"]["evidence_type"] == "observed")
check("serpentine is Maaz, observed (Tosca 2025)", sp["SERPENTINE"]["site"] == "Maaz" and sp["SERPENTINE"]["evidence_type"] == "observed"
      and sp["SERPENTINE"]["src"] == ["Tosca2025"])
check("serpentinization is Maaz, interpreted", sp["SERPENTINIZATION"]["site"] == "Maaz" and sp["SERPENTINIZATION"]["evidence_type"] == "interpreted")
check("H2 production is inferred and not compared", sp["H2_PRODUCTION"]["evidence_type"] == "inferred" and sp["H2_PRODUCTION"]["role"] == "not_compared")
check("Tosca 2025 is cited only for Maaz properties", all(x.get("site") == "Maaz" for x in G.PLANETARY["MARS-SERP"]["properties"] if "Tosca2025" in x["src"]))

# 8 optional: checks on a regional output file
if len(sys.argv) > 1:
    d = json.load(open(sys.argv[1]))
    check("schema version geo-2.0", d["schema_version"] == "geo-2.0")
    check("study area is clipped", d["study_area"]["clipped"] is True)
    lim = d["study_area"]["radius_km"]
    check("all candidates inside the study radius", all(c["distance_km"] <= lim + 0.01 for v in d["candidates"].values() for c in v))
    check("no candidate with a recorded core contradiction",
          all(not any(r["role"] == "contradiction" and r["earth_status"] == "CONTRADICTION recorded"
                      for r in c["layer_1_geological_evidence"]["comparison"]) for v in d["candidates"].values() for c in v))
    s = json.dumps(d["candidates"]).lower()
    check("no match scores, confidence levels or match percentages in candidates",
          not any(k in s for k in ('"score"', '"confidence"', "match_percent", "% match", "similarity")))

print(f"\n{len(FAILS)} failed" if FAILS else "\nall tests passed")
sys.exit(1 if FAILS else 0)
