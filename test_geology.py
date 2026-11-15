"""Offline unit tests. Artificial polygons: do not interpret results as Earth discoveries."""
import json, pathlib, tempfile
from geology_pathway import scan_features,scan_arcgis,scan_geojson,REFERENCE_CASES,NON_DISCOVERABLE

def feature(fid,klass,x,y):
    return {'type':'Feature','properties':{'OBJECTID':fid,'xx_Description':klass},
      'geometry':{'type':'Polygon','coordinates':[[[x,y],[x+.1,y],[x+.1,y+.1],[x,y+.1],[x,y]]]}}

def test_independent_selection():
    ff=[feature(1,'Siliciclastic sedimentary rocks',-74,40),
        feature(2,'Basic volcanic rocks',-110,35),
        feature(3,'Basic plutonic rocks',10,-25),
        feature(4,'No Data',23,47)]
    out=scan_features(ff,'jezero_maaz_volcanic',source={'test':'synthetic'})
    assert out['candidate_count']==1
    assert out['candidates'][0]['candidate_id']=='glim:2'
    assert out['candidates'][0]['terrain_screen_required'] is False
    assert out['candidates'][0]['evidence_status']=='broad_mapped_lithology_only'
    assert out['filtered_wrong_class']==3
    out2=scan_features(ff,'jezero_delta_siliciclastic',source={'test':'synthetic'})
    assert out2['candidate_count']==1 and out2['candidates'][0]['candidate_id']=='glim:1'
    print('PASS: geology independently selects different candidates without terrain')

def test_reject_false_claims():
    ff=[feature(5,'Unconsolidated sediments',-74,40),
        feature(6,'Ice and Glaciers',-70,-70)]
    for key in NON_DISCOVERABLE:
        try:scan_features(ff,key,source={'test':'synthetic'})
        except ValueError:pass
        else:raise AssertionError(f'Did not reject unsupported interpretation {key}')
    assert scan_features(ff,'jezero_delta_siliciclastic',source={'test':'synthetic'})['candidate_count']==0
    print('PASS: unsupported ice, dunes and anorthosite shortcuts are rejected')

def test_file_provenance():
    f=[feature(12,'Basic volcanic rocks',-10,20)]
    with tempfile.TemporaryDirectory() as d:
        p=pathlib.Path(d)/'test.geojson';p.write_text(json.dumps({'type':'FeatureCollection','features':f}))
        x=scan_geojson(p,'jezero_maaz_volcanic')
        assert x['source']['sha256'] and x['coverage_status'].startswith('input extent unknown')
        assert x['candidates'][0]['geometry_locator']['point_lonlat']
    print('PASS: reproducible input source and polygon representative point')

class Response:
    def __init__(self,obj):self.obj=obj
    def raise_for_status(self):pass
    def json(self):return self.obj
class Session:
    def __init__(self):self.calls=[]
    def get(self,url,params,timeout):
        self.calls.append(params)
        if params.get('returnIdsOnly'):
            return Response({'objectIds':[21,22,23]})
        assert params['outSR']==4326
        attrs=[(int(i),'Basic volcanic rocks') for i in params['objectIds'].split(',')]
        features=[]
        for fid,k in attrs:
            x=-100+fid
            features.append({'attributes':{'OBJECTID':fid,'xx_Description':k},
             'geometry':{'rings':[[[x,40],[x,41],[x+1,41],[x+1,40],[x,40]]]}})
        return Response({'features':features})

def test_query_pagination():
    fake=Session()
    r=scan_arcgis('jezero_maaz_volcanic',session=fake,max_records=2)
    assert r['candidate_count']==2
    assert r['coverage_status'].startswith('INCOMPLETE: scanned 2 of 3')
    assert 'Basic volcanic rocks' in fake.calls[0]['where']
    assert fake.calls[0]['returnIdsOnly']=='true'
    assert len(fake.calls)==2
    r2=scan_arcgis('jezero_maaz_volcanic',session=Session(),max_records=None)
    assert r2['candidate_count']==3 and r2['coverage_status']=='complete_matching_feature_set_for_queried_extent'
    print('PASS: ArcGIS source queries, bounded subsets and explicit incomplete/complete coverage')

if __name__=='__main__':
    test_independent_selection();test_reject_false_claims();test_file_provenance();test_query_pagination()
    print('4/4 independent geology test groups passed')
