# Draft written with AI assistance (Claude, Anthropic) for NASA Space Apps 2026; disclosed per the
# Space Apps AI policy. Reviewed and run by the team.
import rasterio, numpy as np, time
from rasterio.windows import from_bounds
ENV=dict(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".TIF", GDAL_HTTP_MULTIPLEX="NO", GDAL_HTTP_MULTIRANGE="SINGLE", GDAL_NUM_THREADS="1", GDAL_HTTP_MAX_RETRY="6", GDAL_HTTP_RETRY_DELAY="4", GDAL_HTTP_RETRY_CODES="403,429,500,502,503")
def read(layer,cx,cy,w,base="https://pgda.gsfc.nasa.gov/data/LOLA_20mpp/LDEM_80S_20MPP_ADJ"):
    with rasterio.Env(**ENV):
        with rasterio.open(f"/vsicurl/{base}{layer}.TIF") as d:
            win=from_bounds(cx-w/2,cy-w/2,cx+w/2,cy+w/2,d.transform)
            return d.read(1,window=win).astype(float), d.window_transform(win), d.crs
if __name__=="__main__":
    sites={"Site01_connecting_ridge":(-11000,-12000,16000),"Site04_shackleton_rim":(-1000,-7000,16000),"Site23_malapert":(-500,121500,21000),"Site11_degerlache_rim":(-37000,15000,16000)}
    for name,(cx,cy,w) in sites.items():
        t=time.time()
        z,_,_=read("",cx,cy,w); e,_,_=read("_EFFRES",cx,cy,w); r,_,_=read("_ERR",cx,cy,w)
        np.savez_compressed(f"lola20_{name}.npz",z=z,effres=e,err=r)
        print(name,z.shape,"EFFRES m p10/50/90=%.0f/%.0f/%.0f"%tuple(np.nanpercentile(e,[10,50,90])),"ERR m p10/50/90=%.2f/%.2f/%.2f"%tuple(np.nanpercentile(r,[10,50,90])),"t=%.0fs"%(time.time()-t),flush=True)
