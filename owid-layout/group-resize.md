# Corner-group population resize trial

[Open the images and data](../examples/auto-cartogram/results/julia-group-resize/index.html).

The trial is `output/auto-cartogram/julia-group-resize-v5`.
Implementation commit: `ac8f566`.
The saved layout, default OWID file, and H3-MON exports are unchanged.

## Result

Population matching was rerun for the ten scopes affected by corner grouping.
All other source assignments remain from the saved layout.

- 18 groups change tile count in Indonesia, the Philippines, Greece, and Palestine.
- All country tile totals remain unchanged. The world has 54,967 unique land cells.
- All shared group borders remain. No new shared border is added.
- The same 64 enclosed water cells remain empty and enclosed.
- All 7,953,748,242 assigned people remain assigned exactly once by source component.
- There are 244 target groups: 241 from original OWID, plus the three added scopes.
- The largest free-group centre movement is less than two cells on either axis.
- All 173 Julia tests pass. A second full run produced identical cell and source-assignment CSV files.

| Group | Saved tiles | New tiles |
| --- | ---: | ---: |
| Indonesia G1 | 1,068 | 1,093 |
| Indonesia G2 | 386 | 380 |
| Indonesia G5 | 88 | 64 |
| Philippines G1 | 590 | 593 |
| Philippines G2 | 200 | 197 |
| Philippines G3 | 18 | 18 |
| Palestine G1 | 28 | 26 |
| Palestine G2 | 13 | 15 |

The full table is in `budgets.csv`. G IDs refer to the corner-connected artwork
groups, not necessarily single physical islands. `membership.csv` maps the old
T pieces to G groups. Japan, New Zealand, Brazil, Hong Kong, Trinidad and Tobago,
and the US keep their saved geometry because their group tile counts do not change.

## Population matching

1. Match source components and target groups with position, population, relative
   direction, and available source-border evidence. Shared source segments are
   evidence of a border; a source corner contact is not.
2. Map nearby small components relative to a larger matched outline. This avoids
   using one country-wide transform for every small island.
3. Use supported child-piece matches as additional source anchors within a group.
   Do not give each child its own tile budget.
4. Assign each remaining source component to its nearest matched source anchor.
5. If a target group has no supported anchor, join its nearest matched target
   group in a population pool. Split that pool's tiles by original target area.
6. Allocate integer tile counts with largest remainders and a minimum of one tile
   per existing G group. Keep each country's total fixed.

There is no manual island identity table in these rerun matches. Source distances
are centroid-to-polygon distances in a local latitude-corrected plane, not exact
geodesic distances. The anchor thresholds are heuristic: at least half a tile
of source population and a unary cost no greater than 0.12, unless source-border
evidence gives a unique candidate. A single target group receives its whole
scope population. These rules do not prove identity accuracy.

A population pool can contain several target groups. `pool_population` and
`pool_proportional_tiles` repeat for those groups in `budgets.csv`; do not sum
those repeated values. `source-assignments.csv` lists each source component once.
Unrepresented scopes from the parent remain unrepresented.

## Resizing

Free groups use the original OWID group outline as the scale guide. A deterministic
grid-growth step produces the exact count, with corner-connected land and
edge-connected water. It does not create enclosed holes. Placement retains
relative centre order within each scope and prevents contact with other groups.
Groups whose counts stay fixed retain the saved geometry, though a free group
in a changed scope can move to make room.

Groups with shared borders use local coast edits. Border cells and protected
water shores remain fixed. A perimeter cost discourages new notches. This is
not a new shared-island border fit. Borneo and New Guinea retain their saved
counts and outlines in this trial.

A changed group can have a different internal distribution from its saved child
pieces. The Philippines images show this clearly: the fit scales the combined
original group instead of retaining each child's earlier population allocation.

## Visual checks and work log

- A first single-anchor trial exposed poor allocations within archipelago groups.
- Added child evidence, rejection of weak anchors, and local outline-relative
  positions. Removed a test failure caused by treating repeated child border
  requirements as a mandatory one-to-one source match.
- Trials v2 and v3 completed all layout checks. Reviewed Indonesia, the Philippines,
  Greece, Palestine, and the world.
- A coast-only guide introduced a notch in Palestine. Added the general perimeter
  cost. A variable-shadowing error in v4 was caught by tests; v4 produced no layout.
- Trial v5 passed. Checked its changed attached outlines and world image. The
  Palestine outline is more compact. Indonesian small groups remain coarse;
  their identities and fallback pools still need user review.
- Repeated the full fit. The cells and source assignments were identical.

## Repeat

Run from the repository root. Use new output directories.

```sh
julia --project=owid-layout owid-layout/bin/resize-corner-groups.jl \
  data/cartogram.csv \
  output/auto-cartogram/owid-scope-split-v3 \
  output/auto-cartogram/world-dissolved/components.csv \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  output/auto-cartogram/julia-group-resize-new fit

julia --project=owid-layout owid-layout/bin/review-group-resize.jl \
  output/auto-cartogram/julia-group-resize-new \
  output/auto-cartogram/world-dissolved/components.csv \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  output/auto-cartogram/julia-group-resize-review-new
```

Use `audit` instead of `fit` to write population budgets without resizing.
The matching, fitting, checks, and SVG renderer are Julia code. This is still
not a clean raw-input production pipeline: component preparation and unchanged
assignments use the previous intermediates. It does not generate an Arrow mapping.
