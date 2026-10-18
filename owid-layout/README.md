# OWID layout: Julia migration

## Status

This project contains the first automatic identity matcher. It does not yet
build or replace a layout. It has no Python runtime calls.

The matcher recovers all 24 checked island identities without overrides.
These checks include Alaska, Oahu, the Big Island, and the main Japanese islands.
The checked identities are test expectations, not matcher inputs.

The reviewed layout remains at:

- Git tag: `owid-reviewed-scope-splits-2026-10-18`
- Commit: `31682a7`
- [Review page](../examples/auto-cartogram/results/owid-scope-splits/index.html)
- Cells: `examples/auto-cartogram/results/owid-scope-splits/cells.csv.gz`

SHA-256 of the saved compressed cells:

```text
4ed46fb942c91706ca138c409747ba95a7d1f5e6320e138a65342a0fcb614ede
```

SHA-256 of the saved `source-assignments.csv` in the same directory:

```text
dc833896648ddf701c655e418fab724daeb866b3eb164983d7d5bb7d225e611c
```

No existing layout, Python program, or H3-MON export has changed.

## Method

1. Read OWID cells. Use the last row at duplicate coordinates, as in the saved
   layout. Find connected pieces and give them stable IDs.
2. Read the existing Natural Earth/Kontur component files. Use polygon centroids
   and bounds, with longitude wrapping. Holes subtract area from the centroid.
3. Within each population scope, estimate a positive scale and translation
   from source bounds to OWID bounds.
4. Solve the joint position and population-cost assignment.
5. Test pair exchanges that reduce the combined cost, including relative
   direction between pieces. Stop when no exchange improves the cost.
6. Write candidate identities and separate position, population, and direction
   costs. Compare candidates with the checked identities only after matching.

Inputs are sorted by ID. Equal-cost choices use a stable order. No random
choices or elapsed-time limits enter the matcher. Reversing the source and
piece input order gives the same results in the tests. Two separate world runs
produced identical candidate CSV files with the pinned Julia environment.

The linear assignment is exact for its cost matrix. The pair-exchange step
finds a local result, not a proven global minimum of the combined cost.

## Run

From the repository root:

```sh
julia --project=owid-layout -e 'using Pkg; Pkg.instantiate(); Pkg.test()'

julia --project=owid-layout owid-layout/bin/audit-identities.jl \
  data/cartogram.csv \
  output/auto-cartogram/world-dissolved/components.csv \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  output/auto-cartogram/julia-identities-new
```

Use a new output directory. The report contains input and code hashes.
The audit does not write population assignments or layout cells.

The source descriptor fixture lets the tests run without the large geometry
files. It contains 654 components from the nine checked country scopes, not
just the expected matches. To regenerate it:

```sh
julia --project=owid-layout owid-layout/test/make-fixture.jl \
  output/auto-cartogram/world-dissolved/components.csv \
  output/auto-cartogram/world-dissolved/polygons.geojson
```

`config/country-codes.csv` contains numeric-to-alpha-3 ISO code pairs copied
from the local `iso-codes` table. It contains no island identities. The runtime
uses this saved table, not `/usr/share/iso-codes`.

## Work log

- Added the named checkpoint for the reviewed layout.
- Added a separate Julia project with pinned dependencies.
- The position/population baseline recovered 22 of 24 checked identities.
  Alaska was correct. Oahu and the Big Island were exchanged.
- Added the general relative-direction cost. A weight of 0.1 fixed Hawaii but
  introduced a Shikoku error. Weights 0.04, 0.06, and 0.08 retained the checked
  Japanese and US identities. The current weight is 0.05, with population
  weight 0.035. The full check then recovered all 24 identities.
- Passed 81 tests, including assignment checks against exhaustive search,
  reversed input order, holes, longitude wrapping, and all 24 identities.
- Ran the world audit twice. Candidate CSV files were identical.
- Saved the audit under `research/identity-audit/`.

## Remaining work

The cost weights were developed with these checks. Passing them is not an
independent accuracy estimate. Other islands still need review. Candidate
scores are not confidence probabilities. Across the 286 original OWID pieces,
44 candidates differ from the saved assignment anchors. Some old anchors were
fallback groups, not island identities. These differences need review, especially
in Indonesia and the Philippines; they are not 44 proven corrections.

This version does not yet use source-border evidence or reject weak identities.
Surplus target pieces receive empty candidate IDs. Unmatched source population
is not yet allocated. Pair exchanges cannot introduce an unused source after
linear assignment. These are limits to address before using the candidates
for tile budgets.

Next, test the other world identities and the unmatched-component rules.
Then port population allocation, shared-landmass resizing, placement, and
validation. Finally, replace the existing component preparation with Julia
input processing from Natural Earth and Kontur. Until then, the audit uses
existing component intermediates; it is not a raw-input production pipeline.
