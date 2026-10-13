# Continuity performance work log

## Window

Start: 2026-10-12 05:51 UTC. End: 2026-10-13 05:51 UTC.
Use KernelAbstractions and oneAPI on the Intel HD Graphics P630. Keep production
files unchanged. Record correctness checks and measured timings separately.

## 05:54 UTC: baseline and plan

Stopped the detached dense planet job after all 152 country baselines finished.
The cost and baseline caches remain available. No planet output was published.
The oneAPI baseline solves ran from 05:46:17 to 05:51:02, including compilation.
China took about 120 seconds; India took 42 seconds. Country cost preparation
had taken about six minutes. These are more useful measurements than the earlier
unmeasured extrapolation to weeks. They do not include the outer continuity fit.
The process used about 23 GB resident memory when stopped.

Targets for this window:

1. Represent plans with dual variables and update history, not dense matrices.
2. Preserve proximal updates and damped mixtures. Do not silently replace them.
3. Calculate masses, means, entropy, and exports in bounded blocks.
4. Cache unchanged country statistics and use coarse inputs for pose selection.
5. Compare against dense CPU and oneAPI references, then measure real workloads.

The existing matrix-free research path still constructs dense host costs and
plans. Removing only the device cost matrix is not enough. An exact compact
update history can represent both the proximal log-plan term and damped mixtures.
Its evaluation cost grows with accepted update count; this needs measurement.

Documentation checked: KernelAbstractions upstream API and kernel documentation.
The installed version is 0.9.44. The upstream 0.10 KernelInterface split does not
apply to this environment. No dependency upgrade is planned.

## 06:28 UTC: first compact solver

Implemented implicit plans, proximal history, exact damped mixtures, bounded
host statistics, cached country moments, and matrix-free oneAPI reductions.
The online reduction evaluates each history once per pair. Source and target
cost offsets improve Float32 conditioning. No transport entries are pruned.

The compact tests pass on CPU and oneAPI: 23 checks on each backend. Tests compare
three repeated proximal updates and a two-pass country-wise fit against dense
plans. They check masses, objectives, saved plans, and invalid inputs.

An early real-data Mali–Burkina Faso comparison used three passes at H3-5,
factor 1. Dense plan storage was 6,167,120 bytes. Compact storage was 548,836
bytes, about 11 times smaller. Final objectives differed by 0.00000345; all-edge
border RMS differed by about two metres. Cold fit times were 80 seconds dense
and 100 seconds compact. These include compilation and are not warmed throughput
measurements. The compact run used the earlier two-pass reduction, before the
online reduction and two-sided cost offsets. Its files end in `mali-compact-v1`.
One earlier compact attempt was stopped by a command timeout before any baseline
completed; it is not a benchmark result. The newer process-measurement wrapper
uses a fresh parent process for each peak-RSS measurement.

## 07:00 UTC: bounded device work and coarse poses

The H3-6/factor-2 dense Africa test completed one pass in 236 seconds, including
compilation. Its plans occupy 954 MB. The corresponding implicit test completed
two country updates, then the Intel driver reset during the DRC reduction.
The kernel journal records a fence expiration and GPU preemption timeout. This
is a failed run, not a completed performance result.

Added bounded output ranges to minimum, materialization, and Sinkhorn kernels.
The implicit pair budget decreases with history depth. Added a bounded cache for
the active country's device cost, with a 512 MiB default. Larger costs remain
implicit. Tests force very small launch ranges and compare cached and uncached
CPU and oneAPI solves, including rotated initial plans. They pass after fixing
index-variable lifetime across KernelAbstractions CPU barriers.

Added coarse H3-4 pose selection for the compact planet path. Native H3-5 solves
check proposed rotations against the native objective and limits. Dense mode
remains available as a reference. The complete small planet workflow passes in
both modes, including mass checks, city labels, and atomic H3-MON publication.
No real planet result has been published yet.

