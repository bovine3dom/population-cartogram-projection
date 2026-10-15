# Browser export storage and checks

Use sharp fitted mappings directly. Optional row reduction and per-batch
replacement-dictionary packing have been removed. Ordinary dictionary encoding,
exact numeric storage, source ordering, and binary checks remain.

## H3-5 storage conversion

```sh
julia --project=examples/continuity/mobile examples/continuity/mobile/pack_mapping.jl \
  original-input.arrow fitted-mapping.arrow density.arrow new-output
```

This command does not run a moment-reduction solver or select important rows.
It uses the supplied fitted mapping. The writer retains city and navigation
anchors and shared-cell country ownership. It writes ordinary Arrow IPC files
with Float32 weights and Float64 population. It checks source and target masses,
means, labels, ownership, and density after serialization.

The writer can remove numerical roundoff tails only when both source and
target fractions are below `1e-20`. It can split a row to preserve country
ownership at a shared target. The report records both operations. These are
not the removed importance-based reduction or moment-packing passes.

## H3-6 export

See [native publication](../native_publication.md). Export the saved fitted
country parts directly. Do not use old moment-packed checkpoints. Ordinary
dictionaries do not change values. Population uses a narrower type only when
all values are exactly preserved. The server keeps its existing zstd policy.

## Checks

`audit.jl` and `quality.jl` check binary mappings and query values. They do not
modify the mapping. `browser.mjs` runs an isolated headless H3-MON check and
records input hashes, coverage, labels, and browser memory. It does not start
the user's H3-MON service or enable a viewport geometry option.

Run `test/mobile_export.jl`, `test/mobile_audit.jl`, and `test/pack_mapping.jl`
with the mobile example project. Older reduction measurements remain in the
benchmark work logs as historical results, not current export instructions.
