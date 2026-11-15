"""Run once on an EXISTING output folder made before the 15 Nov fix: deletes tile files that were skipped because
WorldCover could not be read (outside Antarctica), so the next global_run.py pass retries them.
Usage: python3 recheck_landcover_skips.py OUT_DIR"""
import glob, os, sys
import numpy as np
from global_run import parse
n = 0
for f in glob.glob(os.path.join(sys.argv[1], "*.npz")):
    z = np.load(f)
    meta = [str(x) for x in z["meta"]] if "meta" in z.files else []
    if len(meta) > 1 and meta[1] == "False" and parse(meta[0])[0] >= -60:
        os.remove(f); n += 1
print(n, "tiles queued for retry")
