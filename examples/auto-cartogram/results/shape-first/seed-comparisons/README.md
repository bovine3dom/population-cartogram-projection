# Position seed comparisons

These are rejected position trials, not replacement maps. The images use cleaned
component templates, exact tile budgets, and no added connector paths. The
metrics report no false borders. These checks do not prove correct positions.

- [10,000 tiles from the 55,000-tile parent](world-10000-seed55-islands.png):
  Thailand is north of Myanmar. Retains 138 of 341 source borders.
- [110,000 tiles from the 55,000-tile parent](world-110000-seed55-islands.png):
  Afghanistan is better placed than in the independently initialized trial,
  but Thailand is still north of Myanmar. Retains 132 of 353 source borders.
- [55,000 tiles from Tutte centres](world-55000-seed-tutte-islands.png):
  Sudan moves into Europe. Retains 109 of 348 source borders. Do not use this
  initializer for the current intact-shape solver.

The seed changes initial component centres only. It does not copy source tile
shapes or change population budgets. Centres scale by the square root of the
ratio of target and seed tile counts. New components use the displacement of
nearby source components. The solver then runs continuous placement, integer
refinement, and small-island placement.

All three trials use source coast anchors, collision cost 100, spring cost 1,
anchor cost 0.001, spatial cost 0.3, gap 0.1, ocean scale 0.1, order cost 5,
and local order radius 35 degrees. Continuous placement allows 10,000 iterations;
integer refinement allows 50 rounds. The small-island population limit is 1%.
The code checkpoint is `4833ca6`. The seed parents are
`world-55000-shape-islands` and `world-55000-tutte-partial-200`.

These images show why changing initial positions alone is insufficient. The
next method should permit controlled mainland deformation without creating
thin border paths. Do not select a trial only because it retains more borders.
