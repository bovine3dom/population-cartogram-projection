# Planar mesh guide experiment

This is a new guide test, not a production cartogram generator. Final mosaic
counts remain controlled by the existing component budgets.

## Why test a mesh?

Shared footprints close many gaps. Their coast shapes still constrain all later
country assignments. Stronger border costs cannot correct a poor continent
outline when the occupied cells stay fixed.

Sargent's [2024 preprint](https://arxiv.org/abs/2411.17129) minimizes area error
and shape distortion on a shared triangular mesh. Its shape cost penalizes
unequal stretching in two directions. Its scale cost penalizes extreme local
area changes. Land receives more weight than water. The paper also gives
spherical and hybrid methods. Those methods are not implemented here.

I read the paper's planar method and inspected its published plane-cartogram
figure. I also read the [repository README](https://github.com/rsargentmath/cartogram-gradient-descent/blob/main/README.txt).
The README describes the code as a proof of concept. GitHub's repository metadata
did not identify a licence. This experiment does not copy or import that code,
load its pickle files, or use its bundled population data.

## Method

`mesh_guide.py` is an independent, smaller planar experiment based on the paper's
objective. It uses prepared Equal Earth component geometry and guide budgets.

1. Make a rectangular Delaunay mesh with a water margin. Refine triangles near
   components with fewer than four supporting triangles. Add edge midpoints and
   repeat, up to 16 refinement levels. Keep the outer frame fixed.
2. Intersect each source component with each relevant triangle. Check that the
   intersections retain its source area. Save the number of supporting triangles.
3. Move the free vertices. Each triangle defines one affine transformation.
   Compute each component's area from its triangle intersection areas.
4. Minimize weighted area error plus shape and scale costs. Reduce the distortion
   weight in separate stages. Record iteration limits and convergence status.
5. Check for flipped or collapsed triangles. Transform the source intersections,
   join them, close numerical seams, and reject invalid or split polygons.
6. Check output overlaps. Save geometry and the original and transformed mesh.

For a triangle transformation `J`, the shape cost is
`sum(J * J) / det(J) - 2`. The scale cost is
`det(J) / s + s / det(J) - 2`, where `s` is the intended local area scale.
The area cost is the sum of squared component errors divided by target area.
The code has an analytic gradient. Tests compare it with finite differences.

The solver uses a quadratic extension of the reciprocal determinant below
`1e-5` for line-search probes. This gives invalid trial steps a finite recovery
gradient. No stage with determinant at or below `1e-12` can be accepted or
exported. This differs from the paper's infinite barrier. A finite extension
alone is not proof of valid output; the explicit geometry checks are required.

Other differences from the paper are important:

- Reference triangles are planar, not spherical. Projection distortion remains.
- The outer rectangle is fixed. The paper's planar boundary can move.
- Water triangles use the nearest land triangle's intended scale, not a blurred
  scale field.
- The first mesh is coarse. Small regions can share degrees of freedom. The code
  records support but does not guarantee four triangles per component.
- A stage that reaches its iteration limit can supply a diagnostic guide if it
  passes geometry checks. It is not a converged, exact-area cartogram.
- Polygon unions can have numerical seams between adjacent affine evaluations.
  Unions use a `1e-12` precision grid. A positive and negative `1e-11` buffer
  closes remaining seams in normalized coordinates. Compare the result with the
  sum of mapped piece areas, not only the union area. Reject errors above the
  larger of `1e-12` and `1e-8` times the expected area. Reject changed hole counts.
  This can affect extremely small features; it is not a way to close map gaps.

The first country-box sampling trials stopped with about 97% weighted area
error. The optimizer reported a relative-change stopping condition, not a useful
cartogram. Their world images remain close to the geographic input. They are
rejected. Midpoint refinement now replaces those box samples; it still requires
independent tests and visual review.

## Run

Use a new output directory and a fixed code snapshot:

```sh
p=output/auto-cartogram
"$p/geometry-env/bin/python" examples/auto-cartogram/mesh_guide.py \
  "$p/world-55000-mainland-flow/input" \
  "$p/world-55000-mesh-guide" \
  --resolution 64 --iterations 1000 --distortions .3 .1 .03 .01
```

The input above excludes isolated components from the guide. Their final budgets
are not removed. Pass the output geometry and population sites to the separate
partition stages described in [the shared-footprint notes](compact-pipeline.md).
Inspect the continuous guide before assigning tiles, then inspect the world and
regional tile images. Do not select a map from its area error alone.

## Another recent direction

Bogdan's [September 2026 preprint](https://arxiv.org/abs/2609.14089) tests a
continuous optimal-transport map of native population density. This is different
from our exact-capacity assignment of countries inside a fixed footprint.

The preprint reports less rotation and shear than its own diffusion baseline.
It also reports folded ocean cells in the raw numerical mesh, repaired only for
drawing. Its flow-based comparison was omitted because the author's gridded
implementation did not reproduce the published shape quality. I read these
limits and inspected the world figures. The figures still contain very thin
features. Neither theoretical optimality nor a low displacement cost establishes
the country-shape quality required here. No implementation or data from that
repository have been adopted.
