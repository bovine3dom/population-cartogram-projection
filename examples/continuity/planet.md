# Experimental planet: H3-5, factor 1

This dataset is a continuity experiment, not a replacement for the production
planet map. Keep the existing planet files. The fit can still have large border
gaps and reversed triangles. Ten update passes do not prove convergence.

## Inputs and method

The input is the existing planet `cartogram_weights_hilo.arrow`. Keep its H3-5
source populations, country codes, city names, and target coordinates. Do not
subdivide the OWID grid. Code 249 is metropolitan France in this input.

Fit only countries with a shared geographic boundary that also touch in the
artwork. Natural Earth boundary segments define geographic neighbours. Exclude
edges incident to mixed-country target cells. Record fitted contacts, missing
contacts, and false artwork contacts in `contacts.csv`.

Countries with no such contact keep their old conditional mapping. Normalize
source weights to remove the old file's row-sum error. Recalculate target weights
from transported population, including at shared South Africa–Lesotho cells.

Use KernelAbstractions with oneAPI. There is no CPU solver fallback. First solve
a balanced baseline for each fitted country. Then test eight rotations, one
country at a time, in order of target count. Keep a rotation only if it lowers
the full objective and passes the spread and internal-distance checks. This is
a sequential search, not a global optimum. Stream the candidates to limit memory.

Use the local-scale border penalty from the regional tests. Update smaller
countries first and repeat. Use full source distributions, a fold penalty, and
proximal Sinkhorn updates. The default is ten passes. Saved settings give the
exact weights and tolerances. This method does not solve the island-area problem.
It does not change island outlines or estimate separate island populations.
Internal grid edges still contribute to the objective.

Check source and target mass before export. Keep at least 99.999% of each fitted
source's transport, then normalize the retained weights. Density is people/km².
Both Arrow files use unsigned 32-bit index halves. Keep city names from the old
file; place each source's labels at its largest-weight target. Do not invent
missing prominence values.

## Run

From the projection repository root:

```sh
export ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1
export OPENBLAS_NUM_THREADS=4
julia --threads=8 --project=examples/uk-h3 examples/continuity/planet.jl \
  prepare ~/projects/H3-MON/www/data/cartogram_weights_hilo.arrow \
  output/planet-h3-5-factor1-continuity
julia --threads=8 --project=examples/uk-h3 examples/continuity/planet.jl \
  fit output/planet-h3-5-factor1-continuity
julia --threads=8 --project=examples/uk-h3 examples/continuity/planet.jl \
  publish output/planet-h3-5-factor1-continuity \
  ~/projects/H3-MON/www/data/planet-h3-5-factor1-continuity
```

Preparation and publication refuse to replace existing directories. Baseline
and pose caches permit a restart before the coupled fit starts. The coupled fit
saves plans after each complete pass, not after each country. This avoids writing
several terabytes of repeated data. After an interruption, the metric log can
extend beyond the last saved plan. Do not change inputs or settings when reusing
caches. If the coupled fit stops, retain
its checkpoint and use `continue_fit.jl`; publication requires a completed fit.

To run the fit and publication as one job, use:

```sh
nohup bash examples/continuity/run_planet.sh \
  output/planet-h3-5-factor1-continuity \
  ~/projects/H3-MON/www/data/planet-h3-5-factor1-continuity \
  > output/planet-h3-5-factor1-continuity/job.log 2>&1 < /dev/null &
```

`job-started.txt` records the job PID. `job-status.txt` records its final exit
status. `published.txt` appears only after a successful copy.

The job writes both files to a temporary sibling directory. It publishes that
directory only after both files and the diagnostics are complete. It does not
start H3-MON or change its default dataset.

## Compact mode

Use a new prepared output directory for compact mode. Set
`CONTINUITY_PLANET_MODE=compact` when starting `run_planet.sh`, or call
`planet.jl fit-compact OUTPUT` directly. Do not reuse dense country caches.

This mode uses implicit transport plans and bounded host blocks. It tests poses
with H3-4 source populations, summed from the H3-5 input. It then tests the chosen
angle at H3-5 against the native-resolution objective and distortion limits.
A rejected angle leaves the native baseline in place. Thus there is at most one
additional pose solve per country at the native resolution, not seven.
The final fit and both exports still use the original H3-5 sources and factor 1.

Compact checkpoints are small enough to save after each country update.
`fit-config.csv` records the mode and pose resolution. A restart with different
settings is refused. Compact plans retain proximal updates and damped mixtures;
see `compact.md` for the representation and tests. Publication recalculates plan
statistics in blocks before checking masses.

## Files in H3-MON

- `cartogram_weights_planet_h3_5_factor1_continuity_hilo.arrow`
- `population_density_hilo.arrow`
- `contacts.csv` and `countries.csv`: fitted and excluded countries and contacts.
- `metrics.csv` and seam tables: matched baseline and fit diagnostics.
- `candidate-orientation.csv`: reversed-triangle diagnostics.
- `settings.csv` and `provenance.txt`: settings and input identity.

The matched baseline is a new balanced solve, not the old production mapping.
Global metrics cover fitted countries only. No runtime estimate is established
for this planet run. Country checkpoints and the log show its progress.
