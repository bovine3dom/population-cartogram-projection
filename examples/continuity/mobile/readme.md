# Small planet exports

These tools reduce an existing H3-5 transport for browser use. They do not
change or refit the cartogram. Keep the full transport as a reference.

## Method

Simple row culling can move geographic means by many kilometres. The moment
method removes rows and adjusts the remaining positive weights. It preserves:

- Each source mass and its mean target position.
- Each target population and its mean geographic XYZ position.
- Each target mean population density.
- Source and target coverage, and the original city anchors.

A contribution floor can protect important rows. For each target, select the
largest original population contributions until their sum reaches a fraction
`q`. Keep those rows at or above their original weights. The original plan
remains feasible. With exact target masses, this bounds conditional total
variation by `1-q`. Complete data in a bounded range then has an average error
of at most `(1-q)` times that range. This bound does not apply unchanged after
missing-data filtering and renormalization.

The solver works on blocks. A failed block keeps its input weights. A stage
checkpoint contains a complete country transport. `working.jls` also contains
a complete transport, but only some blocks have been reduced. Copy a working
checkpoint to an immutable path before using it in a manifest.

Large blocks use a separate process with a wall-clock limit. Failed worker
inputs remain in the output directory. Stop the whole country process group
if an external country deadline expires. This also stops its worker.

## Run

Use the separate Julia environment:

```sh
julia --project=examples/continuity/mobile -e 'using Pkg; Pkg.instantiate()'
```

Build country caches from the original input and the full exported transport.
Use `MobileExport.load_index(input, reference, cache)` and
`MobileExport.country_data(data, code)` in `../mobile_export.jl`. Serialize
each country result. The index cache checks the reference path, size, time,
source IDs, and target cells before reuse. Do not use untrusted Julia
serialization files.

For a protected country reduction:

```julia
include("examples/continuity/mobile/reduce.jl")
reduce_country("country.jls", "new-country-output";
    target_retained=0.7, limit=60.,
    stages=[(128,64),(256,128),(512,256),(1024,512),(2048,1024),(4096,2048)])
```

Run Julia with `--threads=1` and `OPENBLAS_NUM_THREADS=1` when countries run
in parallel. Output directories record code hashes and settings. A changed
input or code requires a new output directory. Use `seed="checkpoint.jls"`
to start a new run from a checked complete transport.

For a further reduction, try `fixed_floors=true` with a checked seed. It holds
the protected contribution fixed and reduces only the remaining mass. It can
help when a block with lower bounds fails. It does not weaken the mass,
geometry, city, or total-variation checks. It can also return the input
unchanged; it does not guarantee the smallest support. `block_shift=(1024,512)`
rotates source and target order before block assignment. This can combine
rows across old block cuts without larger matrices. The default `(0,0)`
keeps the original order. Record the shift with each checkpoint.

Create a CSV manifest with `code,cache,result`. Use one row per country.
`result` is a saved stage path. An empty result keeps the full reference
country. The packer checks each country and then checks global coverage.

```sh
julia --project=examples/continuity/mobile examples/continuity/mobile/pack.jl \
  manifest.csv input.arrow full-density.arrow new-output
julia --project=examples/continuity/mobile examples/continuity/mobile/audit.jl \
  input.arrow full-transport.arrow new-transport.arrow new-density.arrow \
  audit.toml 0.7
```

The audit reads the actual Arrow files, not only the solver checkpoints. It
checks masses, means, density, labels, country ownership, and total variation.
It also tests query fields on the actual binary rows at physical target
positions. Its TOML report gives hashes for the inputs and the query CSV.
It writes its report only after all checks pass. Use the floor of the weakest
country in a mixed manifest. Never report a stronger guarantee.

## File and browser checks

The writer uses Int16 positions, UInt16 country codes, Float32 weights,
Float64 population, and UInt32 H3 halves. It uses lossless Arrow dictionaries
for population, lower H3 words, and labels. The density writer also uses a
lossless dictionary for lower H3 words. Density values keep their precision.
It drops an unlabelled roundoff
row only when both its source and target fractions are below `1e-20`.
It preserves country ownership at shared target positions. The packer places
the first row of each target first, then sorts other rows by source H3 and
position. This reduces gzip bytes without changing weights or the browser's
first-source navigation anchors.

Use a dictionary-capable Arrow reader. H3-MON commit `6563a17` uses Apache
Arrow directly. Its earlier loaders.gl reader rejects dictionary columns.
HTTP gzip reduces transfer bytes without changing decoded Arrow types.
H3-MON commit `00c9a85` adds streaming gzip for Arrow responses.

Run `browser.mjs` with the H3-MON path, transport path, density path, and a
new result directory. Set `CHROMIUM_PATH` if necessary. This headless check
uses the real application build with an isolated local HTTP server. It does
not start the normal H3-MON service. It records file transfer sizes, cell and
label counts, browser errors, a screenshot, and memory measurements.

Use `publish.py CANDIDATE AUDIT_TOML FULL_REFERENCE NEW_DESTINATION` to stage
an audited export. It checks file hashes and refuses an existing directory.
It also refuses more than 100 MB for the two Arrow files. Use Python 3.11 or
later. Name the destination after its final public directory, because the
browser metadata includes that name. Keep a full reference outside the web
root before replacing an experimental dataset. Do not change production data.

Set `DATA_PATH` and `METADATA_PATH` for `browser.mjs` to test the published
relative URL and its actual JSON metadata before moving the directory. Set
`VIEWPORT_STRESS=1` to test a world view, the date line, and return navigation.
The staged metadata enables visible-region geometry in H3-MON `fe5b200` or
later. This limits rendered geographic polygons, not source data or queries.
The option is off by default for other datasets. A world view can still use
substantial memory.

Small files do not imply small browser memory. Report raw bytes, compressed
transfer bytes, JavaScript heap, and backing buffers separately. Browser
measurements on a throttled desktop are not measurements on a phone.

See [the results](../../../benchmark/mobile-export.md) for the published
profile. See [the work log](../../../benchmark/mobile-export-work-log.md) for
measurements, failed trials, and commits.
