# Soft continuity experiment

This experiment keeps every OWID target cell in place. It does not identify
islands, assign island populations, or change target capacities. It does not
change the core solver or the existing UK and Germany outputs.

The initial cases are Germany–Poland, Indonesia, and Russia. Sources are Kontur
H3-8 cells selected by the existing Natural Earth extraction procedure, then
summed to H3-4. Targets use the original OWID cells, with no subdivision. Each
country keeps its own source population and equal target masses. The experiment
allows no population transfer between countries.

## Objective

Let `P` be a country's transport plan, normalized to total mass 1. Let `C` be the
core solver's normalized distance cost. Let `q[j]` be the target's mean source
position in three-dimensional unit-sphere coordinates. Divide by the actual
target mass to calculate this mean; do not normalize its length. This prevents
small marginal errors from appearing as large changes in geographic spread.

The objective is:

```text
sum over countries: <C,P> + eta * sum(P * (log(P) - 1))
+ strength * mean over selected edges: 1 - exp(-||q[j]-q[k]||² / (2*tau²))
```

Zero-mass entropy terms are zero. The initial settings are:

- `eta = 0.002`, fixed for baseline and candidate fits.
- `strength = 0.001`.
- `tau = 300 / 6371`, a chord-distance scale of approximately 300 km.
- Three outer iterations at most.

The continuity penalty approaches 1 for a large jump. Its derivative approaches
zero. Thus a large cut receives little force, rather than an unlimited penalty.
This permits island cuts, but it can also preserve bad mainland cuts.
The objective gives each country's transport term equal weight, not weight
proportional to its total population.

Edges connect side-adjacent target cells within each country. By default, international edges connect Germany and Poland only. The Africa
runner supplies a different explicit mask. Neither runner detects geographic
adjacency automatically.

## Optimisation and safeguards

First calculate a fresh baseline at the same resolution and entropy setting.
Do not use the older global Arrow file as the numerical baseline.

For each outer iteration:

1. Differentiate the continuity penalty at the current plans.
2. Add this derivative, multiplied by `strength`, to the original assignment cost.
3. Solve the resulting fixed-cost problems with Sinkhorn on KA + oneAPI.
4. Test mixtures of the old and proposed plans. Start with step 0.5 and halve
   it up to nine times.
5. Accept only an objective decrease. Also require mean source spread and its
   90th percentile to remain within 5% of the initial baseline values.
6. Stop if no tested step passes these conditions.

The spread statistic is a sphere-chord RMS proxy, `6371 * sqrt(1 - ||q||²)`.
It is not mean great-circle radius. The acceptance limits apply across all
included targets; they do not guarantee that every cell avoids extra mixing.

The experimental Sinkhorn implementation uses exact dense costs and KA kernels.
It has no CPU fallback in the runner. It does not use the production solver's
spatial pruning, whose bounds do not cover this new cost. Each solve requires
source-normalized reconstruction and target marginal L1 error at most 0.00001.
A failure to converge stops the experiment instead of exporting that proposal.
Convex mixtures retain source marginals and the target marginal error bound.
The outer problem is not convex; this is not a global optimum guarantee.

## Run

Use the existing UK example environment, which contains oneAPI and the data
packages. From the repository root:

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  OPENBLAS_NUM_THREADS=4 julia --threads=8 --project=examples/uk-h3 \
  examples/continuity/run.jl output/continuity/h3-4-soft-cuts