## 07:27 UTC: bound queued command lists

The uncached H3-6 retry passed the two smaller countries, then remained in a
Level Zero command submission while resident memory grew past 6 GB. A Julia
SIGUSR1 profile showed the command-list submission and reclaim path. The kernel
journal showed no new reset. Stopped this diagnostic run after about 12 minutes.
Added a synchronization after at most eight launches and at the end of each
reduction. This also keeps temporary offset buffers alive until their kernels
finish. CPU and oneAPI compact tests still pass. A new large-case test is needed;
the stopped run is not evidence of convergence or a completed timing.

## 08:13 UTC: cached large-case results and driver memory

The cached H3-6 Africa test completed three passes and a warm repeat. Compact
plans use 7.54 MB; dense plans use 954 MB, about 126 times more. Cold fit times
were 439 seconds compact and 559 seconds dense. Warm times were 345 and 475
seconds. Final objectives differ by 0.00000124; cross-border RMS differs by
1.2 metres. Independent block checks pass source and target mass limits. The
largest target centre difference is 355 metres, so these are close, not identical,
solutions. Plan L1 differences are below 0.00037 per country.

However, peak resident memory was 32.0 GiB compact versus 8.0 GiB dense. The
compact solver allocated less Julia memory, but native command lists accumulated.
The installed oneAPI code creates a Level Zero command list for each launch;
its Julia finalizer releases the native allocation. Julia's heap checks cannot
measure those allocations. Synchronization alone does not release them.

Added periodic garbage collection after synchronized launch batches, and after
completed compact solves. Host log and weight buffers now remain in use across
blocks instead of being allocated for each block. CPU and oneAPI compact tests
pass. A new large-case measurement is running to check actual peak memory. No
memory improvement is claimed from plan storage alone. No SDK files were changed.

## 08:29 UTC: lower measured memory

The revised cached test completed three passes and a warm repeat. Peak process
resident memory fell to 2.29 GiB, versus 8.00 GiB for the dense reference and
32.04 GiB for the earlier compact run. Warm fit time was 346 seconds, versus
475 seconds dense: 27% less time. Cold fit time was 436 seconds. Warm Julia
allocations fell from 108.6 GB dense to 1.44 GB compact. These allocation totals
are cumulative, not peak memory. Process RSS does not measure all GPU residency.

The result retains 7.54 MB of compact plans. Final cross-border RMS differs
from the dense result by 1.17 metres. The test uses three African countries at
H3-6, factor 2, with eta 0.002. It is not a tuned H3-6 planet quality test.
The full planet input is now prepared in a separate compact output directory.
Production datasets and the stopped dense study remain unchanged.

## 08:57 UTC: uncached solve and host work

The uncached H3-6 test completed one pass in 724 seconds. It passed the mass
checks, and the kernel journal shows no new GPU reset. The cached path is faster;
the uncached path is a bounded-memory fallback, not a speed improvement. Research
CPU and oneAPI tests, the small planet publication test, and core tests pass.

A host-only profile found dynamic dispatch through the compact statistics field.
Gave this field a concrete optional named-tuple type. Existing saved plans still
load. Also replaced temporary column copies with views in border, fold, and
metric calculations. No objective formula changed. On the saved Africa case,
100 warm repetitions gave these mean times:

| Operation | Before | Typed statistics and views |
| --- | ---: | ---: |
| Border penalty and force | 78.2 ms | 1.73 ms |
| Fold penalty and force | 21.3 ms | 1.03 ms |
| Metrics | 3.82 ms | 1.79 ms |

Border calculation allocations fell from 16.2 MB to 1.05 MB per call. These are
host-operation measurements, not full-solver speedups. Compact and research
CPU/oneAPI tests pass after the changes, including finite-difference gradients.

## 09:03 UTC: country preparation

