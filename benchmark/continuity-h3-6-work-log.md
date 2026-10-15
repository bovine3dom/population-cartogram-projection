# H3-6 planet work log

## 2026-10-14 20:25 UTC: request and scope

Remove the H3-MON viewport-geometry feature by rewriting its local history.
Keep the other memory improvements. Prepare a higher-resolution planet mapping
from the sharpness-first result. Compare target subdivision factors before a
large run. Keep existing datasets and other research jobs unchanged. The user
has started H3-MON; do not stop or restart that service.

Use KernelAbstractions and oneAPI for fitting. Keep diagnostics under
`output/continuity-h3-6/`. Do not treat a finer source ID as new population data:
read the original resolution-8 population and check aggregation first.

## 20:34 UTC: viewport feature removed

Rebased H3-MON `router`, dropping `64d093a` and its two dependent rendering-test
commits, `b6ed87d` and `5dceff7`. Replayed the six other commits. The new head is
`bfbd50e`. The feature, setting, helper, and tests are absent from branch history.
No force push was made. The old head is recorded in the ignored diagnostics.

Removed the metadata option from both continuity datasets and the local sharp
preview. Preserved the user's `cartogramLineProbe` setting. The mobile publisher
will no longer generate the removed option. No Arrow file changed.

All 68 unit checks, actual Arrow dictionary checks, and the build pass. The
first full headless rendering suite passes dictionary and cartogram checks but
hits a desktop animation-frame timeout. A repeat is running; do not report the
entire rendering suite as passed yet.

Factor 5 means 25 times as many target cells, not five times. H3-6 has up to
seven children per H3-5 cell. A dense all-pair fit could therefore require about
175 times the pair work of the previous run. Factor 3 gives nine times as many
targets and is a better initial size match. A population aggregation audit and
bounded refinement pilot must precede a whole-planet choice. No H3-6 result is
published yet.

## 20:49 UTC: browser comparison and population audit

The second rendering run has the same animation timeout. A detached worktree
at the old H3-MON head also fails the held-frame title check. Thus the failure
also occurs before this rebase; its cause is not established. The temporary
worktree is removed. The user service was not stopped or restarted.

The source audit found 2,003,260 populated H3-6 cells within the old H3-5
coverage. Direct aggregation of all their resolution-8 children gives 0.933%
more population than the old input. Do not rescale this difference away or
claim identical coverage. The old country extracts used polygon filtering.
The first regional pilot instead uses the existing native H3-6 country extract.
The global parent-inherited aggregation remains an audit, not a final input.

Added a bounded-edge, fixed-graph OT solver for research. It uses KA and oneAPI
and checks host Float64 source and target masses. It does not contain a border
penalty: the pilot uses the accepted coarse map as a guide. Graph restriction
and geographic costs change the model, so mass checks alone cannot approve a
planet result. All 13 initial checks pass on CPU and GPU. With graph-budget and
Int32 guards, all 15 CPU checks pass. A real Angola factor-2 pilot is running.
No H3-6 planet fit has started.

## 21:00 UTC: native extraction and first refinement measurements

Added a native H3-8 polygon extraction and H3-6 aggregation script. It retains
one owner per source and reports overlap, cross-country assignment, and missing
countries. Angola exactly matches the previous independent country extraction:
19,020 sources and 36,407,494 people. The whole-planet extraction audit is now
running with a 90-minute limit.

The factor-2 Angola pilot has 1,016 targets and 2,354,740 graph edges. At eta
`1e-4`, the solve passes all mass checks in 63 seconds, but its 99.5% support
ratio is 3.25, above the coarse result's 2.45. It is not yet sharp enough.
A direct jump to `1e-5` converges too slowly; stopped that trial after 5,000
iterations without accepting its unfinished stage. Saved valid stages remain.
A smaller temperature step is under test. This is not evidence that the full
planet can yet use the restricted geographic model without a quality loss.

## 21:15 UTC: factor comparison rejects the simple geographic model

All 15 fixed-graph tests now pass on both CPU and oneAPI. The factor-2 Angola
stage at eta `5e-5` passes the tighter L1 `1e-5` check. Its support ratio is 2.264,
compared with 2.451 for the coarse result. Spatial RMS in coarse grid units is
2.118 versus 1.832. The next, colder stage fails the tighter limit after 5,000
iterations; it is not accepted. The general pilot uses the existing planet
L1 limit `1e-4`, with the unchanged maximum relative limit `0.001`.

