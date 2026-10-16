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
Kazakhstan. However, the sampled target contour for China intersects itself,
even with source simplification 0.05 and edge length one. The run stops before
optimization. This mode is experimental and is not used in the published pair.

The next task is to improve contour correspondence and sampling without
removing the validity checks. New sample points on a retained edge must be
shared by both countries. More iterations alone are not a demonstrated fix.

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

The publisher checks border counts, shared lengths, gaps, overlap, polygon
validity, and geometry hashes. It includes the synthetic release test and an
archive checksum file. Inspect the images as well as the numeric checks.
