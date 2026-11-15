#!/usr/bin/env python3
"""Independent, auditable *broad lithology* candidate search for Earth analog research.

No terrain requirements are evaluated. Class equivalences are limited to EXACT
GLiM Level-1 labels and NASA-supported, specific planetary reference hypotheses.
The output is a *map-unit lead*, NOT verified rock composition, process identity,
accessibility, or an analogue of a complete lunar/Mars base.

Inputs:
* offline --geojson file: GeoJSON polygon features with `xx_Description`
* online --arcgis: world-covering GLiM Level-I ArcGIS FeatureServer query

The latter depends on third-party network access and is intentionally not
claimed tested against live server responses in the packaged synthetic tests.
"""
from __future__ import annotations
import argparse, hashlib, json, pathlib, time
from dataclasses import dataclass
from typing import Iterable
import requests
from shapely.geometry import shape, Polygon
from shapely.ops import unary_union

LAYER_URL = ('https://services8.arcgis.com/4KhTMTZ1x0f76DSg/ArcGIS/rest/'
             'services/GLiM_Niveau_I/FeatureServer/1')
LAYER_CITATION = ('Hartmann and Moosdorf (2012), GLiM: '
                  'https://doi.org/10.1029/2012GC004370; hosted ArcGIS FeatureServer layer')

# Exact lithology classes, NOT a cross-world chemistry equivalence model.
# Ref literature for igneous/sedimentary Jezero: NASA 2022 Perseverance reports.
REFERENCE_CASES = {
    'jezero_maaz_volcanic': {
        'world':'Mars', 'region':'Jezero crater floor, Maaz formation',
        'question':'Where are terrestrial map units broadly classified as mafic volcanic rocks?',
        'classes':('Basic volcanic rocks',),
        'scientific_basis':'NASA Perseverance inferred lava flows in Maaz; source geological map is an Earth broad lithology classification.',
        'basis_url':'https://www.nasa.gov/missions/mars-2020-perseverance/perseverance-rover/nasas-perseverance-makes-new-discoveries-in-mars-jezero-crater/',
        'limitations':['Basic volcanic rock does not establish identical mineralogy or alteration','Volcanism is not equivalent to a NASA-approved Mars base site','Mapped lithology has uncertain local rock exposure']},
    'jezero_delta_siliciclastic': {
        'world':'Mars','region':'Jezero western sedimentary fan',
        'question':'Where are terrestrial map units broadly siliciclastic sedimentary rocks?',
        'classes':('Siliciclastic sedimentary rocks',),
        'scientific_basis':'Perseverance directly investigated sedimentary rocks at the Jezero delta. Sediment source, environment and stratigraphy require further evidence.',
        'basis_url':'https://science.nasa.gov/resource/perseverance-explores-the-jezero-crater-delta/',
        'limitations':['A siliciclastic map unit is NOT evidence of a delta','Does not establish identical depositional history, age, or habitability','Map scale may be far coarser than a sampled outcrop']},
    'jezero_seitah_plutonic': {
        'world':'Mars','region':'Jezero crater floor, Seitah formation',
        'question':'Where are terrestrial map units broadly mafic plutonic rocks?',
        'classes':('Basic plutonic rocks',),
        'scientific_basis':'Seítah is interpreted as slowly cooled, olivine-rich igneous cumulate material. A broad plutonic map class is only a coarse lead.',
        'basis_url':'https://www.usgs.gov/publications/aqueously-altered-igneous-rocks-sampled-floor-jezero-crater-mars',
        'limitations':['Basic plutonic does not establish cumulate texture or olivine content','Mineralogy and emplacement require site-scale verification']}
}
NON_DISCOVERABLE = {
    'lunar_highland_anorthosite':'GLiM Level-1 classes cannot identify anorthosite specifically',
    'martian_dune_process':'An unconsolidated-sediment unit cannot prove dune morphology or active aeolian transport',
    'martian_subsurface_ice':'Global mapped ice/glaciers is not comparable with SWIM subsurface-ice consistency or ice-table depth'
}


