#!/bin/bash
# Global terrain run (all land except Antarctica) on a Mac, then push the small result files.
# Usage, from the repo root:  bash run_global_mac.sh
# Resumable: if it stops, run the same command again.
set -e
cd "$(dirname "$0")"
python3 -m pip install -q -r requirements.txt
cd engine
OUT="$HOME/terrain_features"; LIST=tiles_noantarctic.txt; RES=../results_global
mkdir -p "$OUT" "$RES"
for i in $(seq 1 10); do
  caffeinate -i python3 global_run.py "$OUT" 8 "$LIST"
  missing=$(python3 -c "import os;L=[l.strip() for l in open('$LIST') if l.strip()];print(sum(not os.path.exists(os.path.join('$OUT',n+'.npz')) for n in L))")
  echo "pass $i: $missing tiles missing"
  [ "$missing" = "0" ] && break
done
python3 compare.py "$OUT" $RES/global_terrain_candidates.json
python3 make_manifest.py "$OUT" $RES/global_terrain_candidates.json $RES/manifest_global.json "$LIST" $RES/coverage_global.png
cd ..
git add results_global
git commit -m "Global terrain results (all land except Antarctica) from Mac run"
git push
echo "DONE: results pushed"
