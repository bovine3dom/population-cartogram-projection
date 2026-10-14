# Automatic population mosaic cartograms

## Recommendation

Replace the fixed OWID layout with an offline generator. Give each geographic
component its own population budget. Then run population transport separately
for each component. Keep the existing transport solver and its public interface.

Start with square tiles and the mosaic-cartogram implementation in Wouter
Meulemans's 2026 **GridMapPipeline** [3, 4]. It extends the method in the supplied
2015 paper and adds automatic placement of disconnected outlines. Test it before
writing a new generator in Julia.

This research preceded implementation. A first
[Indonesia island audit](examples/auto-cartogram/results.md) is now complete.
It measures population and tile-capacity mismatches; it does not replace the map.
A later [review gallery](examples/auto-cartogram/gallery.md) contains automatic
world previews at 10,000, 55,000, and 110,000 tiles. It compares geography-first
baselines, border repair, and topology-first fits. None is a production
replacement. The [transport tests](examples/auto-cartogram/transport-results.md)
measure cross-group movement and target errors on the automatic Indonesia
layout. See the [work log](examples/auto-cartogram/work-log.md) for run details.

For the research below, I inspected the two supplied papers, upstream
documentation and selected source files, this repository, and issue #17.
I also checked the local target CSV. No new layout generator was run for that
initial research.

## Implementation update

The prototype now has automatic world images at 10,000, 55,000, and 110,000
tiles. Geographic layouts keep exact budgets but lose borders. Topology-first
fits retain represented borders but still have unacceptable area and position
errors. Border repair provides a middle case, with missing borders and thin
connectors. **Do not replace the production CSV with these layouts yet.**

The native Indonesia experiment uses all 832,166 matched source cells and
explicit target groups. Separate solves prevent cross-group transport. The raw
export retains 99.883% of population and has up to 7.350% target error. A separate
sparse balance correction restores source totals to floating-point precision
and reduces maximum relative target error below 0.01%, without adding pairs.
This does not preserve every island: zero-budget islands can share a group.
It also permits population per tile to vary between groups.

A later placement step keeps all island shapes and counts, but reduces island
axis-order errors from 426 to 5 out of 2,323 comparisons. The balanced native
mapping moves with those shapes through checked integer translations. No
weights change, and the new export passes flow and native-source checks.

Whole-world H3-3 tests also keep cross-group mass at zero, but have target errors
up to 36.090%. Their saved sparse support cannot reach the 0.01% correction
limit. Thus, successful grouping and a good layout image do not prove balanced
transport. At 10,000 tiles, H3-5 source detail reduces the raw target error to
2.471%. A minimum-cut check still proves that the saved pairs require at least
1.161% error in one group. More scaling iterations cannot fix that obstruction.
A separate local pair-expansion test fixes the 10,000- and 55,000-tile coarse
cases: full source mass, zero cross-group movement, and target error below
0.01%. The 110,000-tile case still fails. Some expected source positions change
substantially, so balance alone is not approval of spatial quality.
The gallery now includes a six-image resolution and border-policy
overview, plus a table of initialization and fitting experiments.

These results support component-aware inputs and explicit group eligibility.
They do not establish a production-ready world layout. Source year, unmatched
coastal population, small-island policy, and geographic quality remain open.
See the [gallery](examples/auto-cartogram/gallery.md),
[transport evidence](examples/auto-cartogram/transport-results.md), and
[work log](examples/auto-cartogram/work-log.md).

### Recommended next milestone

Review the gallery before more fitting work. Decide whether gaps between
countries are acceptable. If they are, use the exact-count geographic method
as the next candidate and improve its placement. If borders are mandatory,
work on geographic initialization and constrained shape fitting. More polishing
alone has not met the area requirement.

Keep layout acceptance separate from transport acceptance:

1. Set per-country and per-component limits, not only a global count error.
2. Choose the small-island grouping and per-group capacity rules explicitly.
3. Resolve the population year and unmatched coastal coverage. Do not assign
   unmatched cells to the nearest country without an ownership rule.
