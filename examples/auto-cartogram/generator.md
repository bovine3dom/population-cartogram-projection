# Headless mosaic experiment

This is a research tool, not a replacement for the production map. It does not
change the transport solver. Read `work-log.md` for completed runs and failures.
Read `../../auto-cartogram.md` for the research plan.

## Build

Run commands from the repository root. You need Julia 1.12, Python, Git, curl,
`fd`, `patch`, and `sha256sum`. The default Java download requires Linux x86-64.
On another platform, set `JAVA_HOME` to a JDK 21 installation.

```sh
bash examples/auto-cartogram/bootstrap.sh
julia --project=examples/auto-cartogram -e 'using Pkg; Pkg.instantiate()'
python3 -m venv output/auto-cartogram/geometry-env
output/auto-cartogram/geometry-env/bin/pip install -r examples/auto-cartogram/geometry-requirements.txt
```

The build checks upstream revisions and the downloaded JDK checksum. It writes
`build-info.properties` with revisions and source hashes. The adapter copies
this record into new layouts. Copy the class directory before long experiments
so later builds cannot change their class files. It applies
`upstream-fixes.patch` to copies, not to the upstream checkout. The patch fixes
an inverted size assertion, removal-queue ties, and a local connectivity check.
Keep Java assertions enabled for reference runs. The independent flood-fill test checks
accepted moves against both land connectivity and four-neighbour sea holes.
A second oracle compares 1,000 small flow problems with exhaustive optima. The
unpatched flow solver stalls on this test. The patch updates each reduced cost
once and removes only tiny negative roundoff terms on usable edges. Larger
negative reduced costs cause an error. The tolerance is 16 floating-point units
at the network cost scale. Inactive reverse edges keep their negative costs.
Polishing now restores the previous tile ownership if a partly executable flow
does not reduce count error. A synthetic forced-flow test checks the rollback.
Each transfer uses its planned destination owner. An earlier transfer must not
change that owner. A second test executes a transfer chain in reverse order.
Topology mode can then report a residual count error instead of accepting a
worse pass. Exact mode still fails if it cannot obtain the requested counts.

The optional `-Dmosaic.initialSeaOnly=true` setting removes temporary sea
regions immediately after grid initialization. It retains every land cell
and land contact, then fits only the original population regions. This avoids
artificial sea-contact constraints during fitting. Unit and adapter tests check
this transition. The default retains sea regions through fitting for comparison.

The initializer reports a necessary tile-budget bound: a connected shape of
`n` square cells has at most `2n+2` boundary edges. Temporary sea contacts violate
this bound for one one-tile region at each of the 10,000 and 110,000 world
budgets. The original land contacts have no such violation. This bound alone
does not prove that a layout exists. See the
[degree checks](results/world-dissolved-input/degree-bound.json).

