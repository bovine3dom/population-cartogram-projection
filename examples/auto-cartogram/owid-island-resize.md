# OWID island population resize trial

## Status

The trial is `output/auto-cartogram/owid-island-resize-v9`.
Review page: `results/owid-island-resize/index.html`.
No default layout or H3-MON mapping changed.

The trial changes 53 tile pieces in 11 country scopes. All 54,967 unique land
cells remain allocated. Every country keeps its previous total. All pieces
remain connected. Existing contacts between pieces stay unchanged. The 172
enclosed empty cells and their shore labels are retained.

Malaysia and the Philippines are blocked and remain unchanged. Malaysian
Borneo cannot shrink to its requested budget while retaining its border cells
and connectivity. Philippine part T5 cannot grow to its requested budget
within the shape margin and protected water constraints. The whole country's
trial is rolled back on failure. `matches.csv` separates requested `tiles`
from `actual_tiles` and gives the resize status.

## Population assignments

Use the existing Kontur component populations. ISO map-unit codes take
priority over sovereign-country codes. Explicit aliases map SDS to SSD, PSX
to PSE, and SAH to ESH. A source scope with no OWID tile remains unrepresented;
it is not sent to another country.

`owid-reviewed-identities.csv` contains 24 visually checked identities.
The remaining matches are experimental. They use component position and a
small population-size cost, not equal source and target ranks. Nearby small
islands use the extent of a larger matched neighbour. Remote islands do not
use that local correction. A real source border helps identify the correct
component. Artwork-only country contacts are not used as identity evidence.
This is not a border-aware population fit.

Unreviewed matches with cost above 0.12 are rejected unless source border
context uniquely identifies the component. This threshold is a trial heuristic,
not a measured confidence level. Automatic identities still require review.

An unmatched source component joins the nearest matched source geometry in
its country scope. Distance uses a local longitude/latitude plane with a
latitude correction and longitude wrapping. It is approximate, not a geodesic
calculation. An unmatched target piece joins its nearest matched target group.
Its share within that group follows the existing target-area ratio. Thus a
fallback group is not proof of each small island's population accuracy.

The assigned population is 7,947,374,949. Of this, 90,277,129 joins a matched
source through the nearest-component fallback. These totals include single-part
countries where all source islands must use the only available target group.
There are 24 reviewed target identities, 242 automatic identities, and 20
nearest-target fallbacks. Many automatic identities are single-part countries.
All source assignments and unrepresented scopes are exported for inspection.

## Resizing

Keep country totals fixed. Allocate group budgets by population, subject to
minimum counts for visibility and pinned border or water-shore cells. Use
largest remainders for integer counts. Existing pieces keep at least one cell.
These constraints can prevent exact population proportions.

For a free island, scale its OWID outline uniformly, build an exact-count
connected template, then find a nearby collision-free position. Translation
is limited to 16 cells per axis. Keep a gap from other pieces. This reuses
`geographic_baseline.grow` and `shape_placement.place`.

For a piece with fixed border or water-shore cells, grow or remove boundary
cells toward the scaled outline. Retain connectivity and pinned cells. Growth
stays within three cells of the guide. Shrink donors before growing recipients.
Reject a country's changes if any piece fails or enclosed water changes.

## Visual review and limits

The panels now use shared G labels and colours for the same assigned group.
An asterisk marks an automatic identity or target fallback. Before and after
use the same coordinate frame. Source geography uses a separate scale.

Checked the world, Japan, Indonesia, the US, and a contact sheet for the other
resized countries. Hokkaido shrinks from 193 to 34 tiles. Honshu grows from
509 to 697. Sumatra grows from 271 to 377. Indonesian Borneo shrinks from
248 to 118. Corsica shrinks from four to two. The Isle of Wight shrinks from
four to one. Grouping and protected-cell floors explain differences from the
previous component-only quotas.

Large island outlines remain recognizable, but raster steps and narrow border
sections remain. Tiny shapes cannot retain much detail. Small archipelago
identities remain uncertain. No shape or population mapping is approved for
production from these checks alone.

## Reproduction

```sh
PY=output/auto-cartogram/geometry-env/bin/python
OPENBLAS_NUM_THREADS=1 "$PY" examples/auto-cartogram/resize_owid_islands.py \
  data/cartogram.csv \
  output/auto-cartogram/world-dissolved/components.csv \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  /usr/share/iso-codes/json/iso_3166-1.json \
  examples/auto-cartogram/owid-reviewed-identities.csv \
  output/auto-cartogram/owid-island-resize-v9

"$PY" examples/auto-cartogram/review_owid_resize.py \
  data/cartogram.csv output/auto-cartogram/owid-island-resize-v9 \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  output/auto-cartogram/owid-island-resize-review-v9
```

Use new output paths for a repeat run. Input and dependency hashes are recorded.
The OWID-format CSV reverses the inventory coordinate conversion. It contains
one row per occupied cell. The 11 overlapping South Africa/Lesotho input rows
use the audit's last-row convention. The original input is unchanged.

## Work log

Initial trials could not shrink or grow several constrained pieces. Reusing
free-island template scaling improved shape retention and made Japan feasible.
Pinned-cell minimum budgets prevent requests below the protected shore count.

Visual review rejected a country-wide local-coast extrapolation that assigned
Alaska and a Canary Island to unrelated coastal components. Restricting that
correction to nearby source islands fixed those cases. Added source border
context to distinguish Timor from unrelated Indonesian islands. High-cost
assignments now fall back instead of forcing a one-to-one match.

Added checked identities for Alaska, Oahu, Hawaii, Okinawa, New Zealand,
Malaysia, and Trinidad and Tobago. The final review reverses the initial
unreviewed Oahu/Hawaii assignment using their relative positions.
All 365 Python tests pass, including eight new resize and matching tests.
No trial solver jobs remain running.
