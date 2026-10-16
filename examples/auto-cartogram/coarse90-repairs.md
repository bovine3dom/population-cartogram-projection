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

All 301 tests pass. Saved code is in
`output/auto-cartogram/coarse90-repair-code-1/` through `coarse90-repair-code-3/`.
No result is approved for production.
