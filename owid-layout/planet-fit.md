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

## Work log

- Confirmed the frozen layout and no other active fitting jobs.
- Created an isolated, pinned GPU environment. The device is functional.
- Passed a small GPU fit with zero transport between population pools.
- Prepared the full-world run. Export and browser review are still pending.