```

Use a new output directory. The runner refuses to replace one that exists.
Set `KONTUR_ARROW` to use a different input path. The default is
`~/projects/gtfs_ffs/data/kontur_h3.arrow`.

Each case writes `metrics.csv`, `trials.csv`, `baseline.arrow`, and `candidate.arrow`.
The trials file records every tested step. The metrics file records accepted
and rejected outer updates, the complete objective, internal
and border jump statistics, source spread, and target marginal error. Jump
statistics use great-circle distances between normalized target mean vectors.
They do not establish whether a full line footprint is connected.

The Arrow files are diagnostic sparse mappings, not H3-MON exports. They retain
at least 99.5% of each source's assignment weight. `weight_mean` uses the full
plan's target totals, so its exported target sums can be below 1. The metrics
use the full plans before this sparsification. No city labels or split indices
are added. Do not replace production mapping files with these outputs.

The output root also contains the H3-4 inputs and their SHA-256 checksums.
The runner logs the device, versions, baseline times, and outer updates.

## Initial results

The corrected run is `output/continuity/h3-4-soft-cuts-v2/`. The first pilot was
stopped after a spread-metric defect was found. Do not use its results.

Germany–Poland is effectively unchanged: median seam distance decreases from
129.212 to 129.172 km. This is not evidence of a useful improvement.

For Indonesia, the internal 90th-percentile distance decreases from 75.84 to
74.05 km. However, the maximum increases from 972.62 to 1,119.09 km. Mean source
spread increases from 159.97 to 160.49 km. A lower saturating objective does not
guarantee that large cuts remain unchanged. These outputs are not production
candidates. Russia is still pending at the time of this note.

## African interior trial

The first objective averaged all graph edges together. Numerous internal edges
therefore reduced the influence of a small international seam. The Africa trial
assigns 80% of the continuity weight to international edges and 20% to internal
edges. Each group is normalized separately.

It fits Angola, DRC, and Zambia together, with all three genuine shared borders
enabled. The OWID cells and each country's population constraints remain fixed.
The global H3-5 audit found median seam jumps of 897 km, 583 km, and 249 km for
Angola–DRC, Angola–Zambia, and DRC–Zambia, respectively. These are not the new
H3-4 baselines.

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  OPENBLAS_NUM_THREADS=4 julia --threads=8 --project=examples/uk-h3 \
  examples/continuity/africa.jl \
  ~/projects/H3-MON/www/data/cartogram_weights_hilo.arrow \
  output/continuity/africa-h3-4
```

This runner reads each distinct source population from the existing global
mapping and sums it to H3-4. It does not use sparse transport weights to estimate
source population. Thus it uses the global file's population snapshot, not the
new country extracts. It rejects conflicting populations for the same H3 index.

Four trials combine penalty scales of 300 and 900 km with strengths 0.001 and
0.01. The larger scale tests whether the first penalty stopped growing too early
for these large border jumps. Each trial has a fresh baseline at the same entropy
setting. The runner additionally rejects steps that increase the regional
internal 90th percentile or maximum by more than 5% from baseline.

`baseline-seams.csv` and `candidate-seams.csv` report each country pair separately.
`settings.csv` records parameters and edge counts. All earlier spread safeguards
remain active. These checks do not guarantee that every individual cell or
country improves. Do not accept a result solely because the regional average
improves.

### Completed Africa results

All four trials completed on oneAPI. The 900 km scale with strength 0.01 gives
the largest reduction in the regional border 90th percentile after three steps.
There are 55 border edges and 2,007 internal edges.

| Seam | Baseline median | Candidate median |
| --- | ---: | ---: |
| Angola–DRC | 881 km | 560 km |
| Angola–Zambia | 553 km | 553 km |
| DRC–Zambia | 249 km | 238 km |

The regional border 90th percentile decreases from 1,018 to 735 km. The internal
90th percentile increases from 153 to 157 km, and the internal maximum increases
from 459 to 479 km. Mean source spread increases from 105 to 108 km; its 90th
percentile increases from 183 to 192 km. All accepted steps pass the specified
5% limits, but some of the improvement comes with extra spread and internal
distortion. The maximum country target marginal L1 error is below 0.000007.

These are centre-distance results from a coarse fit, not proof that full line
footprints improve. Inspect the before/after footprints before a fine fit or
production export. No H3-MON files were replaced.

## Tests

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  CONTINUITY_GPU_TEST=1 julia --threads=8 --project=examples/uk-h3 test/continuity.jl
```

Tests check marginals, target-only cost offsets, CPU/GPU agreement, failure on
non-convergence, the penalty derivative, and negligible force across a large cut.
The CPU path exists for small tests only. The experiment runner requires oneAPI.