def sha256(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()


def _polygon_locator(geojson_geometry):
    g=shape(geojson_geometry)
    if g.is_empty or g.geom_type not in ('Polygon','MultiPolygon'):
        raise ValueError('Expected polygon geometry')
    point=g.representative_point()   # guaranteed inside geometry, unlike bbox center
    return {'point_lonlat':[round(point.x,7),round(point.y,7)],
            'bounding_box_lonlat':[round(v,7) for v in g.bounds],
            'centroid_lonlat':[round(g.centroid.x,7),round(g.centroid.y,7)]}


def _esri_to_geojson(g):
    """Preserves rings for a geometry *locator*, not topology/area analysis.
    Complex hole/multipart topology must be checked before computing polygon areas.
    """
    rings=g.get('rings') if g else None
    if not rings:raise ValueError('ArcGIS polygon missing rings')
    # ArcGIS exterior rings clockwise; holes counterclockwise in conventional planar CRS.
    # shapely features used for a pin only: choose the largest individual ring if ambiguous.
    def signed_area(r):
        return sum(r[i][0]*r[(i+1)%len(r)][1]-r[(i+1)%len(r)][0]*r[i][1] for i in range(len(r)))/2
    shells=[r for r in rings if signed_area(r)<0]
    if not shells:shells=[max(rings,key=lambda r:abs(signed_area(r)))]
    return {'type':'MultiPolygon' if len(shells)>1 else 'Polygon',
            'coordinates':[[r] for r in shells] if len(shells)>1 else [shells[0]]}


def arcgis_feature_to_geojson(rec):
    return {'type':'Feature','properties':rec['attributes'],
            'geometry':_esri_to_geojson(rec['geometry'])}


def scan_features(features:Iterable[dict],case_id,*,source,limit=None):
    if case_id in NON_DISCOVERABLE:
        raise ValueError('Unsupported hypothesis: '+NON_DISCOVERABLE[case_id])
    if case_id not in REFERENCE_CASES:raise KeyError('Unknown research case: '+case_id)
    case=REFERENCE_CASES[case_id]
    out=[];n=0;bad=0;filtered=0
    for ft in features:
        n+=1
        p=ft.get('properties') or {}
        value=p.get('xx_Description')
        if value not in case['classes']:
            filtered+=1;continue
        try:loc=_polygon_locator(ft['geometry'])
        except Exception:bad+=1;continue
        out.append({
            'candidate_id':f"glim:{p.get('OBJECTID',p.get('feature_id',n))}",
            'source_class':value,
            'source_record':{k:p.get(k) for k in ('OBJECTID','IDENTITY_','xx_Description','Litho') if k in p},
            'geometry_locator':loc,
            'evidence_status':'broad_mapped_lithology_only',
            'matches':case['question'],
            'does_not_establish':case['limitations'],
            'terrain_screen_required':False
        })
        if limit is not None and len(out)>=limit:break
    return {
      'method':'independent_geology_discovery_v0.2',
      'planetary_reference':{'id':case_id,**case},
      'source':source,
      'mapping_mode':'exact GLiM Level-1 class match; no inferred process or chemistry',
      'processed_input_records':n,'filtered_wrong_class':filtered,
      'invalid_geometry_records':bad, 'candidate_count':len(out),
      'coverage_status':'caller must provide geographic extent or untruncated global dataset; never infer from candidate_count',
      'candidates':out}


def scan_geojson(path,case_id):
    d=json.loads(pathlib.Path(path).read_text())
    if d.get('type')!='FeatureCollection':raise ValueError('Expected GeoJSON FeatureCollection')
    r=scan_features(d['features'],case_id,source={'kind':'GeoJSON',
                'file':str(path),'sha256':sha256(path)})
    r['coverage_status']='input extent unknown; does not establish global coverage'
    return r


def _get(session,params,timeout=40):
    res=session.get(LAYER_URL+'/query',params=params,timeout=timeout)
    res.raise_for_status()
    obj=res.json()
    if 'error' in obj:raise RuntimeError(f"ArcGIS query error: {obj['error']}")
    return obj


def _bbox_params(bbox):
    if bbox is None:return {}
    x0,y0,x1,y1=bbox
    if not (-180<=x0<x1<=180 and -90<=y0<y1<=90):raise ValueError('bad lon/lat bbox')
    return {'geometry':json.dumps({'xmin':x0,'ymin':y0,'xmax':x1,'ymax':y1,
               'spatialReference':{'wkid':4326}}),
            'geometryType':'esriGeometryEnvelope','inSR':4326,
            'spatialRel':'esriSpatialRelIntersects'}


def scan_arcgis(case_id,bbox=None,max_records=3000,session=None):
    """Retrieve actual matched map polygons. Requires network; not globally exhaustive
    unless all matched feature IDs are fetched (see coverage_status).
    """
    if case_id not in REFERENCE_CASES:raise KeyError(case_id)
    if session is None:session=requests.Session()
    classes=REFERENCE_CASES[case_id]['classes']
    where='xx_Description IN ('+','.join("'"+k.replace("'","''")+"'" for k in classes)+')'
    base={'f':'json','where':where,**_bbox_params(bbox)}
    ids=_get(session,{**base,'returnIdsOnly':'true','returnGeometry':'false'})
    records=sorted(ids.get('objectIds') or [])
    if max_records is not None:fetch_ids=records[:max_records]
    else:fetch_ids=records
    feats=[]
    for offset in range(0,len(fetch_ids),200):
        batch=fetch_ids[offset:offset+200]
        chunk=_get(session,{'f':'json','objectIds':','.join(map(str,batch)),
                 'outFields':'OBJECTID,IDENTITY_,xx_Description,Litho',
                 'returnGeometry':'true','outSR':4326})
        if len(chunk.get('features',[]))!=len(batch):
            raise RuntimeError('Missing ArcGIS records: stop rather than claim complete coverage')
        feats.extend(arcgis_feature_to_geojson(f) for f in chunk['features'])
    source={'kind':'GLiM Level-I ArcGIS FeatureServer','service':LAYER_URL,
      'citation':LAYER_CITATION,'query_where':where,'query_bbox_wgs84':bbox,
      'reported_matching_ids':len(records),'downloaded_ids':len(fetch_ids),
      'geometry_crs':'EPSG:4326'}
    r=scan_features(feats,case_id,source=source)
    r['coverage_status']=('complete_matching_feature_set_for_queried_extent' if len(fetch_ids)==len(records)
                 else f'INCOMPLETE: scanned {len(fetch_ids)} of {len(records)} matching polygon IDs')
    return r


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--target',choices=tuple(REFERENCE_CASES),required=True)
    src=ap.add_mutually_exclusive_group(required=True)
    src.add_argument('--geojson',help='A real or synthetic GeoJSON feature collection')
    src.add_argument('--arcgis',action='store_true',help='Query public worldwide GLiM layer (network required)')
    ap.add_argument('--bbox',nargs=4,type=float,metavar=('W','S','E','N'))
    ap.add_argument('--max-records',type=int,default=3000,help='Network result safety cap; truncated results NEVER imply worldwide coverage')
    ap.add_argument('--all-matches',action='store_true',help='Fetch EVERY matching polygon (could be many thousands; API limits apply)')
    ap.add_argument('--output',required=True)
    a=ap.parse_args()
    if a.geojson:r=scan_geojson(a.geojson,a.target)
    else:r=scan_arcgis(a.target,bbox=a.bbox,max_records=None if a.all_matches else a.max_records)
    pathlib.Path(a.output).write_text(json.dumps(r,indent=2))
    print(json.dumps({'target':a.target,'candidates':r['candidate_count'],
                      'coverage':r['coverage_status'],'output':a.output},indent=2))

if __name__=='__main__':main()
