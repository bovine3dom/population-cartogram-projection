#!/usr/bin/env bash
# Run from the repository root. Keep the earlier island export unchanged.
set -euo pipefail
if [ "$#" -ne 3 ]; then
  echo 'Usage: run_border_h3.sh ORIGINAL_RUN PREPARED_BORDER_RUN H3_MON_REPO' >&2
  exit 2
fi
original=$1
out=$2
h3mon=$3
project=${BORDER_JULIA_PROJECT:-/home/olie/projects/population-cartogram-projection/examples/uk-h3}
python=${BORDER_PYTHON:-output/auto-cartogram/geometry-env/bin/python}
export ZE_ENABLE_ALT_DRIVERS=${ZE_ENABLE_ALT_DRIVERS:-/usr/lib/libze_intel_gpu_legacy1.so.1}
export OPENBLAS_NUM_THREADS=2 OMP_NUM_THREADS=1
export CONTINUITY_OUTER_STEPS=1 CONTINUITY_PROXIMAL=.01 CONTINUITY_RETRY_FACTOR=256
julia=(julia --threads=2 --project="$project")
fit=${BORDER_FIT_ROOT:-"$out/border-fit"}
dataset=${BORDER_DATASET:-planet-auto-55000-h3-5-islands-border}
[[ "$dataset" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid dataset name' >&2; exit 2; }
destination="$h3mon/www/data/$dataset"
[ ! -e "$destination" ] || { echo "Export already exists: $destination" >&2; exit 2; }
trap 'status=$?; printf "%s exit=%s\n" "$(date -u +%FT%TZ)" "$status" > "$out/pipeline-exit.txt"' EXIT
# Check the preparation inputs before any expensive work or publication.
"$python" - "$out" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1])
for name,expected in json.loads((root/'provenance.json').read_text())['files'].items():
    if name.endswith('.jl'):continue  # The preparation script has its own saved hash.
    if hashlib.sha256(Path(name).read_bytes()).hexdigest()!=expected:raise ValueError('Preparation input changed: '+name)
PY
if [ ! -f "$out/tuned/tuning-complete.txt" ]; then
  timeout -k 30s 12h "${julia[@]}" examples/continuity/tune_baselines.jl "$out" - "$out/tuned"
fi
if [ ! -d "$out/fit" ]; then
  timeout -k 30s 1h "${julia[@]}" examples/auto-cartogram/border_h3_groups.jl seed "$out" "$out/tuned"
fi
if [ ! -f "$fit/research-fit-complete.txt" ]; then
  timeout -k 30s 12h "${julia[@]}" examples/continuity/refit_tuned.jl "$out" "$out/tuned" "$fit"
fi
timeout -k 30s 2h "${julia[@]}" examples/auto-cartogram/border_h3_groups.jl extract "$original" "$out" "$fit"
timeout -k 30s 2h "$python" examples/auto-cartogram/balance_h3_groups.py "$out"
if [ ! -f "$out/border-audit.json" ]; then
  timeout -k 30s 1h "${julia[@]}" examples/auto-cartogram/audit_h3_borders.jl "$original" "$out" "$fit"
fi
"$python" - "$out/border-audit.json" <<'PY'
import json,sys
if not json.load(open(sys.argv[1]))['numerical_gate']:raise ValueError('Border audit failed; do not publish')
PY
"$python" examples/auto-cartogram/export_h3_groups.py "$out" \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  /usr/share/iso-codes/json/iso_3166-1.json "$destination" \
  --title 'Population density — automatic 55,000 tiles, island groups and border cohesion'
cp "$out/border-audit.json" "$out/contacts.csv" "$out/group-codes.csv" "$out/provenance.json" "$destination/"
cp "$fit/fit/metrics.csv" "$fit/fit/settings.csv" "$fit/fit/country-etas.csv" "$destination/"
if [ -f "$fit/recovery.json" ]; then cp "$fit/recovery.json" "$destination/"; fi
node examples/auto-cartogram/review_h3_mon.mjs "$h3mon" "$out/review" \
  http://127.0.0.1:1983 "$dataset"
date -u > "$out/numerical-export-complete.txt"
echo 'Export and browser capture complete. Human visual review is still required.'
