"""Plot results of artificial data only."""
import json
from pathlib import Path
import matplotlib.pyplot as plt
j=json.loads((Path(__file__).parent/'synthetic_results.json').read_text())
a=j['all_candidates']
fig,ax=plt.subplots(figsize=(8,5))
for i,c in enumerate(a):
    d=c['comparison'];x=d['mean_slope_w1_deg'];y=d['mean_roughness_w1_m']
    ax.scatter(x,y,s=55)
    ax.annotate(str(i+1), (x,y),textcoords='offset points',xytext=(5,5),fontsize=8)
ax.set(xlabel='Mean slope-distribution Wasserstein distance (degrees)',
       ylabel='Mean residual-roughness Wasserstein distance (meters)',
       title='Synthetic GeoTIFF comparison: candidate distances (NOT real NASA data)')
ax.grid(alpha=.25)
fig.tight_layout();fig.savefig(Path(__file__).parent/'synthetic_candidate_distances.png',dpi=180)
