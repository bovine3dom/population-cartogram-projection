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
