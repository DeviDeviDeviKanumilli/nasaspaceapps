# Draft written with AI assistance (Claude, Anthropic) for NASA Space Apps 2026; disclosed per the
# Space Apps AI policy. Reviewed and run by the team.
import sys, numpy as np, time
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from experiment import plane_fit           # team prototype estimator (reference)
from terrain_engine import plane_features, disc_kernel
rng=np.random.default_rng(0)
# 1) analytic incline 15 deg + flat
for ang in [0,15,28]:
    n=200;p=30.0
    y,x=np.mgrid[0:n,0:n]*p
    z=np.tan(np.radians(ang))*x+1000
    s,r,_,_=plane_features(z,np.ones_like(z,bool),p,600)
    print("incline",ang,"-> median slope %.4f rough %.2e"%(np.nanmedian(s),np.nanmedian(r)))
# 2) real-ish random surface with holes: compare to prototype at random pixels
n=160;p=60.0
z=np.cumsum(np.cumsum(rng.normal(size=(n,n)),0),1)*0.5+rng.normal(size=(n,n))*2
valid=rng.random((n,n))>0.05
for L in [240,480,960]:
    s,r,frac,rad=plane_features(z,valid,p,L)
    k,kx,ky=disc_kernel(rad)
    errs=[]
    for _ in range(200):
        i,j=rng.integers(rad,n-rad,2)
        if not np.isfinite(s[i,j]):continue
        sl=(slice(i-rad,i+rad+1),slice(j-rad,j+rad+1))
        res=plane_fit(kx*p,ky*p,z[sl],valid[sl]&(k>0),minimum=12)
        if res is None:continue
        errs.append((abs(res[0]-s[i,j]),abs(res[1]-r[i,j])))
    e=np.array(errs);print("L",L,"n",len(e),"max |dslope| %.2e deg, max |drough| %.2e m"%tuple(e.max(0)))
# 3) speed: 4000x4000 at 30 m (one GLO-30 1x1 deg tile is 3600x3600)
z=np.cumsum(np.cumsum(rng.normal(size=(3600,3600)),0),1).astype(float)
t=time.time(); s,r,_,_=plane_features(z,np.ones_like(z,bool),30.0,480); print("3600^2 tile, one baseline: %.1fs"%(time.time()-t))
