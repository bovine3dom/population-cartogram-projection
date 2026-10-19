#!/usr/bin/env bash
# Wait for an existing fit, check its export, and publish a separate dataset.
set -euo pipefail
if (( $# < 4 || $# > 5 )); then
  echo 'Usage: finish-fit.sh FIT_PID MAPPING_DIR H3_MON_REPO DATASET [ORIGIN]' >&2
  exit 2
fi
pid=$1
mapping=$(realpath "$2")
repo=$(realpath "$3")
dataset=$4
origin=${5:-http://127.0.0.1:1983}
[[ $pid =~ ^[0-9]+$ && $dataset =~ ^[A-Za-z0-9_-]+$ ]]
root=$(cd "$(dirname "$0")/.." && pwd)
status="$mapping/finalize-status.txt"
trap 'rc=$?; if (( rc != 0 )); then printf "failed (exit %s); inspect finalize.log\n" "$rc" > "$status"; fi' EXIT
printf 'waiting for fit\n' > "$status"
while kill -0 "$pid" 2>/dev/null; do sleep 10; done
# Refuse incomplete jobs before attempting to read or display their files.
julia --project="$root" -e 'using JSON; JSON.parsefile(joinpath(ARGS[1],"mapping-job.json"))["complete"] || error("Fit is incomplete")' "$mapping"
printf 'checking local export in H3-MON\n' > "$status"
node "$root/test/h3-mon.mjs" "$repo" "$mapping/h3-mon" "$mapping/browser-preview" "$origin" h3-mon 'x=0&y=15&z=-1'
printf 'publishing separate dataset\n' > "$status"
julia --project="$root" "$root/bin/publish.jl" "$mapping" "$repo/www/data/$dataset"
printf 'checking published HTTP dataset\n' > "$status"
node "$root/test/h3-mon.mjs" "$repo" - "$mapping/browser-published" "$origin" "$dataset" 'x=0&y=15&z=-1'
printf 'ready; browser checks passed; screenshots available for visual review\n' > "$status"
printf '%s/?data=%s/population_density_hilo.arrow&cartogram=%s/cartogram_weights_hilo.arrow#x=0&y=15&z=-1\n' "$origin" "$dataset" "$dataset" > "$mapping/h3-mon-url.txt"
