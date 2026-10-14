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
