# Population Cartogram Projection TODO

## Current Contract

- [x] Accept one cartogram as `x, y`.
- [x] Accept one country's positive source data as `x, y, value, id`.
- [x] Return `x, y, id, weight, weight_mean`.
- [x] Keep automatic eta selection inside one warm Sinkhorn continuation.
- [x] Accept a caller-provided KernelAbstractions backend object.
- [x] Keep vendor, country, H3, CSV, persistence, projection, and rendering code
      outside the package core.
- [x] Preserve example-owned UK H3 and France IRIS integration checks.
- [x] Add a factor-1, country-local Europe example with legacy hilo Arrow output.

## Follow-Up

- [ ] Benchmark the reduced implementation against the previous UK and France
      outputs and record keyed numerical tolerances.
- [ ] Decide whether sparse source weights should remain loss-reporting or gain
      an explicit opt-in renormalization mode.
- [ ] Investigate matrix-free or blockwise costs before adding larger workflows;
      dense source-by-cell storage remains the principal scaling limit.
- [ ] Add CI jobs for accelerator backends that have available hardware.