Started the compact planet fit with a 2 GiB active cost cache. A startup profile
showed LLVM compiling `hcat` with country-sized splatted argument lists. Stopped
this attempt before any baseline solve. The prepared input remains intact.
Replaced the splat with a fixed three-row matrix and a coordinate loop. A real
H3-6 input check passes coordinate shape and unit-length checks. This removes
country-size-specific compilation without changing coordinates or costs.

## 09:30 UTC: sharp coarse poses and checkpoint geometry

The revised planet run completed all coarse baselines, then stopped at a
135-degree Eswatini pose. That coarse case has 12 source cells and nine targets.
Both compact and dense fixed-temperature solves stalled above the mass limit.
A test with decreasing temperatures reached the original eta 0.002 and passed
the original tolerance. Added this retry only for planet baselines and poses.
All stages remain on oneAPI. A failed retry still stops the fit. No mass limit
was relaxed. The planet run has resumed from its country caches.

A separate restart check found that separately loaded, equal geometries could
get duplicate history entries because their object identities differ. Geometry
reuse now checks exact field values after the fast identity check. A serialization
regression test passes. The running planet process retains its earlier loaded
code; subsequent processes will use this additional storage reduction.

## 09:57 UTC: continuation for coupled solves

All native planet baselines and pose checks completed. The first coupled pass
then stopped at Canada: strong border forces required more than 10,000 fixed-
temperature iterations. The last balanced country checkpoint is preserved.
A direct retry of that exact Canada problem, with the full effective temperature
scaled by 16, 8, 4, 2, and 1, converged in 1,100 total iterations. The final
residual was 0.0000984 at the original temperature and proximal weight.

Moved temperature continuation into a shared compact solve wrapper. It retries
after 1,000 fixed-temperature iterations instead of waiting for 10,000. The
prior plan stays fixed throughout the retry; intermediate stages do not add
history. CPU and oneAPI tests force this path and compare its final plan with
the dense proximal reference. All tests pass. The final objective and mass
limits are unchanged. Archive the partial first pass and restart from the saved
native seeds, so the published study still has ten complete passes.

## 10:13 UTC: reduction-kernel check

Paused the planet process from 10:01:13 to 10:02:53 UTC for an isolated kernel
comparison, then resumed it. On a five-million-pair sample from the DRC input,
100 cached dual iterations took 0.86–0.98 seconds with the online reduction,
versus 1.10–1.13 seconds with the dense two-pass reduction. Final centered duals
differed by less than 0.000000002. Keep the online kernel; a second cost pass
would not help this case. No solver code was changed for this comparison.

Added collection before a temperature retry, so the failed solve's device
cache can be released before the next stage allocates its cache. Successful
retry stages already collect their completed resources. The planet fit remains
on its previously loaded code and is still in its first pass.

## 10:24 UTC: acceleration checks

Tested larger Anderson coefficient limits (20, 200, and 2,000) on the exact
Canada problem that had stopped the fit. Also tested damped Anderson proposals.
None improved the residual after 1,000 fixed-temperature iterations. Keep the
existing acceleration rule and the temperature retry; do not add these options.
The test scripts remain with the local diagnostic outputs, not in the solver.
The planet process was paused for these isolated tests from 10:18:48–10:20:30
and 10:22:07–10:23:45 UTC, then resumed. Include these pauses when interpreting
its total wall time.

## 11:04 UTC: bounded GPU marginal refinement

Stopped the planet fit at 10:38 UTC after the US device residual stopped falling.
The device check was below tolerance, but Float64 host reconstruction still
failed. The last valid checkpoint remains intact. No result was published.

A direct host scaling test reduced the error but was too slow: 30 passes still
left target L1 error at 0.000144. Added bounded GPU primal refinement instead.
Calculate accurate weights in host blocks and copy them into the existing device
cost cache. Reuse that cache, rather than allocating another full matrix. Run
primal scaling with bounded oneAPI kernels. Store only the resulting dual
corrections, and recheck masses in Float64. A failed refinement restores the
original cached cost before log-domain iterations continue.

