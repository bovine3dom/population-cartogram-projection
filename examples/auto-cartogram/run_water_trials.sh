#!/usr/bin/env bash
# Run from the repository root. Do not publish these layouts.
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'Usage: run_water_trials.sh NEW_OUTPUT_ROOT DEADLINE_UTC' >&2
  exit 2
fi
out=$1
deadline=$(date -u -d "$2" +%s)
[ ! -e "$out" ] || { echo 'Output already exists' >&2; exit 2; }
mkdir -p "$out"
printf 'margin\tstarted_utc\texit_code\n' > "$out/status.tsv"
export OPENBLAS_NUM_THREADS=2 OMP_NUM_THREADS=1
python=output/auto-cartogram/geometry-env/bin/python
for margin in 0 1; do
  remaining=$((deadline-$(date -u +%s)-30))
  if [ "$remaining" -le 0 ]; then echo 'Deadline reached'; exit 0; fi
  limit=$((remaining<7200 ? remaining : 7200))
  started=$(date -u +%FT%TZ)
  code=0
  timeout -k 20s "${limit}s" "$python" examples/auto-cartogram/run_compact_pipeline.py \
    output/auto-cartogram/world-55000-dissolved-input \
    output/auto-cartogram/world-55000-shape-islands \
    output/auto-cartogram/world-dissolved/polygons.geojson \
    "$out/margin-$margin" \
    --flow-geometry output/auto-cartogram/world-55000-mainland-flow/flow/areas_cartogram.geojson \
    --sites output/auto-cartogram/world-55000-population-sites/sites.csv \
    --stretch 1.2 --flow-guide-weight 8 --sigma 4 --iterations 300 \
    --mainland-only --float-islands --borrow-coast --fixed-border-rounds 16 \
    --shared-islands --fixed-land-anchors --archipelagos --bridge-groups \
    --water-radius 8 --water-margin "$margin" > "$out/margin-$margin.log" 2>&1 || code=$?
  printf '%s\t%s\t%s\n' "$margin" "$started" "$code" >> "$out/status.tsv"
done
echo 'Trials finished. Check the logs, water access, and images. No layout is approved.'
