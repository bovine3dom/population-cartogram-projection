# Coarse 90% Kontur: defect repair trials

The current best and H3-MON data are unchanged. These are research trials.

## Fragment choice

The initial Swedish partition has pieces of 29, 21, 17, and two tiles. The
largest piece touches Germany and Poland. Smaller pieces touch Finland and
Norway. The old repair keeps the largest piece and removes the useful northern
pieces.

The optional source-border rule in `repair_partition.py` first keeps the piece
with more true border neighbours. `repair_coarse90_mainland.py` repeats the
remaining stages from the saved partition.

In `coarse90-preferred-fragments-v1`, Sweden touches Finland and Norway instead
of Germany and Poland. Malaysia rejoins Thailand. However, Sweden gains false
contacts with Estonia and the Russian enclave. Finland–Norway and
Colombia–Panama contacts are lost. The result has 72 missing and 48 false
contacts. Checked Europe and Indonesia visually. Sweden is now a block in the
right region, but its shape still needs work. Do not promote this trial.

## Other trials

- Rigid docking without dependent islands can rejoin Malaysia. The old pass
  tried to move many nearby islands with it. These can block a move.
- General border docking moves Finland and Norway too far east. Rejected after
  visual review. Sorting unsupported bodies first did not help; removed that
  unused option.
- The strict docking option forbids new false pairs. The old rule only compared
  their number, so it could exchange one false border for another.
- Source-template replacement can improve the Malaysian connection. It cannot
  place Sweden under the current neighbour-axis constraints.
- Short coast swaps keep counts, footprint, and true borders. They improve some
  small components, but do not fix Lithuania or Paraguay.
- A full fit with a 1,000-unit inland-coast penalty leaves Paraguay on the coast.
  It increases contact errors to 78 missing and 50 false. Do not promote it.
  This exploratory run used live imported code. Later trials use saved code.

## Local coast constraints

`fit_local_coasts.py` makes bounded mixed-integer tests. It keeps the land
footprint and budgets fixed, retains true borders, forbids new false borders,
and requires connected output. It adds connectivity constraints after each
solve. A fixed root cell and a small search window can exclude valid repairs.
Initial tests repair some small coast defects, but not Lithuania or Paraguay.

