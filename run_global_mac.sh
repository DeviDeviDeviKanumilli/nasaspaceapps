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
TOTAL=$(grep -c . "$LIST")

# progress monitor: one summary line every 60 s (per-tile detail goes to $OUT/run.log)
progress() {
  local start=$(date +%s) start_n=$(ls "$OUT" | grep -c '\.npz$' || true)
  local err0=$(grep -c ' ERROR ' "$OUT/run.log" 2>/dev/null || true); err0=${err0:-0}
  while true; do
    sleep 60
    local n=$(ls "$OUT" | grep -c '\.npz$' || true)
    local el=$(( $(date +%s) - start ))
    local err=$(( $(grep -c ' ERROR ' "$OUT/run.log" 2>/dev/null || echo 0) - err0 ))
    python3 - "$n" "$TOTAL" "$start_n" "$el" "$err" <<'PY'
import sys, time
n, total, n0, el, err = map(int, sys.argv[1:])
rate = (n - n0) / el if el else 0
eta = (total - n) / rate if rate > 0 else float("nan")
eta_s = time.strftime("%H:%M", time.localtime(time.time() + eta)) if rate > 0 else "--:--"
print(f"[{time.strftime('%H:%M')}] {n}/{total} tiles ({100*n/total:.1f}%) | {rate*60:.0f} tiles/min | "
      f"~{eta/3600:.1f} h left, done ~{eta_s} | tile errors this session: {err} (retried automatically)", flush=True)
PY
  done
}
progress & MON=$!
trap 'kill $MON 2>/dev/null' EXIT
echo "Running $TOTAL tiles. Summary every minute; full log: $OUT/run.log"

for i in $(seq 1 10); do
  caffeinate -i python3 global_run.py "$OUT" 8 "$LIST" > "$OUT/stdout.log" 2>&1 || true
  missing=$(python3 -c "import os;L=[l.strip() for l in open('$LIST') if l.strip()];print(sum(not os.path.exists(os.path.join('$OUT',n+'.npz')) for n in L))")
  echo "pass $i: $missing tiles missing"
  [ "$missing" = "0" ] && break
done
kill $MON 2>/dev/null || true
echo "Feature run finished. Comparing with Moon/Mars references..."
python3 compare.py "$OUT" $RES/global_terrain_candidates.json
python3 make_manifest.py "$OUT" $RES/global_terrain_candidates.json $RES/manifest_global.json "$LIST" $RES/coverage_global.png
cd ..
git add results_global
git commit -m "Global terrain results (all land except Antarctica) from Mac run"
git push
echo "DONE: results pushed"
