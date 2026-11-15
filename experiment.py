#!/usr/bin/env python3
"""Exploratory Moon/Mars-to-Earth terrain *measurement* test, not a base suitability score.

This is an intentionally small-tile, auditable experiment. It does NOT claim global
coverage or validate an Earth site. Source DEMs and quality layers must be supplied.
"""
from __future__ import annotations
import argparse, hashlib, json, math, pathlib
from dataclasses import dataclass
import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import from_origin
from rasterio.warp import reproject, transform as rio_transform
from scipy.ndimage import label as nd_label
from scipy.stats import wasserstein_distance

@dataclass
class Patch:
    z: np.ndarray
    valid: np.ndarray
    pixel_m: float
    meta: dict
    effres: np.ndarray | None = None

def _hash(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for b in iter(lambda:f.read(1024*1024), b''):h.update(b)
    return h.hexdigest()

def _finite_mask(a, nodata):
    good=np.isfinite(a)
    if nodata is not None and np.isfinite(nodata): good &= (a!=nodata)
    return good

def _sample_projected(path, size_m, pixel_m, planet=False, center=None, quality_path=None):
    """Read a local crop. Planetary GeoTIFF must already use projected metre XY.
    Earth data are locally reprojected to WGS84 UTM; this is NOT a global mosaic.
    """
    side=int(round(size_m/pixel_m)); size_m=side*pixel_m
    with rasterio.open(path) as ds:
        if not ds.transform.is_rectilinear:raise ValueError('Rotated raster unsupported')
        if planet:
            # Planetary custom CRS may be unknown to Earth-only reprojection libraries.
            # Resample in the native *metric* X/Y frame and never reproject Moon as Earth.
            if abs(abs(ds.res[0])-abs(ds.res[1]))>max(ds.res)*0.03:
                raise ValueError('Planetary X/Y pixels must be metric, nearly square')
            if not (0.1 <= abs(ds.res[0]) <= 20000):
                raise ValueError('Planetary pixel spacing implausible for metres')
            cx,cy=center if center else ((ds.bounds.left+ds.bounds.right)/2,(ds.bounds.top+ds.bounds.bottom)/2)
            win=rasterio.windows.from_bounds(cx-size_m/2,cy-size_m/2,cx+size_m/2,cy+size_m/2,ds.transform)
            z=ds.read(1,window=win,out_shape=(side,side),boundless=True,
                      resampling=Resampling.average,masked=True)
            valid=~np.ma.getmaskarray(z)&np.isfinite(z.filled(np.nan))
            out=np.asarray(z.filled(np.nan),dtype=np.float64)
            metadata={'source':str(path),'source_sha256':_hash(path),'source_crs':str(ds.crs),
                'source_res':list(ds.res),'source_nodata':ds.nodata,'native_xy_center_m':[cx,cy],
                'read_method':'window, average downsampling in native metric planetary grid'}
            effres=None
            if quality_path:
                with rasterio.open(quality_path) as q:
                    if q.width!=ds.width or q.height!=ds.height or not q.transform.almost_equals(ds.transform):
                        raise ValueError('Effective-resolution raster not co-registered with DEM')
                    v=q.read(1,window=win,out_shape=(side,side),boundless=True,
                             resampling=Resampling.average,masked=True)
                    effres=np.asarray(v.filled(np.nan),dtype=float)
                metadata['quality_source']=str(quality_path)
            return Patch(out,valid,float(pixel_m),metadata,effres)
        if ds.crs is None: raise ValueError('Earth raster must have a CRS')
        lon,lat=rio_transform(ds.crs,'EPSG:4326',[(ds.bounds.left+ds.bounds.right)/2],
                              [(ds.bounds.top+ds.bounds.bottom)/2]); lon,lat=lon[0],lat[0]
        if center is not None:lon,lat=center
        zone=int(math.floor((lon+180)/6)+1)
        if zone<1 or zone>60:raise ValueError('Invalid UTM zone')
        epsg=(32600 if lat>=0 else 32700)+zone
        xs,ys=rio_transform('EPSG:4326',f'EPSG:{epsg}',[lon],[lat]);cx,cy=xs[0],ys[0]
        transform=from_origin(cx-size_m/2,cy+size_m/2,pixel_m,pixel_m)
        dest=np.full((side,side),np.nan,dtype=np.float32)
        # Select area averaging when source cells are finer than the target grid.
        if ds.crs.is_geographic:
            src_m=min(abs(ds.res[0])*111320*max(.05,math.cos(math.radians(lat))),abs(ds.res[1])*111320)
        else:
            src_m=min(map(abs,ds.res))
        reproject(source=rasterio.band(ds,1),destination=dest,
                  src_transform=ds.transform,src_crs=ds.crs,src_nodata=ds.nodata,
                  dst_transform=transform,dst_crs=f'EPSG:{epsg}',dst_nodata=np.nan,
                  resampling=Resampling.average if src_m<pixel_m else Resampling.bilinear)
        valid=np.isfinite(dest)
        meta={'source':str(path),'source_sha256':_hash(path),'source_crs':str(ds.crs),
              'source_res':list(ds.res),'utm_epsg':epsg,'center_latlon':[lat,lon],
              'crop_size_m':size_m,'center_utm_xy':[cx,cy],
              'read_method':'local UTM reprojection; effective resolution not assessed'}
        return Patch(dest.astype(float),valid,float(pixel_m),meta)

def plane_fit(x,y,z,valid=None,minimum=12):
    """Single plane fit in physical metres, returning slope degrees and detrended RMS m."""
    if valid is None:valid=np.isfinite(z)
    k=valid&np.isfinite(z)
    if np.count_nonzero(k)<minimum:return None
    xy=np.stack((x[k],y[k],np.ones(np.count_nonzero(k))),axis=1)
    if np.linalg.matrix_rank(xy)<3:return None
    a,b,c=np.linalg.lstsq(xy,z[k],rcond=None)[0]
    residual=z[k]-(a*x[k]+b*y[k]+c)
    return float(np.degrees(np.arctan(np.hypot(a,b)))),float(np.sqrt(np.mean(residual**2)))

def descriptors(p:Patch,baselines_m,step_pixels=2,required_valid=.8):
    """At each physical baseline, fit local circular planes at regularly spaced centers.
    `roughness` is gridded height residual RMS, NOT NASA LOLA LDRM ROUGH.
    """
    h,w=p.z.shape
    data={}
    for L in baselines_m:
        r=int(round(L/(2*p.pixel_m)))
        if r<2:
            data[str(L)]={'status':'unsupported_sampling','reason':'baseline below four grid spacings'};continue
        yy,xx=np.mgrid[-r:r+1,-r:r+1]
        circ=(xx**2+yy**2)<=r*r
        x,y=xx*p.pixel_m,yy*p.pixel_m
        angles=[];rough=[]; slopes_grid=[]; centers=[]
        for i in range(r,h-r,step_pixels):
            for j in range(r,w-r,step_pixels):
                sl=(slice(i-r,i+r+1),slice(j-r,j+r+1))
                mask=p.valid[sl]&circ
                if np.count_nonzero(mask)<12 or np.count_nonzero(mask)/np.count_nonzero(circ)<required_valid:continue
                if p.effres is not None:
                    effective=p.effres[sl][mask]
                    if np.count_nonzero(np.isfinite(effective))<12 or np.nanpercentile(effective,90)>L/2:continue
                fit=plane_fit(x,y,p.z[sl],mask)
                if fit is None:continue
                a,b=fit;angles.append(a);rough.append(b);centers.append([i,j])
        n=len(angles)
        if n<12:
            data[str(L)]={'status':'insufficient_samples','n':n};continue
        # Spatial-connectivity computation uses sampled grid cells. Missing locations obstruct routes.
        si=(np.arange(r,h-r,step_pixels)); sj=(np.arange(r,w-r,step_pixels))
        surface=np.full((len(si),len(sj)),np.nan)
        map_i={v:i for i,v in enumerate(si)};map_j={v:j for j,v in enumerate(sj)}
        for (i,j),a in zip(centers,angles):surface[map_i[i],map_j[j]]=a
        curves={}
        for t in [5,10,15,20,25]:
            ok=np.isfinite(surface)&(surface<=t)
            labs,num=nd_label(ok,structure=np.array([[0,1,0],[1,1,1],[0,1,0]]))
            if np.count_nonzero(ok):
                counts=np.bincount(labs[ok]);curves[str(t)]=float(max(counts[1:])/np.count_nonzero(ok))
            else:curves[str(t)]=None
        data[str(L)]={'status':'ok','n':n,'slope_deg':angles,'roughness_m':rough,
           'slope_summary':_summ(angles),'roughness_summary':_summ(rough),
           'largest_connected_passable_fraction_by_slope_deg':curves,
           'sample_step_m':step_pixels*p.pixel_m}
    return data

def _summ(a):
    v=np.asarray(a);return {'median':float(np.median(v)),'p10':float(np.percentile(v,10)),
        'p90':float(np.percentile(v,90)),'mean':float(np.mean(v))}

def compare(a,b,baselines):
    pairs=[]
    for L in baselines:
        aa=a.get(str(L),{});bb=b.get(str(L),{})
        if aa.get('status')!='ok' or bb.get('status')!='ok':continue
        pairs.append({'baseline_m':L,'slope_w1_deg':float(wasserstein_distance(aa['slope_deg'],bb['slope_deg'])),
            'roughness_w1_m':float(wasserstein_distance(aa['roughness_m'],bb['roughness_m'])),
            'connectivity_difference_by_threshold':{
                t:abs(aa['largest_connected_passable_fraction_by_slope_deg'][t]-bb['largest_connected_passable_fraction_by_slope_deg'][t])
                if aa['largest_connected_passable_fraction_by_slope_deg'][t] is not None and bb['largest_connected_passable_fraction_by_slope_deg'][t] is not None else None
                for t in ['5','10','15','20','25']}})
    if not pairs:return {'status':'no_common_valid_baselines'}
    return {'status':'ok','by_baseline':pairs,
      'mean_slope_w1_deg':float(np.mean([p['slope_w1_deg'] for p in pairs])),
      'mean_roughness_w1_m':float(np.mean([p['roughness_w1_m'] for p in pairs]))}

def pareto(candidates):
    r=[]
    for i,c in enumerate(candidates):
        if c['comparison'].get('status')!='ok':continue
        a,b=c['comparison']['mean_slope_w1_deg'],c['comparison']['mean_roughness_w1_m']
        dominated=False
        for j,d in enumerate(candidates):
            if j==i or d['comparison'].get('status')!='ok':continue
            x,y=d['comparison']['mean_slope_w1_deg'],d['comparison']['mean_roughness_w1_m']
            if x<=a and y<=b and (x<a or y<b):dominated=True;break
        if not dominated:r.append(c['candidate_id'])
    return r

def window(p,r0,c0,side):
    return Patch(p.z[r0:r0+side,c0:c0+side],p.valid[r0:r0+side,c0:c0+side],p.pixel_m,p.meta,
                 None if p.effres is None else p.effres[r0:r0+side,c0:c0+side])

def run(planet,earth_paths,out,baselines=(400,800,1600),pixel=100,reference_size=4800,
        earth_size=9000,window_size=4800,stride=1500,effres=None,planet_center=None,earth_center_lonlat=None):
    P=_sample_projected(planet,reference_size,pixel,planet=True,center=planet_center,quality_path=effres)
    reference=descriptors(P,baselines)
    candidates=[];side=int(round(window_size/pixel)); jump=max(1,int(round(stride/pixel)))
    for ep in earth_paths:
        E=_sample_projected(ep,earth_size,pixel,planet=False,center=earth_center_lonlat)
        for i in range(0,E.z.shape[0]-side+1,jump):
            for j in range(0,E.z.shape[1]-side+1,jump):
                patch=window(E,i,j,side)
                feat=descriptors(patch,baselines)
                cmp=compare(reference,feat,baselines)
                utm_cx,utm_cy=E.meta['center_utm_xy']
                win_cx=utm_cx+(j+side/2-E.z.shape[1]/2)*pixel
                win_cy=utm_cy+(E.z.shape[0]/2-i-side/2)*pixel
                clon,clat=rio_transform(f"EPSG:{E.meta['utm_epsg']}",'EPSG:4326',[win_cx],[win_cy])
                candidates.append({'candidate_id':f'{pathlib.Path(ep).stem}:{i}:{j}',
                     'source':E.meta,'r0':i,'c0':j,
                     'center_lonlat':[float(clon[0]),float(clat[0])],
                     'footprint_estimate':'square in local UTM; center plus window_size_m',
                     'valid_fraction':float(np.mean(patch.valid)),
                     'comparison':cmp,'descriptor_summaries':{
                     k:{'status':v['status'],'n':v.get('n'),
                         'slope_summary':v.get('slope_summary'),'roughness_summary':v.get('roughness_summary'),
                         'connectivity':v.get('largest_connected_passable_fraction_by_slope_deg')}
                     for k,v in feat.items()}})
    eligible=[c for c in candidates if c['comparison'].get('status')=='ok']
    eligible.sort(key=lambda c:(c['comparison']['mean_slope_w1_deg'],c['comparison']['mean_roughness_w1_m']))
    result={'experiment_type':'small-tile real-data comparison if user supplies real DEMs',
      'warning':'Relative measurements only; NOT global search, proven scientific analog, landing suitability or NASA approval',
      'planet':P.meta,'planet_valid_fraction':float(np.mean(P.valid)),
      'parameters':{'baselines_m':list(baselines),'pixel_m':pixel,'reference_size_m':reference_size,
          'earth_crop_size_m':earth_size,'candidate_window_m':window_size,'candidate_stride_m':stride},
      'reference_summaries':{k:{'status':v['status'],'n':v.get('n'),
           'slope_summary':v.get('slope_summary'),'roughness_summary':v.get('roughness_summary'),
           'connectivity':v.get('largest_connected_passable_fraction_by_slope_deg')} for k,v in reference.items()},
      'n_total':len(candidates),'n_eligible':len(eligible),
      'pareto_candidate_ids':pareto(candidates),'top_by_slope':eligible[:10],
      'top_by_roughness':sorted(eligible,key=lambda c:c['comparison']['mean_roughness_w1_m'])[:10],
      'all_candidates':candidates}
    pathlib.Path(out).write_text(json.dumps(result,indent=2))
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--planet',required=True,help='NASA lunar/Martian DEM in metre-based projected coordinates')
    parser.add_argument('--planet-effres',help='Optional co-registered NASA effective-resolution raster in metres')
    parser.add_argument('--planet-center-xy',nargs=2,type=float,help='Optional projected x y metres for planetary crop')
    parser.add_argument('--earth-center-lonlat',nargs=2,type=float,help='Optional longitude latitude for Earth crop (WGS84)')
    parser.add_argument('--earth',action='append',required=True,help='Earth DEM GeoTIFF; repeat for multiple independent tiles')
    parser.add_argument('--output',default='results.json')
    parser.add_argument('--baselines',default='400,800,1600')
    parser.add_argument('--pixel-m',type=float,default=100)
    parser.add_argument('--reference-size-m',type=float,default=4800)
    parser.add_argument('--earth-size-m',type=float,default=9000)
    parser.add_argument('--window-size-m',type=float,default=4800)
    parser.add_argument('--stride-m',type=float,default=1500)
    args=parser.parse_args()
    result=run(args.planet,args.earth,args.output,
      baselines=tuple(int(t) for t in args.baselines.split(',')),pixel=args.pixel_m,
      reference_size=args.reference_size_m,earth_size=args.earth_size_m,
      window_size=args.window_size_m,stride=args.stride_m,
      effres=args.planet_effres,planet_center=args.planet_center_xy,
      earth_center_lonlat=args.earth_center_lonlat)
    print(json.dumps({'n_candidates':result['n_total'],'eligible':result['n_eligible'],
      'pareto':result['pareto_candidate_ids'],'top_slope':[(x['candidate_id'],x['comparison']['mean_slope_w1_deg']) for x in result['top_by_slope'][:5]],
      'saved_to':args.output},indent=2))

if __name__=='__main__':main()
