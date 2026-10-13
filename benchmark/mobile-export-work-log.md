# Mobile export work log

## Window and goal

Start: 2026-10-13 09:45 UTC. End: 2026-10-14 01:45 UTC.
Reduce the experimental planet export for mobile browsers. Aim well below
100 MB for both data files. Record file size, browser memory, load time, and
changes to the map. Keep the fitted plans and full export as references.
Do not change production, UK, or Germany datasets. Keep H3-MON stopped except
for isolated, headless checks that do not start its normal service.

## 09:45 UTC: inspect the consumer and plan measurements

The full export has 120,753,287 rows and uses 8.24 GB. It keeps 99.999% of
each source cell's transport mass. This is a research export, not a suitable
browser dataset. The current browser loads the entire file and builds row
indexes, so file compression alone will not fix its memory use.

The browser uses target-normalized `weight_mean` for aggregation. It also
uses source-to-target support for navigation. Keep both source and target
coverage, the original labels, and source population totals. Measure errors
in target population, geographic means, source means, and conditional weights.

Compare these approaches before choosing a default:

1. Cull by source weight, with explicit source and target coverage guards.
2. Cull by population contribution to each target, with a source anchor.
3. Use narrower numeric columns where their error is negligible.
4. If necessary, adjust the sparse weights to reduce marginal or moment error.

Do not confuse an approximate browser export with the full fitted transport.
Keep the full-plan mass checks unchanged. Test the Arrow files with the actual
JavaScript dependencies before publication. Compression must not require an
unsupported Arrow codec or conceal excessive decoded memory.

Documentation checked: Arrow.jl write API, loaders.gl Arrow reading guide,
and the Arrow JavaScript compression issue. The installed browser uses
Apache Arrow 19.0.1 through loaders.gl. Its actual decoder is the final check.

- https://arrow.apache.org/julia/stable/reference/
- https://loaders.gl/docs/arrowjs/developer-guide/reading-and-writing
- https://github.com/apache/arrow-js/issues/109

## 11:00 UTC: culling profiles and sparse weight adjustment

Built a source and target index for all 120,753,287 rows. Saved separate
country caches for bounded tests. The reference has 387,294 source cells,
54,942 country-target pairs, and 1,715 labelled source cells. Eleven target
coordinates occur in more than one country.

Simple culling causes large errors. Keeping four rows per source, plus
coverage guards, gives an estimated 44 MB transport file. But its 99th
percentile geographic mean error is 114 km. Keeping 32 rows per target gives
an estimated 56 MB and a 62 km error. These estimates exclude the density
file and assume Float32 population. Neither is a safe default.

Tested nonnegative weight adjustment with linear constraints. It preserves
source totals, target population, target geographic means, source forward
means, and optionally target mean population density. Each labelled source
keeps its original anchor with at least half its original weight. These
constraints do not preserve arbitrary data values or the full transport.

A Germany reference test reduced 100,137 rows to 7,746 in 121 seconds.
Maximum geographic mean error was below 0.001 metres. Maximum relative
target population error was 2.3e-9. However, median target total variation
was 0.494. This is an approximation, not lossless compression. This test
did not change the Germany dataset.

Added a separate Julia environment with HiGHS 1.26.0. Direct crossover in
its native HiGHS 1.15.1 crashed before worker initialization. A zero-iteration
solve initializes the workers before crossover. No installed package was
changed. Unit tests pass: 25 export checks and 13 moment checks.

Two dense 128-source blocks from the US and China failed crossover with a
600-second limit. Their results were rejected. The first log did not include
the failure status or elapsed time; this was not proof of a timeout. Test smaller
target blocks next, then merge their sparse results. Keep the full reference
and do not publish a reduced file until independent checks pass.

HiGHS references:

- https://ergo-code.github.io/HiGHS/dev/interfaces/julia/
- https://jump.dev/JuMP.jl/stable/packages/HiGHS/

## 11:10 UTC: bounded blocks and numerical scaling

The smaller blocks exposed a numerical failure, not a time limit. Tiny
weights and redundant moment equations caused crossover to return an unknown
status. Scale the block weights and remove the known shared equations with
pivoted QR. Still check every original equation, including those removed.
A new small-weight regression test passes. There are now 16 moment checks.

A dense US block fell from 217,800 rows to 9,535. Four target-block stages
used 7.3 seconds in crossover. A China block fell from 420,379 to 23,612.
Some small China blocks failed the nonnegative-weight check and retained
their input. Later merges succeeded. No failed result was accepted.

Added a country driver with stage checkpoints and full-country checks.
Started US and China trials. Each stage merges source and target blocks.
The driver retains the input of any failed block. This can increase file
size, but cannot silently install an invalid sparse solution.

## 11:30 UTC: file schema and data-query probes

Added a flat Arrow writer with Int16 coordinates, UInt16 country codes,
UInt32 H3 halves, and Float32 weights. Population remains Float64. Labels
stay on their original source anchors. Recompute target weights across
shared coordinates after Float32 conversion. Omit the unused all-missing
prominence column; the consumer uses population as its fallback.

The 7,746-row Germany test file is 266,274 bytes. It is a local test file,
not a replacement for the Germany dataset. There are 41 export, writer, and
quality checks. Actual JavaScript decoding is still pending.

Added ten data-query probes. For the Germany sparse test, the 99th percentile
error in distance from London is 0.135 km. Density is preserved to numerical
precision. But synthetic noise has a 0.221 error on a zero-to-one scale.
A synthetic half-missing field loses coverage at two of 571 targets and has
a 0.984 error in log density at the 99th percentile. These probes are not
real travel-time data. The sparse file must be described as an approximation.
Preserved map geometry does not imply exact results for arbitrary queries.
