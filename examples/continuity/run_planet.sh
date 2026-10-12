#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
    echo 'usage: run_planet.sh PREPARED_OUTPUT NEW_H3_MON_FOLDER' >&2
    exit 2
fi
cd "$(dirname "$0")/../.."
out=$1
destination=$2
[[ -d "$out" && ! -e "$destination" && ! -e "$destination.pending" ]]
export ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1
export OPENBLAS_NUM_THREADS=4
trap 'status=$?; printf "%s exit_status=%s\n" "$(date -u +%FT%TZ)" "$status" > "$out/job-status.txt"' EXIT
printf '%s pid=%s\n' "$(date -u +%FT%TZ)" "$$" > "$out/job-started.txt"
julia --threads=8 --project=examples/uk-h3 examples/continuity/planet.jl fit "$out"
julia --threads=8 --project=examples/uk-h3 examples/continuity/planet.jl publish "$out" "$destination"
