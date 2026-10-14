# Moment-constrained target subdivision

Run the native-source fit first. It uses KernelAbstractions and oneAPI.
This separate CPU projection then divides each target into `factor^2` cells.
It uses the existing HiGHS dependency in `examples/continuity/mobile`.
It is not a new global border-optimization pass.

## Constraints and limits

Each old source-to-target flow is fixed in total. The fine target cells have
equal mass within their old target. The solver constrains four target means:
raw geographic XYZ and source population density. A local linear guide gives
the desired changes. The solver finds the largest feasible guide amplitude
from zero to one for each old target. All offsets sum to zero, so the old
coarse means remain fixed.

The LP has no entropy term. A basic solution is sparse, but there is no fixed
bound on the number of target cells per source. More target cells can require
more contributions. The LP does not constrain other query fields. Do not claim
that all fine-scale queries equal an independent population extraction.

Each source uses conditional variables. This prevents small source populations
from disappearing at an absolute LP tolerance. The checks then use the actual
masses and moments. Source relative error must be at most `1e-10`. Fine target
relative error, against the old target's divided mass, must be at most `1e-6`.
The native exporter also checks the final country masses and physical weights.

A cell solve has a time limit. If its solve status or numerical check fails,
the fallback distributes each old contribution equally among its fine cells.
This preserves coarse mass and means, but can be broad. `cells.csv` records
its reason and zero amplitude. Do not hide these fallbacks in quality reports.
A city remains within its original coarse target and on the same native source.

There is no fold penalty in this LP. The moment constraints reduce the geometry
changes seen with simple geographic OT, but they do not guarantee valid fine
grid orientation. Compare orientation, border separation, density, and support
before publication. Keep the old H3-5 map and the native factor-1 map separate.

## Run

```sh
H3_SUBDIVISION_DEADLINE=2026-10-15T04:20:00 \
  OPENBLAS_NUM_THREADS=1 julia --threads=2 \
  --project=examples/continuity/mobile \
  examples/continuity/subdivide_native.jl COARSE_FIT FACTOR NEW_OUTPUT
```

The deadline is UTC. Optional country codes after `NEW_OUTPUT` limit a pilot.
The runner checks the coarse input hash on resume. It saves each accepted
country before it starts the next one. The completion marker covers only the
requested country list. The independent native exporter must check planet
coverage before publication.

Run `test/target_subdivision.jl` with the mobile example project.
The HiGHS interface reference is <https://github.com/jump-dev/HiGHS.jl>.