4. Repeat native tests on more archipelagos. Check sparse-support feasibility
   before long correction runs, then inspect large position changes.
5. Only then add a production exporter and optional group eligibility. Preserve
   a rollback path to the existing CSV. Keep source entity IDs until their
   conversion to the repository's numeric country codes is checked.

## 1. What must change

### Current workflow

`data/readme.md` records an OWID export with fluid scale, year 2026, radius 1,
and square cells. `examples/common.jl::load_cartogram` reads the headerless
`x,y,country` file. It expects integer country codes and can subdivide each
square into `factor²` smaller squares.

The public solver accepts target coordinates, not country boundaries or island
identities. `src/spatial.jl::_masses` assigns equal target mass within each solve.
`distribute` returns source and target weights for fixed target positions.
It cannot resize an island or move its outline.

The existing continuity experiments also keep target capacities fixed.
`examples/continuity/planet.md` explicitly states that they do not solve the
island-area problem. Better continuity costs cannot correct wrong capacities.

The description “handmade OWID cartogram” needs one qualification. OWID's tool
also has automatic steps. Its documentation describes a population-scaled base
map, a Dougenik-style deformation, grid sampling, and manual cell movement [5].
The replacement must remove dependence on that fixed country-level layout. It
is not enough to automate the same export settings.

### Issue #17: population moves to the wrong island

