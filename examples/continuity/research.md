# Border-focused research

See `benchmark/continuity-work-log.md` for the time window and decisions.
All research outputs are separate from production H3-MON files.

## Compare with nearby internal edges

The local comparison uses internal target edges incident to either side of a
selected international seam. Report both baseline and candidate local distances.
A candidate must not appear successful merely because its internal jumps grow.
Per-pair CSV files include each border's own local comparison.

The experiments now save full plans in Julia Serialization files:
`baseline.jls` and `candidate.jls`. Candidate plans are saved after every outer
iteration. These files require a compatible Julia environment. They are not
H3-MON files. Sparse Arrow exports remain optional.

## Check source distributions, not only their centres

For independent source draws with unit-sphere positions `u` and `v`,

```text
E[||u-v||²] = 2 - 2 * dot(E[u], E[v]).
```

This quantity includes each target's source spread. The RMS chord distance,
multiplied by Earth radius, can be calculated without a dense geographic
source-to-source distance matrix. It is not a Wasserstein distance or a
geographic line length. Compare it across seams and across nearby internal
edges.

Two penalty forms are available:

- `mean`: squared distance between target means, as in the initial experiment.
- `distribution`: expected squared distance between independent source draws.

Each can use the original saturating penalty or an uncapped quadratic penalty.
The distribution form discourages a false improvement made only by averaging
distant populations together. The uncapped form is a diagnostic for genuine
mainland seams; it is not a proposed default for islands or false contacts.

## First sweep

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  OPENBLAS_NUM_THREADS=4 julia --threads=8 --project=examples/uk-h3 \
  examples/continuity/sweep.jl output/continuity/africa-h3-4 \
  output/continuity/africa-sweep-1
```

This uses the three existing H3-4 country extracts and caches a common baseline.
It tests both penalty forms, both saturation choices, and strengths 0.01, 0.1,
and 1. It allows up to 20 outer steps. Border share is 95%. The internal and
spread limits are relaxed to 25% to measure their influence. These are research
limits, not acceptance criteria for production.

`summary.csv` records ratios between border and local internal statistics.
`failures.log` retains failed solves. A failed configuration does not stop the
remaining configurations. Inspect each pair and its full distributions before
selecting a setting. The launch is bounded by the 19:01 UTC deadline.
