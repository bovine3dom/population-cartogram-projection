# Split combined OWID population groups

## Result

This trial splits three existing tile budgets. It does not add tiles to the map.
See the [review images and data](results/owid-scope-splits/index.html) and the
[population-source audit](owid-missing-scope-audit.md).

| Existing group | New allocation | Total tiles |
| --- | --- | ---: |
| Serbia, including Kosovo | Serbia 45; Kosovo 10 | 55 |
| Somalia, including Somaliland | Somalia 89; Somaliland 28 | 117 |
| Whole Cyprus | Cyprus residual group 6; Northern Cyprus 2 | 8 |

The allocations use source population totals and largest remainders.
The labels identify statistical groups. They do not state sovereignty.
The Cyprus residual group includes the buffer-zone and British base-area source
populations. These areas do not receive separate tiles at this scale.
See `owid-scope-crosswalk.csv` for the explicit assignments.

## Checks

- All 54,967 occupied cell positions remain unchanged from the parent layout.
- All sea and lake positions remain unchanged, including 64 enclosed water cells.
- The layout has 289 connected parts, up from 286.
- Each source component has at most one assignment. Total source population is conserved.
- The assignments now include 6,373,293 people who previously had no target.
- The remaining source groups without tiles contain 929,748 people.
- Existing neighbour tile counts remain unchanged. Some shared borders move.
- Kosovo touches Albania, Montenegro, North Macedonia, and Serbia.
- Somaliland touches Djibouti, Ethiopia, and Somalia.

The local fit uses shared source boundaries, not corner contact, to set the
required neighbours. It removes the old Albania–Bosnia and Herzegovina contact.
It replaces Albania–Serbia with Albania–Kosovo and Djibouti–Somalia with
Djibouti–Somaliland. It also restores Croatia–Montenegro,
North Macedonia–Serbia, and Montenegro–Serbia contacts.

I checked the three regional images and the world image. Kosovo forms a compact
part. Nearby small countries have coarse outlines, but no long connecting paths.
Somaliland occupies the northwest of the old Somalia group. Northern Cyprus
uses two northern cells in the eight-cell island. This island is too small for
a detailed border.

The Python test suite passes: **398 tests**.
The default layout and H3-MON files have not changed. This is a review trial,
not an approved replacement.

## Work log

1. A dense local fit did not find a valid Kosovo result within 120 seconds.
2. A sparse fit with candidate radius 4 reached its 180-second limit before it
   found a connected result.
3. A sparse fit with candidate radius 2 and a 240-second limit completed all
   three splits. Kosovo required 5 solves, Somalia 32, and Cyprus 1. Intermediate
   solves added constraints to remove disconnected parts.
4. Checked population totals, cell positions, water, neighbours, and connected
   parts. Rendered and checked the review images.
5. Committed the implementation as `2e7c080`.

## Repeat the trial

Run from the repository root with the existing parent layout and source files:

```sh
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1 \
output/auto-cartogram/geometry-env/bin/python \
examples/auto-cartogram/split_owid_scopes.py \
output/auto-cartogram/owid-landmass-world-v16 \
output/auto-cartogram/world-dissolved/components.csv \
output/auto-cartogram/world-dissolved/polygons.geojson \
examples/auto-cartogram/owid-scope-crosswalk.csv \
output/auto-cartogram/owid-scope-split-v3 \
--seconds 240 --margin 2
```

Use a new output directory if the named directory exists. Here, `--margin` sets
the candidate-label radius. The report records input hashes and solver checks.
Time-limited runs can produce different valid results.

The review includes `cells.csv.gz`, source assignments, the crosswalk, and the
checks. It does not include an OWID numeric-code export: KOS, SOL, and CYN are
source-scope labels, not ISO numeric codes. A later export must use explicit
scope identifiers. It must not invent ISO codes or reuse the old numeric file.
