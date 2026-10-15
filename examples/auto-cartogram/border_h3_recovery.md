# Recovery of the border fit

## 2026-10-15, 14:20 UTC: diagnosis

The first border sweep stopped at China after 180 completed updates. The
10,000-iteration retry did not converge. It did not reach India's update.
The pipeline stopped before extraction or publication.

Checked the saved candidate against every metric in the last completed row.
All values match. The baseline, candidate, settings, and metric files have
recorded SHA-256 hashes. The completed prefix can be reused without refitting.

China has 30,995 source fragments and 9,632 targets. Its largest force component
has magnitude 3,923,442. The final eta is about 0.000001 and the previous
proximal weight is 0.01. This is a severe scale imbalance for the proposal
solve. It is not evidence of an invalid island population assignment.

## Bounded recovery trial

Test proximal weight 1000, with a 2 GiB device cost-cache budget. China's
Float32 cost matrix needs 1,194,175,360 bytes. The earlier 512 MiB budget could
not cache it. Set a 20-minute process limit and at most 2,000 iterations per
temperature stage. Save each fully checked stage separately.

A larger proximal weight penalizes movement away from the accepted plan. It
changes the proposal step, not the objective used to accept that step. Keep
all original eta values, border weights, population constraints, and distortion
limits. Hot continuation stages are warm starts only. A final-temperature
proposal must pass the full checks before any line-search acceptance.

The first trial passed temperature factors 256 through 2, then reached its
20-minute limit during the final stage. This is progress, not an accepted China
update. Resume the checked factor-2 stage in a separate 20-minute process.
Check its input hashes, group, temperature, proximal coefficient, prior,
source geometry, force array, and full masses before reusing its dual vector.
Do not repeat the earlier temperature stages or publish a hot-stage plan.
Final-temperature checks and the objective test are still pending.

The numerical context is consistent with the limitations described in
[Schmitzer's scaling paper](https://arxiv.org/abs/1610.06519). Its abstract
describes slow convergence at small entropy regularization and log-domain
stabilization with epsilon scaling. Read the abstract directly. This reference
does not validate this trial or the chosen proximal weight.

## Safe checkpoint promotion

`promote_h3_recovery.jl` writes a new checkpoint, never over the failed one.
It checks the input hashes, update order, all source and target masses, and
all original distortion limits. It recalculates the original objective and
requires a decrease. Every other group must have the same serialized plan
hash. Copied prefix metrics retain their earlier settings; new settings apply
to recovery updates only. The provenance file states this distinction.

Only a checkpoint with all 182 updates can receive a research completion
marker. Sparse extraction, balancing, export audits, and visual review still
follow. `BORDER_FIT_ROOT` selects this checked recovery checkpoint for the
existing export pipeline.

CPU tests cover interrupted-state inspection, duplicate output guards,
input-metric mismatch, update-order mismatch, stable plan hashes, and rejection
of a proposal that does not improve the objective. They also test a successful
recovery, a checked warm start, and promotion of a complete two-group fixture. No production code or data
has changed. Both user PDF files remain untracked.
