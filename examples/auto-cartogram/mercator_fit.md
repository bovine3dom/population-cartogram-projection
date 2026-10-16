# Fresh Mercator shape fit

[Review the regional fits](results/geography/mercator-fit/index.html).

## Scope

Start from fresh Mercator outlines, not the distorted previous layout.
Keep each selected component's population tile budget. Fit the shapes without
connector paths. This first fit keeps the fresh shapes rigid. It tests their
relative positions before controlled deformation.

The Eurasia test includes the largest components of Russia, China, India,
and their direct represented land neighbours: 26 components and 25,845 tiles.
The North America test includes the largest components of Canada, the United
States, and Mexico: 3,317 tiles. These budgets are subsets of the 55,000-tile
world budget. They are not new regional population allocations.

**These are mainland tests, not replacement maps.** Named lake cells and
secondary islands are not included. In particular, the Arctic archipelago,
Alaska, and Sri Lanka are not shown. The existing lake-aware world layout and
H3-MON export are unchanged. The regional fitter must not feed production
mapping until empty lakes and island relationships are included.

## Method

1. Project each original component into spherical Mercator. Scale its outline
   uniformly to its existing population tile area.
2. Grow an exact-count connected tile shape from that outline.
3. Convert the existing population sample coordinates from Equal Earth back
   to longitude and latitude, then into Mercator. Weight the positions by
   population. Do not interpret Equal Earth coordinates as Mercator coordinates.
4. Use these population centres as position preferences. Use broad axis order
   constraints between centres. The tolerance is three geographic degrees.
5. Map the midpoint of each source border into both scaled outlines. Prefer
   agreement between these border positions. Weight the preference by the
   population in the audited two-sided border corridor.
6. Fit continuous translations with collision penalties and axis constraints.
   Convert the result into exact integer translations with collision and
   false-contact checks. Keep the broad axis order during this final packing.

The border weight is `clip(log1p(population / 100000), 0.05, 5)`.
This is an experimental weight, not a validated threshold. It does not require
all populated borders to remain connected. Every lost contact is reported
with its corridor population and its earlier sparse-border classification.

For border-position error `d` and release scale `r`, the cost is
`0.5 * weight * r^2 * log(1 + |d|^2 / r^2)`. Its force decreases for large
errors. The release scale is not a maximum gap. The quadratic control uses
`0.5 * weight * |d|^2` instead. Border populations weight the preference;
they never change tile budgets.

The solver uses [SciPy SLSQP](https://docs.scipy.org/doc/scipy/reference/optimize.minimize-slsqp.html)
with linear axis-order constraints. Reports preserve the solver status and
message. A failed optimization is not a successful fit, even if the final
packing has exact counts.

Packing tries spacing factors 1, 1.25, 1.6, 2, 3, and 4. Each exact-placement
search has a 128-cell radius around its target. The report records the factor
and the displacement from the continuous solution. Packing can worsen the
objective. Do not report continuous energy as the quality of the packed map.

## Results

Visual checks covered all four saved regional fits.

- At release scale 8, Russia stays near Europe and west of China. Russia,
  China, and India keep the fresh recognizable outlines. Mongolia stays
  north of China's centre. The Kazakhstan region has no connector paths.
- Exact packing needs no additional expansion for this candidate. Its largest
  displacement from the continuous solution is 1.41 tiles. Broad axis order
  has no measured violations. This does not prove correct coast relationships.
- Only four of 46 source contacts remain. Nineteen removed contacts fail the
  earlier sparse-border test. Too many populated borders are lost. This is
  a shape-first limit case, not an approved balance of shape and contiguity.
- The stronger release scale 24 needs 1.6-fold expansion during final packing.
  It retains no source contacts and has excessive gaps. It is not an improvement.
- The quadratic control does not converge: SLSQP reports a positive directional
  derivative. Its rendered iterate is included as a failed comparison, not as
  a converged control. It also needs 1.6-fold packing expansion.
- The North America test retains a recognizable Canadian mainland and Hudson
  Bay. It retains neither land contact. Canada sits beside the northeastern
  United States, but islands and the Great Lakes still need a joint test.

An earlier geometric-centre fit put Mongolia south of China. Soft axis-order
penalties were insufficient. Hard axis checks fixed that error but left large
gaps. Population-centred placement then moved Russia west without a named
country rule. Russia's geometric centre is not a good position anchor for its
small population-sized outline in this test.

The earlier bounds-only packing attempts failed. They produced no complete
layout. The final method uses a collision-free seed, constrained continuous
optimization, and explicit packing-expansion reports. The geometric-centre
prototypes remain local diagnostic outputs, not current saved candidates.

## Next step

Keep Mercator as the shape target. Add bounded deformation and a penalty for
losing populated border segments. Try to close the small gaps without pulling
Russia, China, and India back into the old pinch point. Add empty-lake and
island constraints before a world fit. Do not treat these omitted features
as solved or silently copy water cells from the old coordinate frame.

## Reproduce

Run from the repository root with a new output directory:

```sh
OPENBLAS_NUM_THREADS=1 output/auto-cartogram/geometry-env/bin/python \
  examples/auto-cartogram/fit_mercator_shapes.py \
  output/auto-cartogram/world-55000-dissolved-input \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  output/auto-cartogram/sparse-border-audit-25-wide/border-population.json \
  output/auto-cartogram/mercator-fit-new \
  --sources output/auto-cartogram/world-55000-h3-5-density/sources.csv \
  --release 8 --iterations 1000
```

For the North America test, add `--countries CAN USA MEX --neighbours 0`.
For the quadratic control, use `--release 0`. For stronger border forces at
large errors, use `--release 24`.

All 198 tests pass. Seven new tests cover projection inversion, population
centres, budget checks, border gradients, reduced long-distance border force,
component selection, exact ordered packing, and a small end-to-end fit.
