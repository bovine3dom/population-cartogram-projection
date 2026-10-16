#!/usr/bin/env bash
# Fit a new layout by island group. Keep previous exports unchanged.
set -euo pipefail
if [ "$#" -ne 4 ]; then
  echo 'Usage: run_layout_h3.sh LAYOUT NEW_RUN_ROOT DATASET H3_MON_REPO' >&2
  exit 2
fi
layout=$1
root=$2
dataset=$3
h3mon=$4
[[ "$dataset" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid dataset name' >&2; exit 2; }
[ ! -e "$root" ] && [ ! -e "$h3mon/www/data/$dataset" ] || {
  echo 'Use new run and dataset paths' >&2; exit 2;
}
python=${BORDER_PYTHON:-output/auto-cartogram/geometry-env/bin/python}
project=${BORDER_JULIA_PROJECT:-/home/olie/projects/population-cartogram-projection/examples/uk-h3}
inputs=output/auto-cartogram/world-55000-dissolved-input
cached=output/auto-cartogram/world-10000-transport-r5-grouped/sources.csv
original=output/auto-cartogram/world-55000-h3-5-density
export ZE_ENABLE_ALT_DRIVERS=${ZE_ENABLE_ALT_DRIVERS:-/usr/lib/libze_intel_gpu_legacy1.so.1}
export OPENBLAS_NUM_THREADS=2 OMP_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1
mkdir -p "$root/baseline/layout"
trap 'status=$?; printf "%s exit=%s\n" "$(date -u +%FT%TZ)" "$status" > "$root/process-exit.txt"' EXIT
"$python" - "$layout" "$root/baseline" "$inputs" "$cached" "$original" <<'PY'
import hashlib,json,shutil,subprocess,sys
from pathlib import Path
sys.path.insert(0,'examples/auto-cartogram')
from review_layout import load,connectivity
layout,out,inputs,cached,original=map(Path,sys.argv[1:])
rows,tiles,owner=load(inputs,layout)
assert len(owner)==sum(map(len,tiles.values()))==55000
assert all(len(points)==int(rows[c]['tiles']) and connectivity(points)==1 for c,points in tiles.items())
for name in ('cells.csv','lake-cells.csv','lake-placement.json'):
    if (layout/name).exists():shutil.copyfile(layout/name,out/'layout'/name)
shutil.copyfile(inputs/'groups.csv',out/'groups.csv')
shutil.copytree(original/'labels',out/'labels')
files=[cached,inputs/'groups.csv',*sorted((out/'layout').iterdir()),*sorted((out/'labels').iterdir())]
files += sorted(Path('examples/auto-cartogram').glob('*.py'))+sorted(Path('examples/auto-cartogram').glob('*.jl'))+sorted(Path('examples/auto-cartogram').glob('*.sh'))
files += sorted(Path('examples/continuity').rglob('*.jl'))+sorted(Path('src').rglob('*.jl'))
(out/'run-inputs.json').write_text(json.dumps(dict(layout=str(layout),commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),files={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()}),indent=2)+'\n')
PY
julia=(julia --threads=2 --project="$project")
echo baseline-fit > "$root/phase.txt"
timeout -k 30s 4h "${julia[@]}" examples/auto-cartogram/fit_h3_groups.jl "$cached" "$root/baseline/groups.csv" "$root/baseline/layout/cells.csv" "$root/baseline"
echo baseline-balance > "$root/phase.txt"
timeout -k 30s 2h "$python" examples/auto-cartogram/balance_h3_groups.py "$root/baseline"
echo baseline-export > "$root/phase.txt"
"$python" examples/auto-cartogram/export_h3_groups.py "$root/baseline" \
  output/auto-cartogram/world-dissolved/polygons.geojson /usr/share/iso-codes/json/iso_3166-1.json \
  "$h3mon/www/data/$dataset" --title 'Population density — coarse Kontur with Pacific coast repair (independent island fit)'
cp "$root/baseline/run-inputs.json" "$h3mon/www/data/$dataset/"
node examples/auto-cartogram/review_h3_mon.mjs "$h3mon" "$root/baseline/review" http://127.0.0.1:1983 "$dataset"
echo numerical-export-complete-visual-review-pending > "$root/phase.txt"
