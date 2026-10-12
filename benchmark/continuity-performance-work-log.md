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
