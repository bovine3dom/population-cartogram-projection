# Planet island-aware H3-5 fit

## Input and scope

Use the reviewed clean layout from `output/auto-cartogram/owid-clean-v2`.
Its 54,967 cells have SHA-256:

```text
ecb5033efa791e51f6fd3aeb9f857ba74903341040642a60991938fa0f009629
```

The fit retains native component membership and uses 244 declared population
pools. It does not use border-aware fitting. It exports population density but
not city labels. Existing H3-MON datasets stay unchanged during the fit.

## GPU environment

The optional `gpu/` project pins oneAPI and its compiler dependencies. Do not
combine the old GPU environment with the CPU project through `JULIA_LOAD_PATH`.
That combination used incompatible LLVM and GPUCompiler versions on this host.
The new environment passes a two-source GPU fit and balance check.

Run from the repository root:

```sh
julia --project=owid-layout/gpu -e 'using Pkg; Pkg.instantiate()'

ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
OPENBLAS_NUM_THREADS=4 julia --threads=8 --project=owid-layout/gpu \
  owid-layout/gpu/fit.jl \
  output/auto-cartogram/owid-clean-v2 \
  output/auto-cartogram/owid-planet-islands-h3-5 5
```

The driver setting is specific to this host's Intel P630. Other Intel GPUs may
not need it. The program does not fall back to CPU. Add `--resume` after `5` to
resume the same inputs. Resume checks the active GPU project and manifest as
well as the layout, source data, core code, and driver setting.

## Publication

The separate destination is `planet-owid-islands-h3-5-v1` in the H3-MON data
directory. It is not available until the fit and browser checks finish.
The finalizer runs this sequence without requiring another manual export step:

```sh
bash owid-layout/bin/finish-fit.sh 3052741 \
  output/auto-cartogram/owid-planet-islands-h3-5 \
  /home/olie/projects/H3-MON planet-owid-islands-h3-5-v1
```

Progress is recorded in the mapping directory as `finalize-status.txt`.
The finalizer log is `finalize.log`. On success, `h3-mon-url.txt` contains the
local test URL. `browser-published/` contains a screenshot and browser checks
from the actual served files, not local file interception. Manual visual review
is still required. A failed fit or browser check must not be described as ready.

## Work log

- Confirmed the frozen layout and no other active fitting jobs.
- Created an isolated, pinned GPU environment. The device is functional.
- Passed a small GPU fit with zero transport between population pools.
- Started the full-world GPU run on 19 October 2026 at about 07:24 UTC.
  PID: `3052741`. Log: `output/auto-cartogram/planet-fit-logs/fit.log`.
- Re-ran all 44 mapping tests after the GPU signature change. All passed.
- Added a checked publisher. Its eight tests passed. It rejects incomplete jobs,
  changed export files, and existing destination directories.
- Added a finalizer that waits for this fit, checks the export in headless
  H3-MON, publishes a separate dataset, and checks the actual HTTP files.
  It does not change the existing default dataset.