The saved US candidate now passes after 1,000 primal iterations: target L1 error
0.0000797, maximum relative target error 0.000214, and maximum relative source
error below 0.000000000000003. The cold refinement test took 100 seconds,
including compilation. Compact CPU and oneAPI tests pass, including refinement,
parent-plan immutability, and bounded uploads. Full regression tests are next.
Uncached solves still use the implicit log-domain path; they do not allocate a
primal matrix outside the requested cache budget.

## 11:17 UTC: regression checks and restart

Core tests, research CPU/oneAPI tests, compact tests, and the small planet
publication workflow pass. Compact tests include partial column uploads and
partial primal kernel launches. There are 40 compact checks on each backend.
Archived the stopped fit and restarted from the same saved native pose seeds.
This discards the partial pass rather than counting it as a complete pass or
changing the initial solution. The fit again requests ten complete passes.
The archived checkpoints and diagnostic logs remain available.

## 12:13 UTC: further rejected optimizations

A temperature schedule based on a conservative force-range bound started at
8,192 times the requested temperature for the saved US problem. Extra stages
reduced some iteration counts, but the run exceeded its ten-minute test limit
at the final stage. It is not a completed timing or a solver improvement. Keep
the tested fixed retry schedule. The planet was paused from 11:50:20–12:00:23
UTC for this test, then resumed.

A separate 32-by-32 tiled device-cost layout preserved the dual results exactly,
but took 0.93–0.97 seconds per 100 iterations on the five-million-pair sample,
versus 0.87–0.91 seconds for the linear layout. Do not add the extra indexing
and upload code without evidence of a gain. The planet was paused from
12:05:38–12:07:25 UTC for this test, then resumed. Neither experiment changed
the running solver.

The US update in the real planet fit has now passed the original mass checks
and the outer objective test. India is still in its first update. Memory remains
bounded; `/proc` high-water readings are being saved to
`output/continuity-performance/planet-memory.csv`.

## 13:00 UTC: avoid repeated work after an interruption

Added an explicit start-update index to the existing continuation workflow.
It still uses a new output directory and the original baseline guards. Recover
a warm-start dual from the last pure proposal in each compact seed; do not
average mixture duals. This permits a verified partial-pass checkpoint to skip
already completed updates. It is not automatic crash recovery: the checkpoint
must match the requested index, and parent logs must be retained.

A two-country test resumes halfway through a pass and matches the uninterrupted
result. All 44 compact checks pass on CPU and oneAPI. The planet was paused for
these tests from 12:55:26–12:58:48 UTC, then resumed. Its loaded code and original
ten-pass plan are unchanged. China is still in its first temperature retry;
resident memory remains about 2.5 GiB.

## 14:10 UTC: sparse GPU marginal refinement

The saved US candidate needs only 522,072 retained pairs out of 71,174,732.
Added bounded row and column lists for primal refinement on KernelAbstractions.
Their combined device storage is 8.49 MB, versus 284.7 MB for dense weights.
The lists use only the unused cache budget and must be smaller than a dense
matrix. The cutoff applies only to temporary weights. Corrected duals still
define the full implicit plan, which must pass the original Float64 checks.
Failure uses the existing dense refinement or returns to log-domain updates.

A paired oneAPI test takes 67.9 seconds for warm dense refinement and 14.9
seconds for sparse construction, upload, and refinement. Both need 1,000
iterations, with target L1 error 0.0000797. Source relative error is below
0.000000000000003. Target mean-coordinate differences are below 0.000000011.
These timings measure refinement only, not the full solve.

All 51 compact checks pass on CPU and oneAPI, including sparse refinement,
budget refusal, bounded kernels, and unchanged parent plans. The first CPU
test caught a shared closure-variable name; this was corrected before GPU use.
The planet was paused from 13:58:43–14:00:13 and 14:00:57–14:08:18 UTC for
these tests, then resumed. Its running code does not yet use sparse refinement.
Logs are in `output/continuity-performance/benchmark-sparse-primal-paired.log`
and `test-compact-sparse-gpu.log`.

