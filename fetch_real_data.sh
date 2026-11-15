#!/bin/sh
# Optional exploratory download helper. Run from directory containing this script.
# These are verified provider publication paths; the server/network may block downloads.
set -eu
cd "$(dirname "$0")"
mkdir -p real_data
NASA='https://pgda.gsfc.nasa.gov/data/LOLA_5mpp/Site04/Site04_final_adj_5mpp_surf.tif'
EARTH='https://copernicus-dem-90m.s3.amazonaws.com/Copernicus_DSM_COG_30_N40_00_W075_00_DEM/Copernicus_DSM_COG_30_N40_00_W075_00_DEM.tif'
echo 'Downloading NASA Shackleton Rim LRO/LOLA Site04 elevation (~41 MB)...'
curl --fail --location --retry 3 --output 'real_data/Site04_final_adj_5mpp_surf.tif' "$NASA"
echo 'Downloading Copernicus GLO-90 tile N40W075...'
curl --fail --location --retry 3 --output 'real_data/Copernicus_GLO90_N40_W075.tif' "$EARTH"
python - <<'PY'
from pathlib import Path
import rasterio
for path in Path('real_data').glob('*.tif'):
    with rasterio.open(path) as d:
        print(path.name,d.width,d.height,d.crs,d.res,d.nodata)
PY
printf '\nNow run:\n'
printf '%s\n' 'python experiment.py --planet real_data/Site04_final_adj_5mpp_surf.tif --earth real_data/Copernicus_GLO90_N40_W075.tif --earth-center-lonlat -74.58 40.34 --output REAL_nj_experiment.json'