Factor 3 has 2,286 targets and 5,254,540 graph edges. At eta `5e-5`, its support
ratio is 3.971. More importantly, positive triangle area is 142,057 square km,
versus 10,846 for the interpolated guide. Mass checks pass, but geometry does
not. Reject this simple geographic refinement for publication. A diagnostic
now tests the existing fold gradient with a penalty on guide displacement and
a proximal update. Its first aggressive step failed to converge; it did not
change any accepted dataset. This diagnostic is not a shipped fitting method.

The whole-planet polygon extraction is still running. Large coast polygons
are slow. The H3 experimental centre-containment fill gives exactly the same
cells on all three Angola polygons; the main polygon takes 9.1 seconds versus
18.6 seconds for the old fill. An Australia speed check is running separately.
No installed package has changed. API reference: https://h3geo.org/docs/api/regions/.

## 21:38 UTC: native planet input complete

The experimental Australia fill also hit its ten-minute limit. Do not use its
Angola speedup as a planet estimate. Replaced full polygon filling with direct
classification of populated H3 cell centres. Latitude bins index original
polygon edges; polygons are not simplified. Closed rings and split antimeridian
edges are required. The six geometry checks pass, including 1,000 comparisons
with an independent ray test. All 66,618 regional sources match the existing
Angola, DRC, and Zambia native extracts after the documented owner merge.

The planet preparation completes with 1,992,902 sources and all 206 countries.
Population is 7,947,202,049, which is 68,417 below the old input. No population
was rescaled to conceal this difference. There are 16,449 shared H3-6 cells;
assigning each to its largest country share moves 14,958,488 people between
country totals but preserves total selected population. All 1,715 old label
parents have native children. A separate worldwide check compares all
1,992,902 H3-6 centres with H3 polygon fills across all 206 countries: zero
mismatches. The slow full-resolution fill was stopped. The final extraction at
`output/continuity-h3-6/native-planet-final/` matches the diagnostic Arrow file
byte for byte (SHA-256 `24e89ff22a8fbc725c0ecd2c08ff2d9e11725339933bbc0a91cfd6079dfb0ec8`).

The factor-3 geometry correction reduces positive triangle area from 142,057
to 12,910 square km, but its support ratio rises to 4.248. Factor 2 reaches a
ratio of 2.453, close to the coarse 2.451, but still has excess fold area. Neither
pilot is a published planet result. Colder temperatures and the subdivision
scaling of the fold term remain under test. With smaller temperature steps and
the original planet mass limits, factor 3 reaches a support ratio of 1.965 at
eta `1.25e-5` in 64 seconds for the last stage. It still needs geometry correction;
a sharper transport alone does not preserve the map.

## 22:07 UTC: preserve coarse flows before adding detail

The colder factor-3 geometry trial still has 71,338 square km of positive
triangle area after nine accepted updates. The next inner solve fails. Its
partial output is not suitable for publication.

Tested a hierarchy that keeps the coarse parent-to-target flows as additional
constraints. First adjust those flows to the native source population. On
Angola this gives target L1 error `7.6e-7` and a 3.39 km RMS shift of coarse
centres. The fine graph has 2,876,337 edges and 61,917 group constraints. Five
small three-way solver checks pass on both CPU and oneAPI. The warm real-data
stage passes mass checks but is too broad; its colder stage fails the group
mass limit. This solver remains an ignored diagnostic, not a shipped feature.

A simpler sequential hierarchy is now under test: first split each coarse
source into its native children while preserving coarse flows, then split each
target using the resulting fixed source contributions. Both steps use the
existing checked two-way KA solver. This avoids the extra three-way solver and
keeps the coarse target means fixed during target subdivision. Fine-grid folds
and sharpness still need independent checks. No whole-planet fit has started.

## 22:19 UTC: checkpoint; higher-resolution publication blocked

The sequential source split passes strict mass checks at eta `1e-6` and has a
99.5% support ratio of 1.657. Further cooling is not needed for that step. The
factor-3 target split passes mass checks but again increases positive triangle
area: 130,585 square km at eta `1e-6`, versus 10,846 in the interpolated guide.
Its support ratio is 3.015. Stopped the colder target trial after it exceeded
1,000 iterations. No unfinished stage is accepted.

