"""Self-contained synthetic unit and integration tests, never mistaken for NASA observations."""
import json, math
from pathlib import Path
import numpy as np
import rasterio
from rasterio.transform import from_origin
from scipy.stats import wasserstein_distance
from experiment import plane_fit, descriptors, Patch, compare, run

ROOT=Path(__file__).resolve().parent

def put_tif(path,z,pixel=100,crs=None,center=(500000,4500000)):
    h,w=z.shape
    t=from_origin(center[0]-w*pixel/2,center[1]+h*pixel/2,pixel,pixel)
    with rasterio.open(path,'w',driver='GTiff',width=w,height=h,count=1,dtype='float32',
                        crs=crs,transform=t,nodata=-9999) as out:
        out.write(z.astype('float32'),1)

def test_math():
    yy,xx=np.mgrid[-10:11,-10:11];x=xx*10.; y=yy*10.
    for angle in [0,15,28]:
        z=np.tan(np.radians(angle))*x
        slope,rough=plane_fit(x,y,z)
        assert abs(slope-angle)<1e-10,(slope,angle)
        assert abs(rough)<1e-9,rough
    bumpy=1.5*np.sin(2*np.pi*x/70.) + .9*np.cos(2*np.pi*y/110.)
    a,r=plane_fit(x,y,bumpy)
    assert r>1.0
    inclined=np.tan(np.radians(15))*x + bumpy
    a2,r2=plane_fit(x,y,inclined)
    assert abs(a-a2)>0.01 # same bumps alter least-squares plane slightly
    assert abs(r-r2)<1e-9
    print('PASS: flat, smooth slopes, residual roughness and tilt invariance')

def test_histogram_counterexample():
    rng=np.random.default_rng(134)
    one=np.zeros((60,60));two=np.zeros((60,60))
    one[27:33,:]=30  # 360 steep cells, divides 2 connected low-slope pieces
    # Isolated 10% steep cells, chosen away from boundary and mutually non-adjacent
    grid=[(i,j) for i in range(1,59,2) for j in range(1,59,2)]
    idx=rng.choice(len(grid),360,replace=False)
    for k in idx:two[grid[k]]=30
    assert np.count_nonzero(one)==np.count_nonzero(two)==360
    d=wasserstein_distance(one.ravel(),two.ravel())
    assert d==0
    from scipy.ndimage import label
    frac=[]
    for g in [one,two]:
        ok=g<10; components,n=label(ok,np.array([[0,1,0],[1,1,1],[0,1,0]]))
        freq=np.bincount(components[ok])
        frac.append(freq[1:].max()/ok.sum())
    assert abs(frac[0]-0.5)<.001 and frac[1]>.99
    print('PASS: same histogram W1=%.1f deg, connected fraction %.3f vs %.3f'%(d,*frac))

def test_normalization_failure():
    a=np.array([3.,4.,5.]); b=np.array([3.,4.,5.]);
    baseline=wasserstein_distance(a,b)
    assert baseline==0
    print('PASS: indistinguishable reference windows yield zero normalization denominator')


def test_resolution_and_quality():
    rng=np.random.default_rng(2026)
    z=rng.normal(size=(48,48))
    all_good=Patch(z,np.ones(z.shape,dtype=bool),100,{'source':'SYNTHETIC'},effres=np.full(z.shape,50.))
    too_blurry=Patch(z,np.ones(z.shape,dtype=bool),100,{'source':'SYNTHETIC'},effres=np.full(z.shape,8000.))
    rgood=descriptors(all_good,[200,400,800])
    rbad=descriptors(too_blurry,[400,800])
    assert rgood['200']['status']=='unsupported_sampling',rgood['200']
    assert rgood['400']['status']=='ok',rgood['400']
    assert all(v['status']=='insufficient_samples' for v in rbad.values()),rbad
    all_missing=Patch(z,np.zeros(z.shape,dtype=bool),100,{'source':'SYNTHETIC'})
    assert descriptors(all_missing,[400])['400']['status']=='insufficient_samples'
    print('PASS: unsupported scales, poor effective resolution and missing data rejected')

def test_real_raster_io_synthetic_surfaces():
    # Synthetic DEM GeoTIFF input exercises same I/O and feature extractor as real rasters.
    sz=48; yy,xx=np.mgrid[0:sz,0:sz];x=xx*100.;y=yy*100.
    base=(.025*x+.013*y + 7*np.sin(x/390.) + 4*np.cos(y/530.)
          + 2*np.sin((x+y)/250.))
    planet=ROOT/'SYNTHETIC_planet_100m.tif'
    earth=ROOT/'SYNTHETIC_earth_100m.tif'
    put_tif(planet,base,crs=None)
    sz2=88; yy2,xx2=np.mgrid[:sz2,:sz2];xe=xx2*100.;ye=yy2*100.
    e=.12*xe+.035*ye+18*np.sin(xe/210.)+19*np.cos(ye/240.)
    e[:48,:48]=base+100 # Same terrain shifted vertically, which slope+roughness ignore.
    put_tif(earth,e,crs='EPSG:32618')
    result=run(str(planet),[str(earth)],str(ROOT/'synthetic_results.json'),
        baselines=(400,800,1600),pixel=100,reference_size=4800,
        earth_size=8800,window_size=4800,stride=1600)
    eligible=result['top_by_slope'];assert eligible
    best=eligible[0]
    # The lower-left corner of the raster is NOT the designated synthetic match;
    # top-left 48x48 is intentionally the matching patch.
    print('SYNTHETIC: n=%d, eligible=%d, best=%s slope-W1=%.4f° rough-W1=%.4fm'%(
        result['n_total'],result['n_eligible'],best['candidate_id'],
        best['comparison']['mean_slope_w1_deg'],best['comparison']['mean_roughness_w1_m']))
    assert any(x['candidate_id'].endswith(':0:0') for x in eligible[:5]),'Matching region should be among leading candidates'
    return result

if __name__=='__main__':
    test_math();test_histogram_counterexample();test_normalization_failure();test_resolution_and_quality();test_real_raster_io_synthetic_surfaces()
    print('ALL TESTS PASSED — input DEMs are synthetic; no NASA/Earth terrain measured.')
