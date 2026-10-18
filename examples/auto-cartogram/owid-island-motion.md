# OWID: border movement and island movement

## Result

[Review the trial](http://proto.olie.science:8642/results/owid-island-motion/index.html).

This trial starts from `output/auto-cartogram/owid-island-resize-v9`.
It does not change the default OWID map or an H3-MON export.

- Malaysian Borneo changes from 164 to 44 tiles.
- Peninsular Malaysia changes from 60 to 180 tiles.
- Shared borders can move. Indonesia, Brunei, Thailand, and Singapore keep
  their tile counts and existing neighbours.
- Philippine islands change size and move as whole pieces after resizing.
  Each piece has at least a one-cell gap from other land, including diagonals.
- Country totals remain fixed. The world has 54,967 unique land cells.
- Each target piece remains connected. No land contact is added or removed.

The source assignments are unchanged. Automatic island identities still need
review. Matching the requested counts does not prove that these identities
are correct. Small fallback pieces share their group's population in
proportion to their original tile counts. This is not a separate population
measurement for each fallback piece.

## Method

For Malaysia, resize the donor part first, then the recipient part. Let each
part and its direct neighbours change shape together. Keep the neighbours'
counts fixed. Use scaled OWID outlines as shape guides. Keep all existing
contacts and protected water. If either fit fails, discard both fits.
Intermediate regional counts can change; the final country total cannot.

For the Philippines, remove the selected islands from the obstacle map before
placement. Resize each outline, then place large pieces first. Move desired
centres away from the group centre by a factor of 1.3. Limit movement to 24
cells per axis. The largest observed movement is 12 cells on one axis.
Keep the original centre order on each axis where centres were at least two
cells apart. Do not rotate pieces.

The old artwork encloses 63 empty cells between Philippine pieces. These
cells can open to the sea or change position. They are not country tiles.
The other 109 enclosed cells remain empty at their old positions. Single-piece
holes and gaps with foreign shores cannot be released by this rule. This is
an artwork rule, not a geographic lake classification.

`matches.csv` records actual counts and actual group totals. Source assignment
files are copied without change. `relaxation.json` records solver results,
movements, released gaps, input hashes, and dependency hashes.

## Work log: 2026-10-18 UTC

1. Added explicit part counts to the existing local border solver. Default
   calls still keep their old counts.
2. Trial v1 completed both Malaysian fits. Philippine placement failed under
   the initial movement limits. The failed placement left the old islands intact.
3. Trial v2 used the expanded desired centres and a 24-cell movement limit.
   Both countries passed the final checks. The Borneo solver reached its
   90-second limit with a valid solution; optimality is not proved. The
   peninsula fit reached an optimal solution for its local objective.
4. Visually checked the Philippine and Malaysian comparisons. Philippine
   pieces now have clear gaps. The principal outlines remain recognisable.
   Malaysia reaches the requested size split, but the peninsula is broader.
5. Visually checked both Malaysian border regions. Brunei remains attached,
   but forms a small projection. The shared Borneo outline still has angular
   edges. These are review points, not production approval. Added border
   lines to the regional images because Thailand and Malaysia share a colour.
6. All 372 Python regression tests passed, including seven new tests for
   budgets, water release, packing, and rollback.

## Repeat the trial

Use a new output directory for each run.

```sh
PY=output/auto-cartogram/geometry-env/bin/python
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 "$PY" \
  examples/auto-cartogram/relax_owid_islands.py \
  output/auto-cartogram/owid-island-resize-v9 data/cartogram.csv \
  output/auto-cartogram/owid-island-motion-repeat \
  --archipelago PHL --redistribute MYS --seconds 90 --max-shift 24

"$PY" examples/auto-cartogram/review_owid_resize.py \
  data/cartogram.csv output/auto-cartogram/owid-island-motion-repeat \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  output/auto-cartogram/owid-island-motion-review-repeat
```

Time-limited solver runs can produce different valid outlines. The published
CSV files contain the exact reviewed trial.