These trials show that correct masses, coarse flow constraints, and a small
support count do not establish good fine-grid geometry. Do not publish these
candidates. A fine-grid continuity fit is still needed; simple subdivision is
not an adequate replacement. Factor selection remains open. No H3-6 planet
fit or publication has completed, and no full-planet fitting job is running.
All jobs from this work session have stopped. Input files and diagnostics remain
available for the next fit. No production Arrow file changed.

H3-MON remains at rebased head `bfbd50e`, with a clean tracked tree and no
`viewportGeometry` introduction in the current `src/app.js` history. The user
service was not stopped or restarted by this work. This repository's changes
are committed in small steps; no core `src/` file changed.

## 22:51 UTC: new six-hour window

The user requests continued H3-6 work at several factors. The new datasets will
coexist with H3-5; they are not replacements. Work window: 2026-10-14 22:51 UTC
to 2026-10-15 04:51 UTC. Use separate output folders and keep the current H3-MON
branch and published files unchanged. Continue with KA and oneAPI.

Priorities: complete a native-source planet baseline; compare subdivision
factors; measure sharpness, fine-grid geometry, border continuity, and file size.
Do not block all native-resolution work on success of a higher-factor model.
Label experimental results and incomplete fits explicitly. A bounded adaptive
geometry trial is running while the common planet pipeline is prepared.

## 23:09 UTC: common native-source pipeline

The adaptive fine-grid trial reduces fold area but broadens support to more
than six cells per source. Stopped it and retained its checkpoints. It is not
ready for publication.

Added a common source-refinement pipeline. It first adjusts the coarse flows
to native parent population, then splits each flow among the native children.
It retains the old target grid as a factor-1 baseline. Higher factors can use
this common result. This is not a new border-optimization pass. The runner
records any proportional-inheritance fallback rather than calling it optimized.

On native Angola, source refinement passes all checks. Its 99.5% ratio is 2.371,
versus 2.451 in the coarse reference. The conservative packed trial has 73,920
rows, target L1 `9.18e-7`, maximum target relative error `6.20e-6`, and all 11
city labels. The runner will also test smaller row selections and keep them
only if mass and target-centre checks pass.

All 12 hierarchy checks pass on CPU and oneAPI. All 18 sparse-solver checks
pass on both backends, including deadline checks. Added internal time limits
so a difficult country cannot consume the whole six-hour window. The native
planet baseline will run before further target-grid experiments.


## 23:37 UTC: local mass correction and short-row kernels

Stopped the first planet job during the US coarse projection. Both nearby-cell
KL projections stalled. No country from that run was published. A direct
minimum-mass transfer passes mass checks but shifts US target centres by
72.4 km RMS. A local path transfer reduces this to 23.9 km RMS. It transfers
each intermediate cell's own mixture, rather than sending the original source
across the full path. This preparation is not an entropy optimum.

Added serial-per-row KA kernels for sparse layouts with at most 16 edges per
row on average. Long layouts retain the existing parallel reduction. All 21
sparse checks pass on CPU and oneAPI, including mixed layouts and launch bounds.
The US native split now completes its first valid stage in 20.4 seconds and
its second in 12.5 seconds. The colder third stage fails; the second remains
the accepted result. Total split time is 155.5 seconds, including that failed
stage. Its 99.5% ratio is 2.011. Packed output has 699,178 rows, target L1
1.35e-6, maximum relative error 8.34e-6, and all 68 city labels.

Four local-transfer checks and 16 hierarchy checks on each backend pass.
These cover conservation, separate grid components, and reduced long-distance
transfer on a three-cell path. The revised planet run uses a new output root.


## 23:46 UTC: binary checks and higher-factor diagnostics

Added an independent native export path and geometry reports. Nine binary
checks and eight geometry checks pass. The real Angola export has 18,842 native
sources, 254 targets, and all 11 city labels. Its transport uses 1,301,370 bytes;
density uses 138,682 bytes. Dictionary encoding is lossless. Density alone uses
Float32, with maximum relative error 5.92e-8. Source populations remain Float64.
No HTTP compression setting or H3-MON code changed.

The headless Chromium check loads this export in 5.2 seconds without errors.
It reads all native source cells and all labels. This small-country check does
not establish the memory cost of the full planet. The initial browser attempt
could not find the Playwright browser; the repeat uses installed Chromium.