`planar_embedding.py --no-sea` instead exports the original dual without added
vertices. NetworkX draws it by adding edges to a private copy, not to the
exported constraints. All three world trials fail upstream geometric preflight
with crossing assertions. Do not use this route for the current world inputs.
See the [NetworkX drawing source](https://networkx.org/documentation/stable/_modules/networkx/algorithms/planar_drawing.html).

## Prepare population and shapes

The population file must contain H3 resolution-8 `h3` and `population` columns.
The current external input does not declare a population year. Keep each output
directory new. Large inputs and intermediate files stay under ignored `output/`.

```sh
BASE=output/auto-cartogram
BOUNDARY=make-lookup-table/population-data/country-boundaries/ne_10m_admin_0_map_units.geojson
POP=/path/to/kontur_h3.arrow
PY=$BASE/geometry-env/bin/python
julia --project=examples/auto-cartogram examples/auto-cartogram/prepare_points.jl "$POP" "$BOUNDARY" "$BASE/world-centres"
"$PY" examples/auto-cartogram/assign_population.py "$BASE/world-centres" "$BASE/world-components"
julia --project=examples/auto-cartogram examples/auto-cartogram/prepare_layout.jl "$BASE/world-components/components.csv" "$BOUNDARY" "$BASE/world-10000-input" 10000 world group
"$PY" examples/auto-cartogram/validate_outlines.py "$BASE/world-10000-input"
PYTHONHASHSEED=0 "$PY" examples/auto-cartogram/geographic_embedding.py "$BASE/world-centres/polygons.geojson" "$BASE/world-10000-input" "$BASE/world-10000-rotation"
PYTHONHASHSEED=0 "$PY" examples/auto-cartogram/planar_embedding.py "$BASE/world-10000-input" --rotations "$BASE/world-10000-rotation/rotations.json"
```

Population assignment uses polygon interiors and H3 cell centres. It excludes
holes. It records unmatched and ambiguous cells separately. It does not split
coastal cells or repair the longitude seam. The first world run excludes about
77.25 million unmatched people. Do not interpret the matched total as complete
world coverage.

Stable polygon IDs include the map-unit ID and a hash of the original rings.
Country grouping uses Natural Earth `ADM0_A3`, not its inconsistent numeric
codes. This choice records source entities; it does not resolve disputed borders.

The `group` policy gives each populated country at least one tile. It allocates
country totals, then component totals. Components with zero tiles join the
nearest represented component in the same country. Their population remains in
the group. This is an explicit loss of island detail, not individual island
preservation. The `omit` policy instead leaves zero-tile population out of shapes.

### Remove internal map-unit borders

Natural Earth map units are not always separate islands. For example, the input
splits Great Britain and Belgium into adjacent units. Use the optional union
stage before tile allocation to remove these internal borders:

```sh
"$PY" examples/auto-cartogram/dissolve_map_units.py "$BASE/world-centres/polygons.geojson" "$BASE/world-components/components.csv" "$BASE/world-dissolved"
julia --project=examples/auto-cartogram examples/auto-cartogram/prepare_dissolved.jl "$BASE/world-dissolved"
julia --project=examples/auto-cartogram examples/auto-cartogram/prepare_layout.jl "$BASE/world-dissolved/components.csv" "$BASE/world-dissolved/boundaries.geojson" "$BASE/world-10000-dissolved-input" 10000 world group
```

Then validate outlines and build the geographic rotation file using
`world-dissolved/polygons.geojson`. The union stage merges exact shared-border
polygons only within the same `ADM0_A3`. It does not join point contacts,
disconnected islands, or different countries. It uses no coordinate snapping.
It preserves the population assigned to original polygons and records an
original-to-dissolved ID table. Future transport must apply that table before
the small-island grouping table. The Indonesia-only transport tests still use
their original, unchanged input.

## Generate and inspect

Use the Java path printed by the build (also in `vendor/java-path.txt`). For example:

```sh
JAVA=output/auto-cartogram/vendor/jdk-21.0.12.1/bin/java
INPUT=output/auto-cartogram/world-10000-input
LAYOUT=output/auto-cartogram/world-10000-layout
timeout 3600s "$JAVA" -ea -Xmx8g -Djava.awt.headless=true \
  -cp output/auto-cartogram/vendor/classes MosaicAdapter \
  "$INPUT/augmented.wkt" "$INPUT/augmented-weights.tsv" "$LAYOUT" \
  topology directional "$INPUT"
python3 examples/auto-cartogram/review_layout.py "$INPUT" "$LAYOUT"
rsvg-convert "$LAYOUT/review.svg" -o "$LAYOUT/review.png"
```

The adapter can also take `validated.wkt` and `weights.tsv` without an embedding
directory. `agnostic` uses upstream placement. `directional` restricts placement
of separate land groups to source bearings. Neither method guarantees good
geographic position. `exact` requests exact tile counts; `topology` permits count
errors when needed by upstream constraints. Always check exported counts.

For bounded preview runs, set Java properties such as
`-Dmosaic.forceIterations=2000 -Dmosaic.scaledPatience=50 -Dmosaic.finalPatience=100`.
The optional `-Dmosaic.maxRounds=50` stops each reshape stage after 50 rounds
and returns its best state. This can increase tile-count and shape errors.
The optional `-Dmosaic.orientInitial=true` selects a rigid square-grid rotation
or reflection before guide fitting. It fits region centres to source centres,
with square-root population-budget weights. Counts and contacts do not change
in this step. It is an experiment, not a guarantee of geographic order.
In topology mode, `-Dmosaic.polishIterations=0` skips the final count correction.
Use this only to inspect an unfinished preview. The marker records the setting.
These limit force iterations and rounds without improvement. They do not impose
a wall-clock limit; keep the external timeout. The completion marker records them.

For a separate performance experiment, use `-da:arrange.model.MosaicCartogram`
after `-ea`. This disables assertions in the model and its nested region class;
other Java assertions stay enabled. It is not an all-assertions run. Independent
final count, connectivity, hole, and contact checks remain required.

An earlier flag targeted only `MosaicCartogram$MosaicRegion`. It did not disable
the region assertions: JLS 14.10 uses the enclosing top-level class status.
The old adapter recorded the requested nested-class status, not the effective
status. Affected saved runs have `assertion-status-correction.json`; their raw
completion records are preserved. Those runs actually kept model assertions
enabled. The adapter and a bytecode-backed test now check the correct status.

The review tool also reports country and island axis-order errors, shape
compactness, and a country-uniform-tile cross-group capacity lower bound.
These are separate diagnostics. Unknown source coverage is shown as unknown,
not as zero. `save_review.py --refresh` can update derived checks only when the
saved tile export and input manifest still match.

The outline check rejects invalid original projected rings. If a simplified ring
crosses itself, it restores the original projected ring and records the change.
Never send unchecked `input.wkt` to the generator. The first global check found
43 invalid simplified rings at 10,000 tiles.

For a fast geography-first comparison, run:

```sh
"$PY" examples/auto-cartogram/geographic_baseline.py "$INPUT" "$LAYOUT"
python3 examples/auto-cartogram/review_layout.py "$INPUT" "$LAYOUT"
```

This baseline grows separate, connected shapes to exact tile counts. It keeps
a gap between shapes and therefore removes all land borders. The review report
records these missing contacts. It is not a topology-preserving substitute.

`repair_contacts.py INPUT BASELINE NEW_OUTPUT` tries to restore these borders.
Run it with the same Python environment. It grows a path toward a required
neighbour and removes a boundary cell for each added cell. Local checks keep
regions connected and prevent holes. The method keeps exact component counts
and all contacts already restored. It forbids false contacts. Failed paths are
rolled back. Some borders remain missing, and long thin connectors can damage
shape and position. This is a separate experiment, not the published algorithm.

`relax_layout.py INPUT BASELINE NEW_OUTPUT` first tries whole-shape translations.
It reduces squared gaps between required neighbours, with a penalty for movement
from each baseline position. The penalty is `stiffness * sqrt(tile_count)` times
squared translation distance. Shapes and counts do not change, and false
contacts are forbidden. The default stiffness is 0.05; `--rounds` bounds the
coordinate search. This can improve later border repair, but can damage country
and island order. It does not preserve every contact during the translation
stage. Run the independent review after each stage. Repair metadata records the
parent layout settings as well as its tile-file hash.

Without `--rotations`, the initializer uses an arbitrary planar embedding. This
can put entire continental regions inside the wrong faces. Retained contacts
alone do not imply a useful geographic layout.

The planar initializer requires `PYTHONHASHSEED=0` for repeatable NetworkX
choices. Save its embedding files with each experiment.
It uses original represented contact edges. The recommended geographic rotation
file selects one shared border segment per neighbour pair, on both sides of the
border. It derives neighbour order from boundary traversal. It discards other
shared segments; this is not full border or enclave preservation. Every connected
graph is checked before the Java fit starts.

The initializer adds temporary
sea regions to remove cut vertices without adding false land borders. Sea tiles
are exported separately and carry no population. This construction does not
guarantee geographic position or enclave containment. Original WKT outlines
omit holes. A successful represented-contact check is not proof of full
geographic topology.

`complete.txt` appears only after export. The review tool rejects missing owners,
unknown owners, and duplicate cells. It writes count, connectivity, and contact
checks plus a headless SVG. Inspect the image as well as the numbers.

## Island transport experiment

`group_transport.jl` calls the existing CPU transport solver separately for each
declared group. It does not change the solver. Its source input is the native
`source-components.arrow` from the Indonesia audit. The group table and layout
must have matching mass and tile budgets.

```sh
julia --threads=2 --project=examples/auto-cartogram examples/auto-cartogram/group_transport.jl \
  output/auto-cartogram/indonesia-reviewed/source-components.arrow \
  output/auto-cartogram/indonesia-1894-v2-input \
  output/auto-cartogram/indonesia-1894-v2-layout \
  output/auto-cartogram/indonesia-transport-r3-grouped 3 grouped
```

Resolution 3 is a coarse test. The script combines sources by original component
and H3 parent, without combining different component identities. It uses
population-weighted source centres in the Equal Earth projection. The wrapper
converts north-up target y to the solver's downward screen convention, then
restores north-up y in the export. Resolution 8
keeps native source cells. `pooled` instead runs one unrestricted country solve
as a comparison. Do not interpret a coarse comparison as a native-cell result.

Grouped transport permits movement within declared island groups, but not between
groups. Each group has its own population per tile. It therefore does not enforce
one exact population value per tile across the country. The existing sparse
export also retains only part of each source contribution. Inspect retained mass
and target error as well as cross-group mass. The script does not renormalize
away these errors. Use `check_transport.py TRANSPORT_DIR NEW_CHECKS.json` to
check the CSV export independently. It recomputes retained source weights,
target totals, and cross-group population. It rejects unknown IDs, duplicate
pairs, invalid weights, and differences from the saved summary.
`check_native_sources.py SOURCE.arrow GROUPS.csv TRANSPORT_DIR NEW_CHECKS.json`
also checks every native source ID, population, and group label against the
original files. It requires the geometry Python environment.

### Optional sparse balance correction

`balance_transport.py TRANSPORT_DIR NEW_OUTPUT` alternates source and target
scaling on the exported nonzero pairs. Run it with the geometry Python
environment. It does not add pairs or change group eligibility. It rejects
incompatible total mass and disconnected support with incompatible capacities.
Other support constraints can also prevent convergence. A bounded failure is
not proof of infeasibility. The script exports only if the target tolerance is
met, then runs the independent CSV checker. Original solver exports remain
unchanged. This correction changes transport weights and needs a separate
spatial-quality review.
`review_balance.py RAW_DIR CORRECTED_DIR NEW_OUTPUT` draws native H3-8 target
errors on one colour scale. It verifies file hashes, unchanged source/target
tables, equal capacities, and every ordered nonzero pair before drawing.

## Tests

```sh
julia --project=examples/auto-cartogram test/auto_layout.jl
julia --project=examples/auto-cartogram test/auto_transport.jl
python3 test/auto_layout.py
python3 test/auto_transport.py
output/auto-cartogram/geometry-env/bin/python test/auto_geometry.py
```

## License boundary

`MosaicAdapter.java`, `DirectionalPlacement.java`, `GeographicOrientation.java`,
`upstream-fixes.patch`, and
the Java oracle tests are GPL-3.0-or-later experimental code. See
`MosaicAdapter.LICENSE`. GridMapPipeline is GPL-3.0; GeometryCore is
GPL-3.0-or-later. Keep this optional Java experiment separate from the main
Julia package. Review distribution terms before shipping a combined product.

## Method references

- [Java assertion status, JLS 14.10](https://docs.oracle.com/javase/specs/jls/se21/html/jls-14.html#jls-14.10)
- [GridMapPipeline](https://github.com/tue-alga/GridMapPipeline)
- [GeometryCore](https://github.com/tue-alga/GeometryCore)
- [Equal Earth projection, EPSG method 1078](https://epsg.io/1078-method)
- [Shapely polygon union](https://shapely.readthedocs.io/en/stable/reference/shapely.union_all.html)
- [Shapely spatial index](https://shapely.readthedocs.io/en/stable/strtree.html)
- [NetworkX planar drawing](https://networkx.org/documentation/stable/reference/algorithms/planar_drawing.html)
- [Pukelsheim: matrix scaling and convergence conditions](https://d-nb.info/1275986811/34)
- [NetworkX minimum-cost flow: floating-point warning](https://networkx.org/documentation/stable/reference/algorithms/generated/networkx.algorithms.flow.min_cost_flow.html)
