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
