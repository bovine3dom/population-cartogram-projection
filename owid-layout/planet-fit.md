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
  output/auto-cartogram/owid-planet-islands-h3-5-v2 5 --resume
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
bash owid-layout/bin/finish-fit.sh 3063647 \
  output/auto-cartogram/owid-planet-islands-h3-5-v2 \
  /home/olie/projects/H3-MON planet-owid-islands-h3-5-v1
```

Progress is recorded in the mapping directory as `finalize-status.txt`.
The finalizer log is `finalize.log`. On success, `h3-mon-url.txt` contains the
local test URL. `browser-published/` contains a screenshot and browser checks
from the actual served files, not local file interception. Manual visual review
is still required. A failed fit or browser check must not be described as ready.

## Balance performance fix and restart

The original process was stopped on 19 October 2026 at 08:54 UTC. Its watcher
was stopped first. It had completed 33 pools, or 5,072 tiles. The old run remains
at `output/auto-cartogram/owid-planet-islands-h3-5`.

A live stack trace located the CPU work in the new balance loop, not the GPU
solver. The loop used values whose concrete types were not known to the compiler.
It allocated about 1.30 GB in a 100-iteration China benchmark. The fixed loop uses
a typed array function and allocates about 42 MB for the complete benchmark call.
Its allocation count does not grow with the numerical iteration count.

The same 100 iterations took 1.25 seconds before the fix and 0.089 seconds after
the fix. A full balance of the earlier saved China shard took 44 seconds. It
passed the population checks for 30,995 sources and 9,632 tiles. This is a
benchmark on the older layout, not a completed fit of the new China layout.

The target tolerance is again `1e-4` (0.01%), with 50,000 iterations per support
attempt. These are the earlier planet pipeline settings. Source weights must
still sum to one within `1e-9`. Population cannot cross pool boundaries.
The GPU solver itself has not changed.

The workflow now saves all raw fits before CPU balancing. Each fit and balance
has a separate timing. A failed balance no longer loses the raw fit. China had
no raw checkpoint in the stopped job, so its GPU fit must run again.

`bin/recover-balanced.jl` creates a separate recovery job. It permits only the
two reviewed balance/checkpoint code changes. It rejects changes to input data,
the solver, dependencies, resolution, or backend. Each recovered shard must pass
its file hash and all population checks at the original `1e-6` tolerance.
All 33 shards passed and were copied byte-for-byte. Normal resume still rejects
changed code. The recovery job records both old and new code hashes.

The current run is `output/auto-cartogram/owid-planet-islands-h3-5-v2`.
It started at 09:05 UTC with PID `3063647`. Its log is
`output/auto-cartogram/planet-fit-logs/fit-v2.log`. The publication watcher now
tracks this process, not the stopped job. The destination dataset name is unchanged.

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
- Fixed CPU balance type instability and added an allocation regression test.
- Added raw checkpoint, damaged-checkpoint, and checked recovery tests.
- Rechecked and preserved 33 completed pools. Restarted the remaining fits.
