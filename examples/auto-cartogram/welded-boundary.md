# Shared-border fit

## Status

The point-contact assembly failed. It kept contacts at isolated points, not
complete borders. Do not use its output as a new layout.

The replacement uses shared vertex variables along each retained border.
A selected cut gets separate vertex copies. No spring connects the two copies.
General collision checks still apply. A cut permits a gap; it does not require
one. Junctions can remain connected through other retained borders.

The regional test preserves all 23 control borders and all 19 retained borders
in the cut case. However, it does not yet improve the shapes. The current-best
planet layout and H3-MON exports are unchanged.

Review: [border checks and images](results/geography/welded-boundary/index.html).

## Method

1. Load the saved continuous guide and verify its input hash.
2. Simplify the shared coverage and sample its borders.
3. Match complete shared edges. Reject missing border segments.
4. Use one position variable for both sides of each retained border.
5. Use separate variables for the four audited cuts.
6. Fit the independent Kontur outlines with a sparse quadratic solver.
7. Reject invalid polygons, reversed triangles, and country overlaps.

The solver can translate each preferred outline. Country areas use penalized
slack variables, not exact constraints. Reports give the actual area errors.
Step limits and local elastic terms restrict deformation. The mesh is
triangulated again after each accepted step.

This test includes 12 countries. It omits external neighbours, islands, and
lakes. It produces continuous polygons, not tiles. White areas in these panels
are not a proposed sea map.

## Results and limits

The published regional pair uses eight iterations, a source simplification
of 0.3 tile units, and a maximum sampled edge length of six tile units.
Retained borders have zero gap and positive shared length. The maximum country
area error is less than 0.2%. The shapes remain close to the initial guide.

A separate three-region test checks the release mechanism. A and B retain their
complete shared edge. After the B-C cut, C changes from a long rectangle toward
a square and separates from B. This test passes, but it does not demonstrate a
successful Eurasian layout.

Large regional steps can make narrow coastlines cross themselves. The validity
checks reject those steps. Small steps preserve borders but make little progress.

The optional `--patch-guides` mode matches contour sections by common Kontur
patch labels. The ordered label sequences agree for Russia, China, India, and
Kazakhstan. Its first version rejected China's sampled target contour because
straight chords crossed narrow bends. Projection of new source points could
also jump across a bay.

The revised mode projects original source vertices only. It interpolates fixed
target parameters for new samples. Crossing target chords cause subdivision of
the source edge on both sides. Each mapped target ring must pass its
self-intersection check. Refinement stops with an error if it cannot do this.
Single-label rings and ambiguous label cycles still use whole-outline matching.

[Contour refinement results](results/geography/contour-refinement/index.html)
show a new paired test with simplification 0.3, edge length six, and a limit of
24 iterations. One round of eight edge splits repaired the mapped contours.
All 23 control borders and all 19 retained cut-case borders remain intact.
The control accepts 24 steps, with maximum area error 0.027%. The cut case
accepts one very small step in eight attempts, with maximum area error 0.170%.
It stops because solver convergence and overlap checks prevent further steps.
This is not a successful cut layout.

Visual checks show small changes in the control, but the Kazakhstan pinch and
the narrow Russian strip remain. A second test with one-tile simplification
also failed to produce a useful cut layout. Its cut-case area error was 4.62%.
Do not use coarse simplification to hide these problems.

The next task is the collision model at released borders and solver convergence.
Valid target contours are necessary, but they do not ensure a valid deformation
path. Keep the whole-border, polygon validity, and overlap checks active.

## Repeat the checks

Use the experimental geometry environment with `mesh-requirements.txt`.
The input data must already exist under `output/auto-cartogram`.
Use a new output directory for each fit.

```sh
PY=output/auto-cartogram/geometry-env/bin/python
export OPENBLAS_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1
$PY examples/auto-cartogram/welded_boundary_fit.py \
  output/auto-cartogram output/auto-cartogram/welded-boundary-repeat \
  --iterations 8 --source-simplify .3 --edge-length 6
$PY examples/auto-cartogram/publish_welded_boundary.py \
  output/auto-cartogram/welded-boundary-repeat \
  examples/auto-cartogram/results/geography/welded-boundary-repeat
$PY -m unittest discover -s test -p 'auto_*.py'
```

To repeat the contour refinement test, use a new output directory and add
`--patch-guides`. Set `--iterations 24 --source-simplify .3 --edge-length 6`.

The publisher checks border counts, shared lengths, gaps, overlap, polygon
validity, and geometry hashes. Its table reports accepted steps and solver
status separately from final geometry checks. It includes the synthetic release test and an
archive checksum file. Inspect the images as well as the numeric checks.
