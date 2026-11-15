"""Presentation maps from run outputs (not part of the website).

Draws, for each reference, every window the run could measure (grey), the nominated
candidates coloured by worst-scale slope distance (degrees), and a dashed line in the colour bar
at the distance between two lunar references (the yardstick). Also draws the scale signature
(median slope vs baseline) of the five closest candidates against the reference.

Usage: python3 plot_candidates.py FEATURE_DIR CANDIDATES_JSON OUT_PREFIX [states.geojson]
Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
"""
import sys, json, glob, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from global_run import LS

YARDSTICK = {"M-CR": ("de Gerlache rim", 3.66), "M-DG": ("Connecting ridge", 3.66),
             "M-MA": ("de Gerlache rim", 3.72), "M-SR": ("Malapert", 4.76),
             "MZ-FLAT": ("a typical real lunar flat-zone window (median)", 1.16),
             "MZ-STEEP": ("a typical real lunar steep-zone window (median)", 2.95)}


def outlines(ax, path):
    if not path or not os.path.exists(path):
        return
    for f in json.load(open(path))["features"]:
        g = f["geometry"]
        polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        for p in polys:
            r = np.array(p[0]); ax.plot(r[:, 0], r[:, 1], color="#9a9a9a", lw=0.5, zorder=1)


def main():
    fdir, cj, pre = sys.argv[1:4]
    states = sys.argv[4] if len(sys.argv) > 4 else None
    lat, lon = [], []
    for f in glob.glob(os.path.join(fdir, "*.npz")):
        z = np.load(f)
        if z["lat"].size:
            lat.append(z["lat"]); lon.append(z["lon"])
    lat = np.concatenate(lat); lon = np.concatenate(lon)
    res = json.load(open(cj))
    for rid, r in res["references"].items():
        c = r["candidates"]
        if not c:
            continue
        fig, ax = plt.subplots(figsize=(12, 7), dpi=150)
        outlines(ax, states)
        ax.scatter(lon, lat, s=0.6, c="#d6d6d6", lw=0, zorder=2, label=f"measured windows ({lat.size:,})")
        cl = np.array([[x["lon"], x["lat"], x["worst_scale_slope_W1_deg"]] for x in c])
        sc = ax.scatter(cl[:, 0], cl[:, 1], c=cl[:, 2], cmap="viridis_r", s=40, edgecolor="black", lw=0.5, zorder=3,
                        label=f"nominated candidates ({len(c)})")
        for k in range(min(5, len(c))):
            ax.annotate(str(k + 1), (cl[k, 0], cl[k, 1]), xytext=(4, 4), textcoords="offset points", fontsize=9, weight="bold", zorder=4)
        cb = fig.colorbar(sc, ax=ax, shrink=0.7)
        cb.set_label("worst-scale slope distance to reference (degrees; lower = closer)")
        if rid in YARDSTICK:
            name, d = YARDSTICK[rid]
            lo, hi = cb.vmin, cb.vmax
            if lo <= d <= hi:
                cb.ax.axhline(d, color="red", ls="--", lw=1.5)
            ax.plot([], [], color="red", ls="--", label=f"yardstick: {name} vs this reference = {d}° (colour-bar line)")
        ax.set_xlim(lon.min() - 1, lon.max() + 1); ax.set_ylim(lat.min() - 1, lat.max() + 1)
        ax.set_aspect(1 / np.cos(np.radians(np.mean(lat))))
        ax.set_xlabel("longitude"); ax.set_ylabel("latitude")
        ax.set_title(f"Earth windows closest in multiscale terrain to {r['meta']['desc'].split(',')[0]}\n"
                     f"Copernicus GLO-90 + ESA WorldCover vs NASA LOLA; 10 km windows; run on {res['n_tiles']} tiles", fontsize=11)
        ax.legend(loc="lower left", fontsize=8)
        fig.tight_layout(); fig.savefig(f"{pre}_{rid}_map.png"); plt.close(fig)

        # scale signature: reference vs five closest candidates
        R = np.load("refs.npz")[rid + "_slope_q"]
        use = [LS.index(L) for L in r["meta"]["baselines"]]
        fig, ax = plt.subplots(figsize=(7, 4.5), dpi=150)
        ax.plot([LS[i] for i in use], [R[i, 24:26].mean() for i in use], "k-o", lw=2.5, label="reference (Moon)")
        for k, x in enumerate(c[:5]):
            m = x["median_slope_deg_by_baseline"]
            ax.plot(LS, [m[str(L)] for L in LS], "-o", lw=1.2, alpha=0.8, label=f"candidate {k+1} ({x['lat']:.2f}, {x['lon']:.2f})")
        ax.set_xscale("log"); ax.minorticks_off(); ax.set_xticks(LS); ax.set_xticklabels([f"{L} m" for L in LS])
        ax.set_xlabel("baseline (plane-fit disc diameter)"); ax.set_ylabel("median slope (degrees)")
        ax.set_title(f"Scale signature: {r['meta']['desc'].split(',')[0]}", fontsize=10)
        ax.legend(fontsize=7); ax.grid(alpha=0.3)
        fig.tight_layout(); fig.savefig(f"{pre}_{rid}_signature.png"); plt.close(fig)
        print("wrote", rid)


if __name__ == "__main__":
    main()
