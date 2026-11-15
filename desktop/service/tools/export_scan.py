"""Export one Field Station scan for people to look at: its photos and a rotatable 3D mesh.

    cd desktop/service && .venv/bin/python tools/export_scan.py <scan_id or prefix> [--out DIR]

Writes DIR (default ~/Desktop/Field Scan export - <title>):
  photos/             the phone's full-resolution photos (copied byte for byte), or the D435 colour image
  mesh_viewer.html    self-contained: drag to rotate, scroll to zoom, right-drag to pan. No internet needed.
  mesh.obj            the same mesh for other 3D software (Blender, MeshLab, Preview)
  README.txt          what the files are and what they are not

The mesh is the scan's own: ARKit's scene-reconstruction mesh for iPhone scans (derived by ARKit), or Field Station's
grid mesh for D435 scans. Nothing is smoothed, filled or invented here. Colours in the viewer are by height only.
If the scan's camera track failed the plausibility check (tracking drift), the viewer says so on screen.

Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import shutil
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fieldstation.bundle import default_home  # noqa: E402
from fieldstation.tracking_check import check as tracking_check  # noqa: E402


def read_mesh_ply(p: Path) -> tuple[np.ndarray, np.ndarray]:
    """Vertices (N,3 float32) and triangles (M,3 uint32) from a binary little-endian or ASCII PLY."""
    raw = p.read_bytes()
    end = raw.index(b"end_header") + len(b"end_header")
    end = raw.index(b"\n", end) + 1
    header = raw[:end].decode("ascii", "replace").splitlines()
    fmt = next(line.split()[1] for line in header if line.startswith("format"))
    elements, cur = [], None
    for line in header:
        t = line.split()
        if t[:1] == ["element"]:
            cur = {"name": t[1], "count": int(t[2]), "props": []}
            elements.append(cur)
        elif t[:1] == ["property"] and cur is not None:
            cur["props"].append(t[1:])
    sizes = {"char": "i1", "uchar": "u1", "int8": "i1", "uint8": "u1", "short": "i2", "ushort": "u2", "int16": "i2",
             "uint16": "u2", "int": "i4", "uint": "u4", "int32": "i4", "uint32": "u4", "float": "f4", "float32": "f4",
             "double": "f8", "float64": "f8"}
    if fmt == "ascii":
        lines = raw[end:].decode("ascii").split("\n")
        i = 0
        verts = faces = None
        for el in elements:
            if el["name"] == "vertex":
                names = [pr[-1] for pr in el["props"]]
                arr = np.array([[float(x) for x in lines[i + k].split()] for k in range(el["count"])])
                verts = arr[:, [names.index("x"), names.index("y"), names.index("z")]].astype(np.float32)
            elif el["name"] == "face":
                faces = np.array([[int(x) for x in lines[i + k].split()[1:4]] for k in range(el["count"])], np.uint32)
            i += el["count"]
        return verts, faces
    if fmt != "binary_little_endian":
        raise SystemExit(f"unsupported PLY format {fmt}")
    off = end
    verts = faces = None
    for el in elements:
        if el["name"] == "face" and el["props"] and el["props"][0][0] == "list":
            cnt_t, idx_t = sizes[el["props"][0][1]], sizes[el["props"][0][2]]
            extra = [(f"p{i}", "<" + sizes[pr[0]]) for i, pr in enumerate(el["props"][1:])]
            # every face in these files is a triangle: fixed-size records
            dt = np.dtype([("n", "<" + cnt_t), ("v", "<" + idx_t, (3,))] + extra)
            rec = np.frombuffer(raw, dt, el["count"], off)
            if not (rec["n"] == 3).all():
                raise SystemExit("mesh has non-triangle faces; not supported here")
            faces = rec["v"].astype(np.uint32)
            off += dt.itemsize * el["count"]
        else:
            dt = np.dtype([(pr[-1], "<" + sizes[pr[0]]) for pr in el["props"]])
            rec = np.frombuffer(raw, dt, el["count"], off)
            off += dt.itemsize * el["count"]
            if el["name"] == "vertex":
                verts = np.stack([rec["x"], rec["y"], rec["z"]], 1).astype(np.float32)
    if verts is None or faces is None:
        raise SystemExit("no vertex/face elements in the mesh")
    return verts, faces


VIEWER = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<style>
:root{--bg:#f4f2ee;--ink:#1d1f21;--muted:#5d6266;--warn:#8a2a1b;--warnbg:#fbe9e5}
@media (prefers-color-scheme:dark){:root{--bg:#121416;--ink:#e8e6e1;--muted:#9aa0a5;--warn:#ffb4a6;--warnbg:#3a1d18}}
html,body{margin:0;height:100%;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,system-ui,sans-serif}
#c{position:fixed;inset:0;width:100%;height:100%;touch-action:none;cursor:grab}
#info{position:fixed;left:16px;top:16px;max-width:min(560px,calc(100% - 32px));background:color-mix(in srgb,var(--bg) 88%,transparent);padding:10px 12px;border-radius:8px}
#info h1{font-size:16px;margin:0 0 4px}#info p{margin:2px 0;color:var(--muted)}
.warn{color:var(--warn)!important;background:var(--warnbg);padding:6px 8px;border-radius:6px;margin-top:6px!important}
button{font:inherit;margin-top:6px;padding:4px 10px;border-radius:6px;border:1px solid var(--muted);background:transparent;color:var(--ink);cursor:pointer}
</style></head><body>
<canvas id="c"></canvas>
<div id="info"><h1>__TITLE__</h1>
<p>__DESC__</p>
<p>Drag to rotate · scroll or pinch to zoom · right-drag or shift-drag to pan. Colour = height (not measured colour).</p>
__WARN__
<button id="reset">Reset view</button></div>
<script>
const P=new Float32Array(Uint8Array.from(atob("__POS__"),c=>c.charCodeAt(0)).buffer);
const I=new Uint32Array(Uint8Array.from(atob("__IDX__"),c=>c.charCodeAt(0)).buffer);
const cv=document.getElementById('c'),gl=cv.getContext('webgl',{antialias:true});
if(!gl||!gl.getExtension('OES_element_index_uint')){document.getElementById('info').insertAdjacentHTML('beforeend','<p class="warn">This browser cannot draw the mesh (WebGL unavailable). Open mesh.obj in a 3D app instead.</p>');}
// flat normals: split vertices per triangle so every face shades by its own orientation
const nT=I.length/3,pos=new Float32Array(nT*9),nor=new Float32Array(nT*9);let ymin=1e9,ymax=-1e9;
for(let t=0;t<nT;t++){const a=I[3*t]*3,b=I[3*t+1]*3,c=I[3*t+2]*3;
 const ux=P[b]-P[a],uy=P[b+1]-P[a+1],uz=P[b+2]-P[a+2],vx=P[c]-P[a],vy=P[c+1]-P[a+1],vz=P[c+2]-P[a+2];
 let nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx;const l=Math.hypot(nx,ny,nz)||1;nx/=l;ny/=l;nz/=l;
 [a,b,c].forEach((k,j)=>{pos.set([P[k],P[k+1],P[k+2]],t*9+j*3);nor.set([nx,ny,nz],t*9+j*3);ymin=Math.min(ymin,P[k+1]);ymax=Math.max(ymax,P[k+1]);});}
const vs=`attribute vec3 p,n;uniform mat4 M;uniform float y0,y1;varying vec3 vn;varying float h;void main(){vn=n;h=(p.y-y0)/max(1e-6,y1-y0);gl_Position=M*vec4(p,1.);}`;
const fs=`precision mediump float;varying vec3 vn;varying float h;uniform vec3 L;
vec3 ramp(float t){t=clamp(t,0.,1.);return mix(mix(vec3(.23,.35,.55),vec3(.55,.62,.45),smoothstep(0.,.5,t)),vec3(.86,.62,.38),smoothstep(.5,1.,t));}
void main(){float d=abs(dot(normalize(vn),L));gl_FragColor=vec4(ramp(h)*(.35+.65*d),1.);}`;
function sh(t,s){const o=gl.createShader(t);gl.shaderSource(o,s);gl.compileShader(o);return o}
const pr=gl.createProgram();gl.attachShader(pr,sh(gl.VERTEX_SHADER,vs));gl.attachShader(pr,sh(gl.FRAGMENT_SHADER,fs));gl.linkProgram(pr);gl.useProgram(pr);
function buf(a,name){const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,a,gl.STATIC_DRAW);const l=gl.getAttribLocation(pr,name);gl.enableVertexAttribArray(l);gl.vertexAttribPointer(l,3,gl.FLOAT,false,0,0)}
buf(pos,'p');buf(nor,'n');gl.uniform1f(gl.getUniformLocation(pr,'y0'),ymin);gl.uniform1f(gl.getUniformLocation(pr,'y1'),ymax);
gl.enable(gl.DEPTH_TEST);
const C=__CENTER__,R=__RADIUS__;let yaw=0.6,pitch=0.45,dist=R*2.6,tx=C[0],ty=C[1],tz=C[2];
function mul(a,b){const o=new Float32Array(16);for(let i=0;i<4;i++)for(let j=0;j<4;j++){let s=0;for(let k=0;k<4;k++)s+=a[k*4+j]*b[i*4+k];o[i*4+j]=s}return o}
function draw(){const w=cv.clientWidth*devicePixelRatio,h=cv.clientHeight*devicePixelRatio;if(cv.width!==w||cv.height!==h){cv.width=w;cv.height=h}
 gl.viewport(0,0,w,h);const bg=getComputedStyle(document.body).backgroundColor.match(/\d+/g).map(Number);gl.clearColor(bg[0]/255,bg[1]/255,bg[2]/255,1);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);
 const ex=tx+dist*Math.cos(pitch)*Math.sin(yaw),ey=ty+dist*Math.sin(pitch),ez=tz+dist*Math.cos(pitch)*Math.cos(yaw);
 let fx=tx-ex,fy=ty-ey,fz=tz-ez;let l=Math.hypot(fx,fy,fz);fx/=l;fy/=l;fz/=l;let sx=fy*0-fz*1,sy=fz*0-fx*0,sz=fx*1-fy*0;l=Math.hypot(sx,sy,sz)||1;sx/=l;sy/=l;sz/=l;
 const ux=sy*fz-sz*fy,uy=sz*fx-sx*fz,uz=sx*fy-sy*fx;
 const V=new Float32Array([sx,ux,-fx,0,sy,uy,-fy,0,sz,uz,-fz,0,-(sx*ex+sy*ey+sz*ez),-(ux*ex+uy*ey+uz*ez),fx*ex+fy*ey+fz*ez,1]);
 const f=1/Math.tan(0.5*0.8),near=Math.max(dist/1000,1e-4),far=dist+R*20,asp=w/h;
 const Pm=new Float32Array([f/asp,0,0,0,0,f,0,0,0,0,(far+near)/(near-far),-1,0,0,2*far*near/(near-far),0]);
 gl.uniformMatrix4fv(gl.getUniformLocation(pr,'M'),false,mul(Pm,V));gl.uniform3f(gl.getUniformLocation(pr,'L'),-fx*0.6+ux*0.5,-fy*0.6+uy*0.5,-fz*0.6+uz*0.5);
 gl.drawArrays(gl.TRIANGLES,0,nT*3)}
let drag=null;cv.addEventListener('pointerdown',e=>{cv.setPointerCapture(e.pointerId);drag={x:e.clientX,y:e.clientY,pan:e.button===2||e.shiftKey};cv.style.cursor='grabbing'});
cv.addEventListener('pointermove',e=>{if(!drag)return;const dx=e.clientX-drag.x,dy=e.clientY-drag.y;drag.x=e.clientX;drag.y=e.clientY;
 if(drag.pan){const s=dist*0.0015;tx-=Math.cos(yaw)*dx*s;tz+=Math.sin(yaw)*dx*s;ty+=dy*s}else{yaw-=dx*0.008;pitch=Math.max(-1.55,Math.min(1.55,pitch+dy*0.008))}draw()});
cv.addEventListener('pointerup',()=>{drag=null;cv.style.cursor='grab'});cv.addEventListener('contextmenu',e=>e.preventDefault());
cv.addEventListener('wheel',e=>{e.preventDefault();dist*=Math.exp(e.deltaY*0.0015);draw()},{passive:false});
document.getElementById('reset').onclick=()=>{yaw=0.6;pitch=0.45;dist=R*2.6;tx=C[0];ty=C[1];tz=C[2];draw()};
addEventListener('resize',draw);matchMedia('(prefers-color-scheme: dark)').addEventListener('change',draw);draw();
</script></body></html>
"""


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("scan", help="scan id or unique prefix")
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--home", type=Path, default=default_home())
    a = ap.parse_args()
    found = sorted((a.home / "scans").glob(f"scan-{a.scan}*"))
    if len(found) != 1:
        raise SystemExit(f"{len(found)} scans match {a.scan!r}")
    d = found[0]
    man = json.loads((d / "scan.json").read_text())
    title = ((man.get("observation") or {}).get("title") or "").strip() or f"Scan {man['scan_id'][:8]}"
    out = a.out or Path.home() / "Desktop" / f"Field Scan export - {re.sub(r'[^A-Za-z0-9 ._-]+', '_', title)} ({man['scan_id'][:8]})"
    out.mkdir(parents=True, exist_ok=True)

    # photos, byte for byte
    (out / "photos").mkdir(exist_ok=True)
    n_ph = 0
    for p in sorted((d / "photos").glob("*.jpg")) if (d / "photos").is_dir() else []:
        shutil.copy2(p, out / "photos" / p.name)
        n_ph += 1
    for name in ("color.png", "color_0000.png"):
        if (d / name).exists():
            shutil.copy2(d / name, out / "photos" / name)
            n_ph += 1

    # the scan's own mesh
    mesh = next((d / m for m in ("mesh_arkit.ply", "mesh_grid.ply") if (d / m).exists()), None)
    if mesh is None:
        raise SystemExit("this scan has no mesh (mesh_arkit.ply / mesh_grid.ply)")
    v, f = read_mesh_ply(mesh)
    used = np.unique(f)
    remap = np.full(len(v), -1, np.int64)
    remap[used] = np.arange(len(used))
    v, f = v[used], remap[f].astype(np.uint32)
    with open(out / "mesh.obj", "w") as fo:
        fo.write(f"# {title} ({man['scan_id']}), from {mesh.name}; metres, frame {(man.get('coordinate_frame') or {}).get('name')}\n")
        np.savetxt(fo, v, "v %.5f %.5f %.5f")
        np.savetxt(fo, f + 1, "f %d %d %d")

    center = np.median(v, 0)
    radius = float(np.percentile(np.linalg.norm(v - center, axis=1), 95)) or 1.0
    tc = tracking_check(d)
    warn = ""
    if tc and not tc["trustworthy"]:
        warn = '<p class="warn">Unreliable positions: ' + esc(" ".join(tc["warnings"])) + "</p>"
    origin = man.get("origin", "")
    what = ("ARKit scene-reconstruction mesh (derived by ARKit on the iPhone, not raw LiDAR)" if mesh.name == "mesh_arkit.ply"
            else "Field Station grid mesh from the D435 depth image (derived, no hole filling)")
    when = (man.get("captured_at_utc") or {}).get("start") if isinstance(man.get("captured_at_utc"), dict) else None
    desc = (f"{what}. {len(v):,} vertices, {len(f):,} triangles, about {2 * radius:.2f} m across (95% of vertices). "
            f"Units: metres. Source: {origin}{', captured ' + when[:16].replace('T', ' ') + ' UTC' if when else ''}. "
            "Surfaces the sensor did not see are missing, not filled.")
    html = (VIEWER.replace("__TITLE__", esc(title)).replace("__DESC__", esc(desc)).replace("__WARN__", warn)
            .replace("__POS__", base64.b64encode(v.astype("<f4").tobytes()).decode())
            .replace("__IDX__", base64.b64encode(f.astype("<u4").tobytes()).decode())
            .replace("__CENTER__", json.dumps([round(float(x), 5) for x in center])).replace("__RADIUS__", f"{radius:.5f}"))
    (out / "mesh_viewer.html").write_text(html)
    (out / "README.txt").write_text(
        f"{title}\nscan_id {man['scan_id']}\n\n"
        f"photos/          {n_ph} image(s), copied unchanged from the scan.\n"
        f"mesh_viewer.html open in any browser; drag to rotate. Works offline.\n"
        f"mesh.obj         the same mesh for Blender / MeshLab / Preview.\n\n"
        f"{desc}\n"
        + (f"\nWARNING: {' '.join(tc['warnings'])}\n" if tc and not tc['trustworthy'] else "")
        + "\nPhotos may show people. Check before sharing: the Space Apps submission must not show minors.\n"
        "Exported by Field Station tools/export_scan.py (written with AI assistance, Claude by Anthropic).\n")
    print(json.dumps({"out": str(out), "photos": n_ph, "vertices": int(len(v)), "triangles": int(len(f)),
                      "across_m": round(2 * radius, 3), "tracking_ok": None if tc is None else tc["trustworthy"]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
