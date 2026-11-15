# Draft written with AI assistance (Claude, Anthropic) for NASA Space Apps 2026; disclosed per the
# Space Apps AI policy. Reviewed and run by the team.
import requests, json, time, os, sys
U="https://services8.arcgis.com/4KhTMTZ1x0f76DSg/ArcGIS/rest/services/GLiM_Niveau_I/FeatureServer/1/query"
s=requests.Session(); s.verify=os.environ.get("REQUESTS_CA_BUNDLE",True)
N=1235259; page=2000; t0=time.time(); fails=0
for off in range(0,N,page):
    fn=f"glim/p{off:07d}.geojson"; os.makedirs("glim", exist_ok=True)
    if os.path.exists(fn): continue
    for attempt in range(5):
        try:
            r=s.get(U,params=dict(where="1=1",outFields="Litho",returnGeometry="true",outSR=4326,geometryPrecision=4,maxAllowableOffset=0.001,resultOffset=off,resultRecordCount=page,orderByFields="OBJECTID",f="geojson"),timeout=120)
            d=r.json(); assert "features" in d, str(d)[:200]
            json.dump(d,open(fn,"w")); break
        except Exception as e:
            time.sleep(5*(attempt+1)); err=e
    else:
        fails+=1; print("FAIL",off,err,flush=True)
    if off % 100000==0: print(off, round(time.time()-t0), "s", flush=True)
print("done", round(time.time()-t0),"s fails",fails, flush=True)