Issue [#17][issue] proposes a Kontur audit and separate island codes. Its linked
Mastodon thread explains the failure [6]: country-level scaling gives islands
areas that do not match their populations. It reports severe errors in Indonesia
and Portsmouth population assigned to the Channel Islands. These are the
reporter's observations; this research did not reproduce those mappings.

The capacity mismatch gives a useful lower bound. For one country, let:

- `P` be its total source population.
- `T` be its total target-cell count.
- `P_i` be the source population of island component `i`.
- `T_i` be the target-cell count assigned to that component.

With equal target masses, the island receives capacity:

```text
capacity_i = P * T_i / T
excess_i = capacity_i - P_i
minimum_cross_component_mass = 0.5 * sum_i abs(excess_i)
```

The last expression assumes complete, matching source and target component
partitions. It is a lower bound on population that must cross component labels
in any balanced country-wide transport plan. Geometry can force more movement.
Changing eta cannot remove this lower bound.

**Two changes are necessary:**

1. Set island tile counts from island populations, not island land areas.
2. Prevent transport between distinct island groups unless the grouping policy
   explicitly permits it.

Correct counts alone do not prevent mixing in an entropic country-wide solve.
Separate solves provide that restriction without a new core solver API.

### Small audit of the current CSV

At repository commit `21cabe3`, `data/cartogram.csv` contains 54,978 rows,
208 country codes, and 54,967 distinct coordinate pairs. All coordinates are
even integers. I counted components using side adjacency at a grid step of 2.

| Country code | Cells | Side-connected target components |
| --- | ---: | --- |
| Indonesia, 360 | 1,894 | 25; largest sizes 1,050, 271, 248, 138 |
| United Kingdom, 826 | 459 | 3; sizes 439, 16, 4 |
| France, 250 | 438 | 2; sizes 434, 4 |
| Russia, 643 | 975 | 1 |

These are artwork components, not identified geographic islands. Do not assign
island names from size or position alone. A single artwork component can also
combine geographic parts that should be separate.

There are 11 coordinate pairs shared by South Africa (710) and Lesotho (426).
A new generator must give each target cell exactly one owner. Do not copy these
overlaps into a global target table. Country-code compatibility also needs an
explicit table: the older workflow maps OWID France 250 to Natural Earth 249.

CSV SHA-256:
`a08f41f7b3f8912e3956c8882a255a0e6ea60b5a720216a0746416ba5d62c257`.

## 2. What the supplied papers establish

### Cano et al. (2015): Mosaic Drawings and Cartograms

The paper gives an automatic square or hexagonal mosaic method [1, Sections
3–5]. A region is represented by an edge-connected set of tiles. The final
configuration has no holes. Its contact graph must match the input graph.

The method has three main stages:

1. **Construct a valid initial layout.** Build a mosaic drawing from the
   augmented map dual. Vertices represent regions; edges represent contacts.
   The construction uses an orderly spanning tree. A Schnyder-labeling variant
   gives better initial relative positions.
2. **Move and reshape.** Scale each region to its required tile area. Construct
   a connected, exact-size guiding shape from grid intersections. Try several
   small offsets and prefer low symmetric difference. Move these guides with
   attraction and repulsion forces. Transfer boundary tiles only when the
   connectivity and adjacency tests permit the change. Increase resolution in
   stages for large outputs.
3. **Correct tile counts.** Build a minimum-cost flow problem over boundary
   tiles, region supply nodes, and the sea. Transfer tiles from surplus regions
   to deficient regions. Rebuild the problem after changes. Costs discourage
   departures from the guiding shapes.

This is not ordinary rasterization of a continuous cartogram. Its topology
checks are a central part of the algorithm. A global assignment of tiles by
nearest distance would not provide the same guarantees.

Important limits:

- The construction theorem for a valid mosaic drawing does not guarantee a
  good layout with any requested set of small integer areas.
- The moving stage has no convergence guarantee. The implementation uses an
  iteration limit. The flow stage can stop with residual tile-count error.
- “Zero cartographic error” can mean exact agreement with rounded integer
  weights. It does not remove the earlier population-rounding error.
- The experiments represent each region as one connected shape, even for
  disconnected regions such as Greece and Michigan. Thus the tested method
  does **not** directly solve issue #17.
- Strict adjacency can create long, narrow extensions. More resolution is not
  an unconditional cure for poor shape.
- Hexagons often need fewer tiles than squares to attain low count error in
  the reported tests. This is evidence for a comparison, not a reason to
  replace the repository's square-grid interfaces immediately.

The Java prototype took under a minute for small examples and 10–15 minutes
for larger examples. Those measurements are not estimates for this world map.

### Nusrat and Kobourov (2016): The State of the Art in Cartograms

The survey discusses mosaic cartograms in Section 5.5 [2]. It summarizes the
Cano method; it does not provide a second independent mosaic algorithm.
Its main contribution here is a framework for selecting and evaluating methods.

Measure three separate properties:

- **Statistical accuracy:** does displayed area match population?
- **Geographical accuracy:** are shape and relative position recognizable?
- **Topological accuracy:** are the correct regions adjacent?

Sections 6–7 also distinguish user tasks, such as locating a region, comparing
areas, and finding neighbours. Section 11 recommends linked geographic views
and identifies gaps in user evaluation of newer cartogram types.

For this project, add a fourth property: **attribution accuracy**. A map can have
correct national areas while placing an island's population on another island.
Neither a small national area error nor a smooth-looking transport field is a
sufficient acceptance test.

## 3. Further research: a stronger starting point

### Meulemans (2026) and GridMapPipeline

The 2026 paper directly revises the Cano algorithm [3]. It separates processing
of disconnected outlines and later combines their layouts. It also improves
guiding-shape construction, shape storage, overlap tests, and connectivity tests.
Its shape representation supports constant-time translation. Its tile moves
keep regions simply connected, which permits local connectivity tests.

The paper reports single-run mosaic times of 13 seconds for Europe population,
7 seconds for US businesses, and 35 seconds for US Starbucks locations.
These are much smaller test cases, not a benchmark of this repository's data.
The Europe timing excludes islands.

The island placement stage is especially relevant [3, Section 6]:

- Generate a layout for each connected outline separately.
- Select components to combine by size or geographic proximity.
- Translate components on the grid. Reject overlaps and edge contacts between
  outlines that must remain separate.
- Use geographic directions and, for grid maps, assigned sites to guide placement.

No one placement strategy wins every example. The paper prefers different
strategies for the UK and the Netherlands. It also notes remaining defects in
island-chain placement. This is a useful automatic starting point, not proof
that a world population layout will look good.

**Do not confuse the full grid-map pipeline with a population mosaic.** Its
normal grid-map task assigns one tile per site. We need many tiles per region,
with counts set by population. Use the cartogram route instead of creating
millions of artificial sites.

The inspected implementation provides that route [4]:

- `main/Cartogram.java` accepts labeled outlines and TSV weights.
- `common/Partition.java` has `customWeight`; `getWeight()` uses it when positive.
- `arrange/DeformAlgorithm.java` generates the mosaic.
- `main/Cartogram.java` then uses `AgnosticCombination` to place separate parts.
- `io/WKT.java` and the export classes provide starting points for data adapters.

There is a critical option distinction. The `-exact` flag forces exact tile
counts **instead of ensuring correct topology**, according to the CLI help.
Do not enable it and then claim both guarantees. First run topology-preserving
mode. Measure residual count error. Increase resolution or report a controlled
exception if the requested counts cannot be achieved.

The CLI also rounds weights and clamps each outline to at least one tile.
Supply precomputed positive integer budgets. Do not let this hidden minimum
silently decide the treatment of small islands.

The repository README mainly describes GUI use. Source code also contains a
command-line cartogram entry point and evaluation runners. Test that path
headlessly, without debug windows or PDF conversion. A complete build and
export recipe remains to be verified.

Inspected revision: `f1c18c0a938bd526e42d531e3728a85f3f0a0305`.
The repository declares GPL-3.0 and requires GeometryCore. Keep an initial
experiment as a separate offline tool. Review dependency and distribution
licenses before copying code into this BSD-style licensed repository. Running
a separate process does not by itself settle all license questions.

### Alternatives

| Approach | Value for this project | Main limitation |
| --- | --- | --- |
| 2026 mosaic implementation | Existing weighted mosaic code and disconnected-outline placement | Needs component data, adapters, license review, and world-scale tests |
| New implementation of the 2015 method | Direct control over a small square-grid generator | Graph initialization and valid tile transfers are substantial work |
| Continuous cartogram, then grid conversion | Useful comparison or initial layout | Grid conversion can lose contacts, islands, and exact tile counts |
| Capacity-constrained assignment or optimal transport on grid sites | Can meet count constraints | Does not by itself preserve connected shapes or contacts |
| One-tile-per-country grid map | Simple and compact | Does not encode population by area |
| Manual repair of OWID | Useful short-term baseline | Not a reproducible solution for new years and resolutions |

For the continuous comparison, `cartogram-cpp` accepts GeoJSON regions and CSV
target areas and uses a fast flow-based method [7]. Give island components
separate feature IDs and populations. Scaling a country MultiPolygon by one
national value would retain the same modeling problem. Its polygon output
still needs discrete count correction and topology checks. Do not treat it as
a direct replacement for `data/cartogram.csv`.

## 4. Proposed component model

Keep three identities separate:

```text
country_code     administrative owner; retain the existing integer interface
landmass_id      physical landmass; can contain several countries
component_id    connected country part, or an explicitly declared island group
```

For example, Borneo contains parts of Indonesia, Malaysia, and Brunei. Ireland
contains parts of two countries. Their land borders must remain contacts, even
though the countries also have disconnected territory elsewhere.

Use a separate string such as `360:java` for a component ID. Do not insert
synthetic decimal country codes into the existing integer column. Keep stable
IDs in a registry; polygon order is not a stable identifier.

### Geometry and population preparation

1. Select and record a boundary dataset, version, and territorial policy.
2. Repair invalid polygons. Separate connected country parts. Rejoin artificial
   cuts at the antimeridian before identifying islands.
3. Build physical landmasses and real shared-border relations. Use shared
   boundary segments, not point contact or H3 proximity, to define land borders.
4. Assign native-resolution population cells to components. Record cells near
   coasts, disputed borders, or missing polygons for review.
5. Sum populations only after component assignment. Preserve component identity
   during later H3 aggregation.

The current extractor in `scripts/extract_kontur_country.jl` unions country
polygons and selects H3-8 cell centres. That loses polygon identity. Extend the
preparation layer rather than trying to recover islands from its country totals.

Do not identify islands from connected sets of **positive-population** H3 cells.
An unpopulated area can split one landmass. A coarse H3 cell can also cover both
sides of a strait. Geometry identifies components; population supplies weights.
Natural Earth is the current boundary source, but its coverage of small islands
must be checked. A missing polygon is not evidence of zero population.

If one source H3 cell must be split between components, use temporary internal
IDs and conserve its original mass. When exporting, combine transported masses
by original H3 ID and target, then recompute both weights. Do not concatenate
several independently source-normalized rows as if each held the full source
population. A centre-based rule is simpler, but its coastal error must be reported.

Use one declared population basis. Either use Kontur sums directly, or rescale
them to selected national totals while retaining within-country shares. Record
the multiplier and year. Do not silently mix OWID 2026 totals with a different
Kontur year.

### Integer tile budgets

For component populations `P_i`, total population `P`, and tile budget `N`:

```text
ideal_i = N * P_i / P
n_i = floor(ideal_i)
```

Distribute the remaining tiles by largest fractional remainder. Use stable IDs
to break ties. This gives a fixed total count and, without minimum constraints,
less than one tile of rounding error per component.

If national counts must be fixed, allocate tiles to countries first. Then
allocate each country's count among its components. Report the extra error
from this two-stage allocation. For a complete replacement, compare it with
direct global component allocation.

Small islands require an explicit policy:

- Increase resolution when an important component receives too few tiles.
- Group nearby small islands only under a declared rule. Record that transport
  within this group can cross island boundaries.
- Use a labeled inset when geographic placement is impractical. Retain the
  population area scale, or label any different scale clearly.
- If a minimum of one tile is imposed, report the resulting area inflation.
- Never remove inhabited islands or their source mass silently.

A non-population locator symbol can show an island with no area tile, but it
does not solve transport for that island. Retain its mass in a declared group
or a population-bearing inset. Zero-population parts need no transport solve.

One tile can have only four side neighbours on a square grid. Thus some contact
graphs cannot fit small budgets, even before shape is considered. An enclave
also needs special treatment: a surrounding country has a hole, which conflicts
with the simple-region assumption. Test Lesotho and other enclaves explicitly.
Use documented splits into connected patches, or a method that supports holes;
do not assume the original theorem covers arbitrary world polygons.

## 5. Layout and transport pipeline

### Generate shapes and place landmasses

Use square tiles first. They match current loaders, subdivision, rendering, and
side-adjacency diagnostics. H3 sources do not require hexagonal target tiles.

Create population-weighted guiding shapes for country components. Preserve
real borders within each connected landmass. Generate independent layouts for
separate landmasses, then place them on one grid with translations.

For isolated single-region islands, a connected exact-size guiding shape can
be enough. Multi-country landmasses need the graph-based mosaic stage. Do not
solve every country independently and expect international borders to align.

Use proximity and relative direction for island placement. Compare the
published combination strategies. If needed, add penalties for reversed
west–east order, poor island-chain order, and excessive displacement. These
would be project extensions, not guarantees of the published method.

Keep two graphs:

- **Contact graph:** real land borders; these can become shared tile edges.
- **Placement graph:** nearby islands and mainland anchors; these guide position
  but must not become invented land borders.

Keep sea as empty space, not as population-bearing tiles. Apply an explicit
separation rule to disconnected landmasses. Remove all temporary graph nodes
before export and recheck the final contact graph.

### Run transport per component

For each represented component or declared group:

```text
select its target cells
select its positive source rows
call distribute(targets[x,y], sources[x,y,value,id]; backend)
restore country and component metadata outside the core
```

The solver still sees ordinary tables. No change to its public result schema
is required. Keep the global target coordinates for export. Check coordinate
alignment and degenerate one-cell cases in the preparation layer.

There is an unavoidable mass qualification. A separate solve gives each target
in component `i` actual capacity `P_i / n_i`. These values differ slightly
between components because tile counts are integers. This is preferable to
moving people across islands merely to force exact global equal mass.

The following three requirements cannot generally all hold at finite resolution:

1. Every tile represents exactly the same population.
2. Every component has an integer number of tiles.
3. No population crosses component boundaries.

Recommend preserving source population and component membership. Report the
rounding error in tile areas. Increase resolution when that error is too large.
Variable target masses could preserve component totals in a country-wide solve,
but would need a core API change and would not alone prevent mixing.

Subdivision is not a repair for wrong island proportions. Subdividing all old
tiles equally leaves `T_i / T` unchanged. Generate budgets and boundaries at the
intended layout resolution. Use subdivision later only for transport detail.

### Files and integration

Put the generator under a new example or offline preparation directory. Keep
geometry, Java tooling, H3, and file formats outside `src/`.

Proposed outputs:

| File | Content |
| --- | --- |
| `cartogram.csv` | Headerless integer `x,y,country_code`, for legacy readers |
| `cells.arrow` | Coordinates, cell ID, country, component, landmass, parent ID |
| `components.csv` | Population, ideal and actual counts, grouping and inset policy |
| `source-components.arrow` | Source membership and any split fractions |
| `contacts.csv` | Required, missing, and false land-border contacts |
| `manifest.json` | Input hashes, versions, population year, seed, settings, exceptions |

Use one cell owner globally. Preserve the step-2 square convention for the first
adapter, or declare and test a new convention. Do not use a compatibility CSV
without the component table when running the new transport workflow.

Join metadata back onto the unchanged solver output. Regenerate city placements
and downstream Arrow files. Old cell IDs, mapping weights, and caches are not
valid for a new layout. Keep OWID outputs available for comparison and rollback.

## 6. Validation and staged delivery

### Stage A: audit before replacement

Create an island audit from geometry, Kontur, and the existing artwork. Associate
artwork components with geographic components and retain uncertain matches.
Record missing islands and artwork that merges several islands. Calculate the
capacity lower bound from Section 1 only where that association is valid.

Rank cases by absolute excess population, relative area error, and affected
population share. Inspect Indonesia first. Include the UK, Japan, the
Philippines, Greece, New Zealand, and overseas territories. Report country-code
and geometry errors separately from layout errors.

### Stage B: small headless prototype

Build the pinned GridMapPipeline revision and its dependencies in a separate
environment. Convert component outlines and integer weights. Disable GUI debug
output. Add an adapter that extracts actual tile ownership, not SVG pixels.

Start with:

- Indonesia: large differences between island population shares.
- UK and Ireland: disconnected country parts and an international island border.
- Borneo: one island shared by several countries.
- South Africa and Lesotho: enclave support and duplicate-cell regression.
- Synthetic two-island examples: known population ratios, one-cell budgets,
  missing-island input, and an intentionally infeasible contact graph.

Compare topology-preserving mode with higher resolutions. Test `-exact` only as
a separately labeled trade-off. Validate outputs even if the process reports
success; the inspected Java entry point catches some exceptions internally.

### Stage C: transport and comparison

Compare three outputs with identical source data:

1. Current OWID layout and country-wide transport.
2. Generated layout and country-wide transport.
3. Generated layout and component-restricted transport.

This separates benefits from better capacities and benefits from restricted
transport. Then test several tile budgets around the present 55,000-row scale.
Do not compare a much finer generated map with a coarse OWID map without noting
that difference.

### Acceptance measures

| Property | Check |
| --- | --- |
| Cell ownership | No duplicate coordinates, overlaps, or target cells without an owner |
| Population accounting | Source totals conserved; no unexplained component or country loss |
| Area | Integer count error and population-rounding error reported separately |
| Island attribution | Cross-component transported mass is zero for restricted components |
| Solver export | Marginal error, retained mass, and sparse-output loss reported separately |
| Topology | Required and false contacts measured at component level |
| Shape | Symmetric difference after documented alignment; thin extensions and holes recorded |
| Position | Geographic order, displacement, island-chain order, and inset placement checked |
| Stability | Repeated seeds and population years compared for unnecessary movement |
| Cost | Layout time, transport time, peak memory, target count, and output size recorded |

For attribution, sum `source.value * weight` on rows whose source and target
component labels differ. A source-normalized weight alone is not a population
amount. For shape, do not allow arbitrary rotation to hide a reversed island.

Require zero ownership conflicts and no undeclared cross-component transfer.
Require exact requested counts before calling a layout count-correct. Set area
error tolerances explicitly for small regions; a one-tile error can be large.
A topology-preserving result with residual count error remains an experiment,
not an automatically accepted production map.

Finally, inspect maps with a linked geographic reference. Ask whether a reader
can find Java, recognize Britain, compare populations, and identify land
neighbours. The survey supports evaluating these tasks separately. Numerical
success does not establish readability.

## Decision

Proceed with the island audit and a small GridMapPipeline prototype. Keep the
existing world map until the population, topology, and readability checks pass.
The main risks are small-island data, integer area budgets, enclave topology,
and readable global placement.

## Sources

[1] R. G. Cano et al. (2015), **Mosaic Drawings and Cartograms**.
Supplied file: `mosaic cartograms 2015.pdf`.
[DOI](https://doi.org/10.1111/cgf.12648).
Sections 3–4 describe the algorithm; Sections 5–6 report tests and limits.

[2] S. Nusrat and S. Kobourov (2016), **The State of the Art in Cartograms**.
Supplied file: `state of the art in cartograms 2016.pdf`.
[DOI](https://doi.org/10.1111/cgf.12932).
Sections 5.5, 6–7, and 11 are the main references used here.

[3] W. Meulemans (2026), **A Simple Grid-Maps Pipeline: Restructured,
Accelerated and Upgraded**.
[Paper and supplements](https://diglib.eg.org/items/32dd909a-13d4-4496-a5ce-162b0b429a8c),
[DOI](https://doi.org/10.1111/cgf.70467).
The main paper was inspected directly, especially Sections 4 and 6–7.

[4] [GridMapPipeline source](https://github.com/tue-alga/GridMapPipeline),
[pinned cartogram entry point](https://github.com/tue-alga/GridMapPipeline/blob/f1c18c0a938bd526e42d531e3728a85f3f0a0305/GridmapPipeline/src/main/Cartogram.java),
[pinned weight model](https://github.com/tue-alga/GridMapPipeline/blob/f1c18c0a938bd526e42d531e3728a85f3f0a0305/GridmapPipeline/src/common/Partition.java),
and [archived evaluation release](https://doi.org/10.5281/zenodo.19497047).
The README and selected source files were inspected; the archive was not run.

[5] [OWID cartogram documentation](https://github.com/owid/cartograms/blob/7fca238522ee065aa0406530ccc20e8c5481c39c/documentation/README.md).
Also see local `data/readme.md` and `data/citation.md`.

[6] [Issue #17][issue], its reference comment, and the linked Mastodon
[problem description](https://masto.ai/@bovine3dom/117421312540991201) and
[examples](https://masto.ai/@bovine3dom/117421312552225770).
The issue and thread text were retrieved directly through their APIs.

[7] [cartogram-cpp](https://github.com/mgastner/cartogram-cpp).
Its README documents the flow-based method, GeoJSON/CSV interface, and licensing.
It was inspected as a comparison candidate, not tested in this work.

[issue]: https://github.com/bovine3dom/population-cartogram-projection/issues/17
