# Continuity sharpness findings

## Earlier fix

The earlier method was automatic eta selection:

- `cc2dfdd` added the tuner to the CUDA pipeline.
- `12745e0` reduced the connection budget from `10*(sources+targets)` to
  `2*(sources+targets)` and extended eta candidates down to `1e-7`.
- `6be9396` moved the tuner to KernelAbstractions.

The tuner counts connections needed to retain 99.5% of each source's mass.
It selects the converged eta nearest the budget. The old code also used a
loose aggregate mass tolerance of 0.02. The new trials do not copy that limit:
target L1 must remain at most 1e-4 and maximum relative error at most 0.001.
Some old production masses fail these stricter limits.

The continuity planet runner bypassed the tuner and used eta 0.002 everywhere.
Its export retained 99.999%, rather than 99.5%. Its half-step updates also kept
part of the broad initial plan: after four accepted half steps, at least 6.25%
remains explicitly. The saved China plan retained 30.76% of its broad seed.
Mobile moment reduction removed rows but largely preserved spatial spread.
Thus smaller files did not establish that the underlying mapping was sharp.

## Matched measurements

These figures use the same 353,480 sources in the 152 fitted countries.
Support is measured at 99.5% in every row. Spatial RMS uses target coordinates;
cell spacing is 2 at factor 1. The old production export already omits tails.

| Mapping | Connections/H3 | Mean source spatial RMS |
| --- | ---: | ---: |
| Old production | 1.837 | 0.412 |
| Old full continuity | 147.973 | 5.868 |
| Old mobile continuity | 5.738 | 5.739 |
| New tuned baseline | 1.906 | 0.426 |
| New border pass 1 | 2.004 | 0.715 |
| New border pass 2 | 2.172 | 1.026 |
| New border pass 3 | 2.312 | 1.254 |

For the same 277,637 low-population sources, the old production support is
1.607. The new baseline needs 1.634 and border pass 1 needs 1.773. Here, low
population means less than one tenth of a uniform country target quota.

The trials use per-country eta, maximum step 1, proximal weight 0.01, and the
previous border weights and distortion checks. They use KernelAbstractions
and oneAPI. A hotter numerical continuation helps sharp priors converge;
only the original final eta and a fully checked plan can be accepted.

More passes are not automatically better for this task:

| Fit | Border RMS, km | Reversed triangle area, million km² |
| --- | ---: | ---: |
| New tuned baseline | 695.2 | 0.509 |
| New pass 1 | 654.0 | 3.324 |
| New pass 2 | 646.1 | 3.046 |
| New pass 3 | 641.3 | 2.487 |
| Previous broad four-pass fit | 613.5 | 8.019 |

The old four-pass geometry figures use its cached checked moments. New pass
figures use independent full-plan audits. No row in this table is a solved
continuity map. The run stopped after three complete passes within the time
budget, not after convergence. Pass 1 is the preferred sharpness-first preview;
passes 2 and 3 give smaller border errors but more source spread.
Additional small, distant contributions can increase source
spatial spread even when connection counts remain low.

The third full plan passes its mass checks, but its 99.999% sparse export
slightly exceeds the target L1 limit. Retaining 99.99999% restores the limit.
The tighter third-pass pair is 41.1 MB after packing. Publication now checks
post-extraction masses and rejects an export that fails. The first-pass preview
passes with the original 99.999% fraction.

## Sharpness-first preview

The first-pass preview is kept separately at:

```text
output/continuity-sharpness/planet-h3-5-factor1-continuity-sharp-pass1/
```

It contains both Arrow files, the density JSON, hashes, full update metrics,
eta settings, mass checks, and quality reports. It is not published. The
existing H3-MON dataset and application are unchanged, and the service stays
off. This is H3-5 at factor 1, not a higher-factor dataset.

The export includes all 387,294 planet sources, 54,942 country target cells,
and 54,931 physical target cells. The 54 unfitted countries retain their earlier
source distributions. All 1,715 labelled sources remain.

- Whole-planet support at 99.5%: **2.026 cells/H3**, versus **1.875** before
  border fitting, about 8% more.
- Stored distinct connections: **2.851/H3**, versus **2.310** before.
- Mean source spatial RMS: **0.701**, versus **0.425** before and **5.285** in
  the previous mobile continuity export.
- Transport: **28,322,066 bytes**. Density: **5,035,946 bytes**.
- Combined Arrow size: **33,358,012 bytes**, before HTTP compression.

The fitted export retains 99.999% before source normalization. It passes the
strict fitted-country target mass limits after extraction. Mobile packing
uses the existing numeric types and Arrow dictionaries, not moment reduction.
It removes 3,109 unlabelled roundoff tails and adds 52 split rows to preserve
shared-cell country ownership. Packing changes target total variation by at
most 2.62e-8. It does not preserve the old broad mapping; it preserves the new
sharp fit. No gzip handling was added. Production zstd is unchanged.

The first-pass files pass an isolated headless browser check with a mobile-size
viewport and three viewport cycles. The 128 MiB V8 heap-limit test is not a
128 MiB total-memory claim: reported post-collection heap use is 39.6 MB and
backing storage is 120.1 MB, before other browser costs. Real mobile-device
memory and interaction performance still need testing.

## Reuse the method

The production solver and ordinary planet command retain their defaults.
Use the explicit research path:

```sh
julia --threads=8 --project=examples/uk-h3 examples/continuity/tune_baselines.jl \
  PARENT_ROOT POSES_CSV CALIBRATION_ROOT
julia --threads=8 --project=examples/uk-h3 examples/continuity/refit_tuned.jl \
  PARENT_ROOT CALIBRATION_ROOT NEW_FIT_ROOT
```

Set the oneAPI driver environment as required by the machine. Use a process
timeout. The refit checks geometry, masses, eta, and support again, and saves
complete-pass snapshots. It does not create a publication marker. Use
`audit_sharpness.jl` to compare immutable snapshots with source diagnostics
from the old export. Inspect spatial spread, borders, and folds as well as
connection counts. See [compact plans](../examples/continuity/compact.md).

For an already assembled sparse planet Arrow file, `mobile/pack_mapping.jl`
checks a direct mobile packing without a moment solver. See
[mobile exports](../examples/continuity/mobile/readme.md).

The chronology, failed trials, checks, and artifact paths are in the
[work log](continuity-sharpness-work-log.md).