## 14:36 UTC: reduce repeated full-plan checks

China completed its first update at about 14:30 UTC. The first full pass is
complete. A stack sample during China's final stage showed repeated full-plan
host checks while the device residual changed little. After a failed full
check, now repeat it only after a 10% device-residual improvement, 500 more
iterations, or the iteration limit. Try refinement at the first failed check.
The acceptance limits are unchanged.

The dense and compact research tests and toy planet publication passed after
the sparse change. The planet was paused from 14:10:42–14:16:58 UTC for those
tests. Added explicit tests of both sparse index layouts, an exact storage
budget limit, and empty-row refusal. All 55 compact checks now pass on CPU and
oneAPI, including the revised host-check schedule.

Stopped the old planet process at 14:31:54 UTC, during its second pass, after
country 524. The complete first pass and the partial second pass remain saved.
The process required SIGKILL after SIGTERM did not finish shutdown. No outputs
were published. Verify the saved objective and metric index before continuing
with the new code; do not repeat the expensive first pass. A final regional
performance test will run before the continuation.

## 15:20 UTC: final paired regional benchmark

Repeated the three-pass H3-6, factor-2 Africa comparison at commit `f7dc433`.
The runs used the GPU in sequence. Compact cold/warm times are 437/345 seconds;
dense times are 562/476 seconds. Peak process memory is 2.17 GiB for compact
and 7.79 GiB for dense. Warm cumulative Julia allocations are 0.875 GB and
108.4 GB. Stored plans are 7.54 MB and 954 MB. The final compact result matches
the earlier compact benchmark; this case does not need sparse refinement.
Independent full-plan mass and moment checks pass again.

The planet continuation started at 15:09 UTC in
`output/planet-h3-5-factor1-sparse`. Before starting, the one-time script
checked every parent update index and recomputed the checkpoint objective and
all saved metrics. They match. It resumes at update 259 of 1,520, after country
524 in pass 2. The original baseline and guards are unchanged. The original
fit is copied into `parent-fit`; code, the seed hash, and the continuation
script are saved. At completion, the script will check and combine metric
prefixes, require a complete final pass, and run the normal publication checks.

The runner has a fixed deadline of 04:53 UTC, before the 05:51 UTC end of the
exclusive-use window. Publication remains conditional on successful checks.
No H3-MON server has been started.

## 16:05 UTC: avoid an early sparse-to-dense fallback

The second US update passed, but its reported final-stage refinement work
included 14,960 iterations across repeated attempts. The sparse path had the
same 1,000-iteration limit as the much slower dense path. This can discard useful
progress and then repeat the same scaling with a dense matrix.

Tested a saved US plan with a smooth linear perturbation to its target dual.
Its initial target L1 error is 0.0789. Sparse refinement fails at 1,000
iterations, but passes at 4,500 in 18.3 warm seconds with the original tolerance.
Allow up to 10,000 sparse iterations before falling back to dense refinement.
Dense limits, cache limits, and the final full-plan checks are unchanged.
A separate high-frequency perturbation still finishes at 1,000 iterations.

The planet was paused from 16:00:26–16:01:55 and 16:02:14–16:03:48 UTC for
these tests, then resumed. Logs are `test-sparse-limit.log` and
`test-sparse-limit-linear.log`. Its loaded code still has the shorter sparse
limit. Apply the change only after another verified checkpoint.

## 18:10 UTC: refine earlier, but keep the original acceptance tests

Tested earlier sparse refinement on China's second-pass hot stage. A candidate
at scaled device residual 121.75 failed primal scaling: some Float32 scale
values became zero at about 900 iterations. Smaller cutoffs did not fix it.
A diagnostic log-domain sparse kernel avoided this arithmetic failure, but
the full-plan mass check failed. The next support set was unavailable within
the tested limits. None of those changes were added to the solver.