The solver API was checked against the
[SciPy documentation](https://docs.scipy.org/doc/scipy/reference/generated/scipy.optimize.milp.html).

## Short separation

`separate_false_contacts.py` tests short rigid translations. It keeps all true
contacts, lake cells, and their shore labels. It can remove the new Swedish
false contacts with a one-tile move. Coast access and empty space still need
review. It does not use country-specific rules.

## Validation

All 308 tests pass. Saved code is in
`output/auto-cartogram/coarse90-repair-code-1/` through `coarse90-repair-code-10/`.
No result is approved for production.

## Published mainland trial

[Review the world and regions](results/geography/coarse90-repairs/mainland-v1/index.html).
The land layout is `output/auto-cartogram/coarse90-lithuania-lakes-v1/`.

This trial has 69 missing and 34 false contacts, compared with 73 and 48 in the
current best. It gains five true contacts, loses Finland–Norway, removes 14
false contacts, and adds no false contact. Thus, the lower total is not enough
for production approval.

- Malaysia touches Thailand.
- Sweden no longer touches Germany or Poland. It touches Norway and Finland.
- Lithuania has two exterior-water edges, compared with zero before.
- Manhattan remains beside the western end of Long Island.
- Colombia still touches Panama. A preliminary trial broke this connection;
  the two-stage docking pass restores it.
- Paraguay still has 16 exterior-water edges. This remains a defect.

Checked the world, Europe, Africa, Indonesia, Japan/Korea, South America, and
New York images. The Nordic outlines remain weak. The Nordic group also lacks
its mainland connections. The new Finland–Norway loss is a regression. A local
fixed-footprint test could not restore that border within its constraints.

The final publication check verifies 55,000 exact tiles, 481 connected
components, 45 lakes, and 220 empty lake cells. It checks every lake's required
and allowed shores. The current best and production data are unchanged.

### Lake regression found and corrected

A short Finland translation opened Lake Saimaa to the sea. Checking only the
set of country labels beside a lake did not detect the missing shore cells.
The stricter separation pass fixes all cells next to a lake. The local integer
fit can also fix these cells.

For the published trial, `transport_moved_lakes.py` moves empty lake cells by
the recorded common translation of their shore countries. Lake Saimaa moves
one tile east and two north. No land tile changes. The lake remains enclosed
by Finland. All original lake shore checks pass. A mixed shore translation or
an occupied destination is rejected if the final shore constraints fail.

### Local coast solver

The first integer model added connectivity constraints after each solve. It
used too much time on disconnected solutions. The revised model sends a
continuous flow from a fixed root through each country's assigned cells.
Unchanged exterior pieces are compressed into fixed nodes. This enforces
connectivity in the first solve. Independent checks still reject splits,
count errors, false borders, and missing required contacts.

A three-tile reach limit finds an optimal local repair for Lithuania. Wider
Paraguay tests reach their time limits without a valid solution. Tests with a
shorter reach are infeasible. These results apply only to the tested windows,
fixed roots, and retained-contact constraints.

### Why Paraguay remains on the coast

In the 1,000-unit coast-penalty partition, Paraguay has zero exterior-water
edges. Repair raises this to 15; border fitting leaves 14. The partition uses
small Chilean and Brazilian pieces as coastal cover. Some Chilean pieces touch
Paraguay, which is itself a false border. Repair removes these pieces. It also
exchanges five Paraguayan cells with neighbouring fragments.

Repeating source-border fragment selection on this partition does not solve
the problem. The resulting map has 75 missing and 50 false contacts. Rejected.
The next useful test must preserve a valid coastal cover during region
assignment and fragment repair, rather than only penalize inland coast cells.

### Reproduction sequence

Use the geometry environment's Python executable. Each output must be new.

1. Run `repair_coarse90_mainland.py` from the saved current-best partition.
2. Run `separate_false_contacts.py`. For the published exploratory candidate,
   the saved pre-strict-shore separation is `coarse90-separated-v3`.
3. Run `fit_local_coasts.py` with a five-tile margin, a three-tile reach, and
   Lithuania as the target. The saved successful run is `coarse90-local-coasts-v6`.
4. Run `transport_moved_lakes.py` with the recorded separation and its reference
   layout. This gives `coarse90-lithuania-lakes-v1` without changing land cells.
5. Run `review_coarse90_repairs.py`. It rejects invalid lake shores before
   publication.

The saved snapshots retain the exact code for these trials. Current defaults
use stricter shore guards. They need not reproduce the earlier trial's moves.

## Further local trials

Review: `results/geography/coarse90-repairs/followup-v1/index.html`.
Both trials start from `coarse90-lithuania-lakes-v1`. Neither replaces it.

- `coarse90-coastal-buffer-v1`: run `repair_coast_access.py` with
  `--buffer 3 --rounds 30`. The buffer adds a cost for inland cells near exterior
  water. A sea-edge penalty exceeds all buffer costs for a component. Thus a
  better buffer score cannot justify more sea edges. Freeze all lake-shore cells.
  The 158 swaps give 67 missing and 34 false contacts. Paraguay still has 16
  exterior-water edges. Visual review shows that its narrow shape remains.
- `coarse90-contact-translations-v1`: run `separate_false_contacts.py` with
  `--radius 12 --restore-contacts`. Five rigid moves give 65 missing and 32 false
  contacts. Reject this trial: Ethiopia gains seven exterior-water edges and
  the inland KAB component gains four. Border totals alone are not sufficient.
  The optional translation mode remains an experiment, not a safe final repair.
- `coarse90-nordic-contact-v2`: require Finland–Norway with Sweden as the local
  target, margin 10, reach 8, and 90 seconds. The solver reports infeasibility.
  This result applies only to that constrained window. A separate rigid search
  within 32 cells on each axis needs a minimum Norway move of 14 cells east and
  seven north to touch both Sweden and Finland. This moves Norway too far east.

Both completed layouts pass independent count, connectivity, and lake-shore
checks. The buffer trial causes no extra inland sea edges and no complete loss
of coastal access. Visually checked South America, Africa, and the reference
Nordic layout. The current best and H3-MON exports are unchanged.

Snapshots `coarse90-repair-code-13` and `coarse90-repair-code-14` hold the trial
code. A later translation optimization avoids repeated whole-world dictionary
copies. The defaults still disable the new buffer and contact-restoration modes.
All 311 tests pass.

Next, allow the Nordic group's outside boundary to change in a joint fit.
Retain its counts, true borders, and lake shores. For Paraguay, enforce connected
coastal cover during fragment repair. Final fixed-footprint swaps have not
repaired either main defect.

## Joint Nordic fit with a movable coastline

Review: `results/geography/coarse90-repairs/nordic-v1/index.html`.
The final trial is `coarse90-nordic-expansion-v6`. It is not a new current best.

The local solver can now assign empty cells near the current land. It keeps
exact component counts, connected components, existing true borders, and lake
shores. It adds no false border pairs. A new exterior-water flood fill checks
all components, not only those inside the fit window. The fit rejects extra
inland coast or loss of coastal access. These checks use sampled source coast
labels. They are not a proof of correct geography.

The experiments use the main Sweden, Norway, and Finland components as explicit
movable labels. Other components stay fixed. They require Finland–Norway.

| Run | Settings | Result |
| --- | --- | --- |
| Nordic v1 | Margin 4, expansion 3, reach 8; all local labels; 90 seconds | No feasible incumbent before the time limit |
| Nordic v2 | Margin 12, expansion 2, reach 10; Nordic group; 120 seconds | Valid border, but a thin northern strip |
| Nordic v3 | Source templates; expansion 4; otherwise v2 settings | Valid border and changed shapes, but long extensions |
| Nordic v4 | Source templates; expansion 3; perimeter cost 0.4; 180 seconds | No feasible incumbent before the time limit |
| Nordic v5 | As v4, plus squared-distance cost 0.3 | No feasible incumbent before the time limit |
| Nordic v6 | Start from v3; expansion 1, reach 2; both shape costs; 120 seconds | Optimal within this local model; useful shape refinement |

All runs except v6 start from `coarse90-lithuania-lakes-v1`. Templates come from
`world-55000-shape-islands`. Each template is translated to its component's
current centroid. The fit does not rotate it. The squared-distance term uses
Manhattan distance to the nearest template cell. The perimeter term counts
exposed tile sides for each component. Shared borders count for both components.

The final trial restores Finland–Norway. It has 68 missing and 34 false borders.
It loses no true border relative to the original current best. Only the three
Nordic components change relative to the mainland repair trial. All 55,000
counts remain exact. All 481 components remain connected. The 45 lakes retain
all 220 empty cells and pass shore checks. No coastal-access regression occurs.

Visual checks include the world, Europe, and enlarged Nordic comparisons.
Sweden is no longer rectangular. Compared with v3, Finland's perimeter falls
from 70 to 52 tile edges. Sweden's falls from 60 to 42. Norway's rises from 34
to 36. Norway still has a narrow section. Finland still has an awkward extension
around Lake Saimaa. Do not promote this result on border counts alone.

Two Paraguay fits also permit coastline changes. Neither finds a feasible
incumbent in its time limit. The first uses margin 4, expansion 2, reach 5, and
120 seconds. The second limits movement to Paraguay, Brazil, and Argentina. It
uses margin 6, expansion 1, reach 6, and 180 seconds. This does not prove that
Paraguay cannot be repaired. Its false coast remains at 16 edges.

Frozen snapshots `coarse90-repair-code-15` through `coarse90-repair-code-21`
record the trial code. The review includes run records, land and lake downloads,
and comparison checks. All 317 tests pass. The current best and H3-MON exports
are unchanged. The next shape experiment should test the group placement and
lake placement together. Paraguay still needs an earlier coastal-cover repair.

## Interior lake exchange and sea connectivity

Review: `results/geography/coarse90-repairs/nordic-lakes-v1/index.html`.
The final trial is `coarse90-nordic-sea-v1`. It starts from the previous Nordic
trial, not from the current best. It is not approved for production.

`move_interior_lake.py` tests a rigid move inside a single shore component.
It exchanges water and land. The old lake cells become land, and the same
number of interior land cells become water. The lake shape, country tile
budget, country borders, and other lake shores stay fixed. The tool rejects
shared or exposed shores, overlaps, and disconnected countries. It does not
estimate a new lake position from source geography.

Four nonzero interior moves fit within five cells of Saimaa in the previous
Nordic result. The shortest is three cells west and two north. It creates
`coarse90-saimaa-seed-v1`. The next experiment moves three west and three north,
creating `coarse90-saimaa-seed-v2`. Both are refitted with the same Nordic group,
source templates, margin 12, expansion 1, reach 2, perimeter cost 0.4, and
squared-distance cost 0.3. Both local fits reach optimality within 90 seconds.
Both remove Finland's long lake extension. The shorter move is selected.

A further fit starts from `coarse90-saimaa-fit-v1`. It uses the same shape
settings, a 120-second limit, and `--sea-connected`. Continuous water flow
requires non-lake empty cells in the window to reach the exterior sea. Recorded
lake cells remain empty and are excluded from this flow. A final flood fill
rejects newly enclosed water inside or outside the window. This trial reaches
optimality within its local model.

A control fit, `coarse90-nordic-sea-fixed-lake-v1`, starts directly from the
previous Nordic result with the same sea-flow and shape settings. It leaves
Saimaa fixed. It removes the local unnamed holes, but retains Finland's lake
extension and a long water channel beside Norway. This control also reaches
local optimality. Fewer enclosed holes alone do not prove better geography.

Compared with `coarse90-nordic-expansion-v6`, only the three Nordic components
and Saimaa change. The lake moves from (508, 474) to (505, 476). All 55,000 land
tiles retain exact component counts. All 481 components remain connected.
All 45 lakes retain their IDs and 220 empty cells. Shore checks pass. There are
no lost true borders, new false borders, or coast-access regressions.

Three unnamed enclosed-water cells disappear: (494, 476), (495, 476), and
(497, 467). No new enclosed-water cells appear globally. Global unnamed water
falls from 376 to 373 cells. These counts are not counts of defective lakes.
Unnamed water can represent real features. Check source water before applying
this rule outside a reviewed local area.

Visually checked both lake trials, the final Nordic detail, and Europe.
Finland's extension is removed. Norway's narrow northern section remains.
The Nordic group still lacks its Russian borders. Paraguay is unchanged.
Snapshots `coarse90-repair-code-22` and `coarse90-repair-code-23` retain the trial
code. All 325 tests pass. The current best and H3-MON exports are unchanged.

## Paraguay: a valid inland layout

Review: `results/geography/coarse90-repairs/paraguay-v1/index.html`.
Final layout: `coarse90-paraguay-water-v1`.
Reference for this repair: `coarse90-nordic-sea-v1`.

Paraguay's exterior-water edges fall from 16 to zero. Its three source borders
remain. Argentina–Bolivia is restored. No true border is lost and no false pair
is added. The world now has 67 missing and 34 false borders. The Nordic layout,
island cells, and all other components are unchanged. Bolivia's existing false
coast stays at 25 edges. The repair does not move the defect there.

### Why the earlier exchanges stopped

A short eastward Paraguay move enters Brazil. But giving the vacated western
strip to Brazil creates disconnected coastal cover. Removing that fragment
exposes Paraguay again. Pairwise swaps cannot make the required joint exchange.

`inset_landlocked.py` tests short translations into one coastal donor. A second
coastal source neighbour takes the vacated cells. It then gives an equal number
of its original boundary cells to the donor. The trial must retain connectivity,
exact budgets, lake shores, and all existing true borders. It adds no false
border pairs. An old target boundary cell can be retained to preserve a true
contact. No connector tiles are added. There is no country-specific branch.

For Paraguay, the accepted seed moves three cells east. One retained cell keeps
Bolivia. Argentina takes 29 vacated cells and gives 29 original boundary cells
to Brazil. The exchange changes 87 labels without changing the land footprint.
It also restores Argentina–Bolivia. The initial Argentine extension is too thin.

### Shape refinement and water checks

Use `--refine` to fit an explicit target whose coast access is already valid.
Otherwise the coast-repair filter skips it. The recorded v1 and v2 refinement
commands were skipped runs, not fit results.

- `coarse90-paraguay-refine-v3`: margin 8, reach 2, expansion 1, perimeter weight
  1, distance weight 0.1, sea connectivity, and 120 seconds. Accepted.
- v4: perimeter weight 2. Rejected because another inland coast grew. The solver
  now keeps occupied neighbours of fixed inland components occupied.
- v5: start from v3; margin 14, perimeter weight 2, and 180 seconds. Accepted.
- v6: start from v5; margin 10, perimeter weight 1, thin-cell weight 2, and
  180 seconds. Accepted. A thin cell belongs to no full 2-by-2 block of its
  component. This soft cost reduces Argentina's thin-cell count from 26 in the
  seed to 13, equal to the reference count.
- v7: start from v3 and pin all existing enclosed water and shores. No feasible
  incumbent before the time limit. This does not prove infeasibility.

The larger fits filled one unrecorded enclosed-water cell. Its source status
was uncertain. `restore_reference_water.py` restores it through a single-country
vacancy exchange. Only the endpoints change: (302, 265) becomes water again,
and (309, 254) becomes Argentine land. The route does not create a connector.
The tool retains budgets, true borders, water shores, and coastal access. It
rejects new false pairs and new same-country axis-order errors. All reference
enclosed water is now retained, not only the named lakes.

The final candidate changes only Paraguay, Argentina, and Brazil. Paraguay has
48 tiles, Argentina 315, and Brazil 1,465. All 55,000 tile budgets are exact and
all 481 components are connected. The 45 lakes retain their 220 empty cells.
No enclosed water is added or removed. There are no new country or island
centre-order errors relative to the reference. An intermediate Argentine
centre-order regression is absent in the final result.

Visually checked the world, South America, and enlarged stage comparisons.
Argentina's perimeter rises from 158 to 192 despite the lower thin-cell count.
Its northern extension and the direction of coastal cover still need geographic
review. The last smoothing fits return feasible solutions at their time limits;
they do not prove optimality. Do not promote this result on border counts alone.
Snapshots `coarse90-repair-code-24` through `coarse90-repair-code-29` retain the
trial code. All 337 tests pass. The current best and H3-MON exports are unchanged.

## Pacific coast correction after user review

Rejected `coarse90-paraguay-water-v1`. It makes Paraguay inland by extending
Argentina's false Pacific coast. A country-level sea-access check cannot
detect this error. The public page now states this rejection.

Added `audit_coast_arcs.py`. It compares the land neighbours at each end of
a sea-coast section. Argentina's main source coast ends at Chile and Uruguay.
The rejected trial adds a coast between Bolivia and Chile. Source sampling
at 8,192 and 32,768 points gives the same source endpoints. Enclosed water is
not sea in the tile check. Source sampling remains approximate.

The initial partition has one Chile tile beside Peru and Bolivia. Fragment
repair removes it. Most Chile tiles are already too far south in the
partition. Keeping that fragment alone would not correct the mass placement.

Added `shield_coast.py`. It extends the source coastal neighbour along the
wrong coast, then removes the same number of its original coastal tiles.
No other component moves. It retains all previous true contacts, enclosed
water, and shore labels. It rejects new false contact pairs.

The first trial moves 72 Chile tiles. Routing that first minimizes extra
water cells reduces this to 54 in `coarse90-pacific-shield-v2`.
Chile retains 133 tiles. It touches Peru and Bolivia again. Bolivia and
Paraguay have zero sea edges. Argentina's unsupported Bolivia–Chile sea
section is gone. Other coast-section mismatches remain near enclosed water
and the southern SPI component.

All 55,000 component budgets are exact. All 481 components are connected.
The 45 lakes retain 220 empty cells. World border totals are 65 missing and
34 false. Island-axis errors stay at 392. Country-axis errors rise from
218 to 219: Chile versus South Africa is a new error.

Checked the enlarged South America image. The coastal order is better.
Chile is still thin. Paraguay is too far west. Moving 54 of 133 Chile tiles
can also distort internal population placement. Do not promote this trial.
The next fit must handle Chile, Argentina, Bolivia, and Paraguay together,
with source coast order as a constraint, not only country sea access.

Published `results/geography/coarse90-repairs/pacific-v1/index.html`.
Snapshots 30 and 31 retain the trial code. All 344 tests pass. The current
best layout hash and H3-MON exports are unchanged.
