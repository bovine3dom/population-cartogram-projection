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
