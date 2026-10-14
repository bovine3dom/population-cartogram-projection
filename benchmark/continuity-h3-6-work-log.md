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