The planet run has completed the US, China, Brazil, Australia, and Argentina.
No planet export is complete yet. Higher-factor diagnostics now constrain fine
target moments instead of accepting geographic OT output with large folds.
This diagnostic uses CPU linear programming after the KA/oneAPI native split;
it is not a replacement GPU fitting method. Conditional source variables avoid
loss of low-population rows at the LP feasibility floor. On Angola, factors 2
and 3 retain all masses without fallback. Their 99.5% ratios are 2.515 and
2.769. Fine geometry, factor 5, and whole-planet cost still need checks.


## 23:58 UTC: native planet complete; separate factor runs next

All 206 native-source countries finish without proportional-inheritance
fallback. There are 1,992,902 sources and 6,187,416 stored rows. The global
99.5% support ratio is 2.132, versus 2.026 in the sharp H3-5 export.
On the same 3,292 border edges, mean-position RMS changes from 649.672 to
650.178 km. Internal RMS changes from 97.655 to 97.075 km. Positive triangle
area changes from 3.337 to 3.350 million square km. These are small changes
to the reference, not evidence that its existing defects are solved.

The independent binary audit passes all sources, masses, and 1,715 labels.
The first native export is 156,027,314 transport bytes plus 17,937,338 density
bytes. It exceeds the earlier 100 MB file goal and is not yet published.
A GPU row-selection and mass-projection test reduces US rows by 34%, but its
maximum target shift and density error are too large. The less aggressive
test reduces rows by 21%, with a 0.815 km maximum shift and 0.295% density
error. Neither diagnostic has replaced the accepted native fit.

Stopped an export that spent minutes sorting with a boxed table capture.
Its log records 4.4 billion allocations. Bound the sort arrays separately and
built the city-parent lookup once. The revised full export completes. All nine
binary tests pass again. The earlier Angola browser check used low-precision
geographic rendering: the supplied value 6 was parsed as false, not as an H3
resolution. A default-precision planet browser check remains necessary.

Added a separate, resumable moment-subdivision runner. All 15 unit checks pass.
It preserves coarse flows and constrains fine XYZ and density means. On Angola,
factors 2 and 3 have ratios 2.444 and 2.760 with no fallback. Factor 5 has one
20-second timeout, so its uniform fallback raises the ratio to 5.788. The
factor-5 runner will allow 120 seconds per cell. These outputs are diagnostics,
not published replacements. CPU LP projection follows the native KA/oneAPI fit.


## 00:17 UTC: factor 2 complete; storage and browser limits

Factor 2 completes all 206 countries. It has 219,768 country targets and a
99.5% ratio of 2.500. There are 16 uniform cell fallbacks out of 54,942 coarse
targets. Mean border separation is 646.615 km on 6,584 edges. Positive triangle
area is 3.650 million square km, versus 3.350 million in the native factor-1
map. The largest positive triangle is smaller. This is not a fold-free map.
Its independent binary audit passes all native sources and city names.
Factors 3 and 5 remain running, with a hard stop at 04:30 UTC.

Added lossless per-batch dictionary packing. The native factor-1 files decrease
from 174.0 MB to 125.8 MB with no row or value change. Python tests pass, and
all columns pass independent JavaScript and Julia batch-reader comparisons.
Arrow.jl 2.8.1 joins replacement dictionaries incorrectly with Arrow.Table;
Arrow.Stream passes. The format and reader restriction are documented.
The IPC data is uncompressed. Production zstd settings remain unchanged.

Default-precision headless checks load the full native map and the packed
stream without errors. They retain about 1.3 GB of backing storage plus 102 MB
of JavaScript heap after collection. Turning off the existing high-precision
flag does not reduce this result. File reduction alone does not make this
two-million-cell geographic layer safe for a phone. No viewport feature was
restored, and no native planet dataset is published yet.

A bounded moment-packing diagnostic reduces US rows by 27% while preserving
target mass, geographic XYZ, and density. Its maximum target total variation
is 0.00814 and maximum forward mean shift is 0.142 coarse grid units. Some
low-population source distributions change substantially. Stricter forward
bounds and explicit city and navigation-anchor protection are under test.
This is an approximate export experiment, not a change to the accepted fit.