A separate diagnostic pooled source rows at H3-3 to get a coarse dual estimate.
It reduced the native residual after 1,000 iterations to 7.66, compared with
121.75 without that estimate. The coarse solve and 1,000 native iterations did
not complete a valid native solve. This is not a measured full-solver speedup,
and no coarse warm-start feature was added.

The resulting saved near-converged candidate did pass sparse refinement:
3,980 primal iterations, 120 cold seconds including construction and checks,
target L1 error 0.0000278. Its starting target L1 error was 0.000272. Permit
sparse refinement earlier, at device L1 residual up to ten times the tolerance
and maximum relative error up to 1%. Dense refinement still uses the old
near-convergence limit. Every accepted plan must pass the original full-plan
Float64 limits; the new entry threshold does not relax them.

All 55 compact checks pass on both CPU and oneAPI with the revised entry limit.
The tests above paused the planet at these UTC intervals:
17:10:20–17:18:35, 17:19:52–17:23:25, 17:25:15–17:25:36,
17:25:51–17:28:56, 17:29:52–17:30:32, 17:33:35–17:43:38,
17:44:39–17:51:01, 17:53:43–18:02:42, and 18:04:35–18:08:08.
The first log-kernel test had a script scope error; the rerun reached the
full-plan check. The first coarse test hit its ten-minute limit. Its saved
coarse dual was then checked in a separate bounded native test. All logs and
invalid diagnostic candidates remain under `output/continuity-performance`.
They are not exportable cartogram results.

## 19:20 UTC: reuse a verified hot-stage dual

The old process remained in China's second pass. At 19:10 UTC, its factor-2
stage had reached 5,000 iterations with little residual change. Stopped it at
19:11:38 UTC rather than continue with the old short refinement limit. The
saved checkpoint still ends after India at update 303. Recomputed its objective
and all metrics, checked the parent prefix, and confirmed next update 304.

The earlier diagnostic produced a valid China hot-stage plan for this exact
checkpoint. Its prior history and force match exactly. Recomputed its full
masses: target L1 error 0.0000278 and maximum relative error 0.000792, at effective
temperature 1.632. Use its dual only as a warm start. Do not install this
high-temperature plan as the final country plan.

Added an explicit per-country initial-dual argument to the research runner.
It checks dimensions and finite values and saves the input vectors. This avoids
a country-specific solver patch. All 59 compact checks pass on CPU and oneAPI,
including a continued fit with explicit duals and invalid-input checks.
The old process required SIGKILL after its shutdown grace period. Its files
remain unchanged for review. A new continuation will retain both metric
prefixes and use the tested longer, earlier sparse refinement.

## 19:38 UTC: protect fast solves from early-refinement overhead

The full regional rerun caught a regression: unrestricted earlier refinement
raised warm time from 345 to 390 seconds. Several cases that normally need only
100–400 dual iterations paid for sparse construction to save a few iterations.
The result still passed its mass checks, but the runtime change is not useful.

Restrict the wider sparse-entry threshold to solves that have already used
1,000 dual iterations. Faster solves retain the old threshold. Keep the longer
sparse iteration limit for difficult cases. All 59 compact CPU checks pass.
The regional table still refers to the measured `f7dc433` comparison; do not
replace it with the regressed result. The new threshold has no effect on those
regional solves, all of which finish before 1,000 dual iterations.

## 20:25 UTC: second planet pass complete

The new continuation started at 19:38 UTC in
`output/planet-h3-5-factor1-sparse-v2`, at commit `8c02b00`. The verified
hot-stage dual reduced the repeated factor-16 solve to 50 iterations. The
factor-4 and factor-2 stages each passed at 1,000 iterations with the new
refinement policy. China then passed the final-temperature check and the
outer objective test. Pass 2 is complete; pass 3 is running.

The pass-2 objective is 67.6970. Cross-border RMS is 629.9 km and internal
edge RMS is 201.7 km. Large defects remain; this is not a continuity solution.
Peak process resident memory so far is about 2.4 GiB. No new GPU reset was
reported by the kernel journal.

Saved and verified a complete pass-2 checkpoint as a time-budget fallback.
A separate watcher saves later complete-pass checkpoints without modifying the
fit. Any fallback still needs full-plan and publication checks. The runner
deadline is 04:50 UTC; no new GPU tests will interrupt it for now.

## 23:20 UTC: retain useful partial refinement progress

China's third-pass final stage is slow. The running code discards a refinement
attempt if it reaches its iteration limit before passing both mass checks.
Added a conservative warm-start path: evaluate the full implicit plan at the
refinement limit, and retain its dual correction only when the largest
normalized mass residual improves by at least 10%. The partial plan is never
accepted. Reset the Anderson history and host-check delay only if the device
dual changes after Float32 conversion.

All 65 compact checks pass on CPU and oneAPI, including a deliberately
unfinished sparse refinement and unchanged history depth. A saved US
integration test limits sparse attempts to 200 iterations. It uses two partial
warm starts and then passes in 150 dual and 600 primal iterations. Final target
L1 error is 0.0000897, maximum relative error 0.000321, and source relative
error is below 0.000000000000003. This tests progress retention; it is not a
new full-fit speedup measurement.

The planet was paused from 23:08:41–23:11:17 and 23:11:47–23:14:32 UTC for
these GPU tests, then resumed. Its loaded code has not changed. CPU tests use
the same normalized-residual rule as the device convergence check.

## 23:32 UTC: keep validated inner stages

Added one bounded inner-stage checkpoint to compact research fits. Each
successful temperature stage overwrites the previous file atomically. Save
the step, country, temperature factor, compact proposal, and dual. This
avoids repeating a completed hot stage after an interruption. It does not
make an inner proposal an accepted outer plan, and it is not automatic
crash recovery. Input checks are still required before a warm restart.

All 69 compact checks pass on CPU and oneAPI. They check the retry callback
sequence and the saved stage metadata and residual. The planet was paused
from 23:27:08–23:30:55 UTC for these tests, then resumed briefly.

The old solver is still in China's third-pass final stage. Restart from its
last verified outer checkpoint with partial-refinement progress retention.
Limit this publication attempt to four passes, not the original ten, to keep
time for full validation and export within the reserved window. Keep all
original mass and distortion limits. The accepted pass-2 fallback remains
available if the four-pass attempt does not finish.

## 00:10 UTC, 13 October: reuse temperature-independent costs

The new four-pass continuation started at 23:34:54 UTC in
`output/planet-h3-5-factor1-sparse-v3`, at commit `f52d40b`. Its parent
checkpoint matches objective 65.1975 and all metrics. It resumes at update 456,
China in pass 3. The timeout ends at 04:40 UTC, with time left for validation
and a fallback export if needed.

Separated the compact cost workspace from the dual iterations. A temperature
retry does not change the force, prior, or proximal weight, so it need not
rebuild the same cost matrix and row/column offsets at every stage. Keep one
workspace and mark its matrix dirty when dense refinement overwrites it.
Restore the cost before the next use. Check workspace input identities.

All 72 compact checks pass on CPU and oneAPI. Tests overwrite a cached matrix
with NaNs, mark it dirty, and confirm that reuse restores the correct solve.
They also reject a workspace with different inputs. A saved China problem has
303,300,228 pairs and a 1.213 GB device cost cache. Workspace construction takes
37.6 cold seconds and 5.8 warm seconds. Reuse avoids this setup, not the main
pair reductions. This is not a whole-fit speedup measurement.

The planet was paused from 00:00:20–00:04:20 UTC for the GPU tests and setup
measurement, then resumed. Its loaded code does not use workspace reuse.
Do not restart it solely for this small setup saving.
