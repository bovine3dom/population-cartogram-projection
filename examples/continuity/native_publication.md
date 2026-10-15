# Native H3-6 publication

Use the saved fitted mapping. Do not apply optional row reduction or per-batch
replacement dictionaries. Ordinary lossless dictionaries remain supported.
The native source fit uses KernelAbstractions and oneAPI. Target subdivision
uses CPU linear programming; it is a fitting constraint, not export packing.

1. Finish all requested countries. Retain the input manifest and checkpoints.
2. Run `native_export.jl FIT NATIVE GUIDES NEW_EXPORT FACTOR` with the mobile
   example project. This checks every binary column, masses, and coverage.
3. Run `native_quality.jl FIT GUIDES FACTOR BORDERS NEW_QUALITY` with the uk-h3
   example project. Its fitted-part hash must match the binary audit.
4. Run a headless browser check. Record coverage, labels, errors, and memory.
5. Run `publish_native.py EXPORT QUALITY NEW_DESTINATION`.

The publisher checks file headers, footers, hashes, sizes, and fit provenance.
It rejects old moment-packed inputs and Arrow streams. It stages ordinary
Arrow IPC files, adds `population_density_hilo.json`, and renames the directory.
It refuses to overwrite an existing destination. It does not start H3-MON,
change application defaults or compression, or add a viewport geometry option.

Arrow.Table and Apache Arrow JavaScript can read the ordinary IPC files.
No replacement-dictionary reader workaround is needed. Existing saved fits can
retain their original numerical sparsification policy; re-encoding cannot
restore discarded fitted contributions. New native fits export every positive
contribution and cannot resume an old row-selected export root.

The native planet requires substantial browser memory. Removing export packing
increases file sizes and does not remove the geographic-layer memory cost.
Keep H3-5 available. Preserve old experimental publications outside the served
data tree when migrating existing URLs to checked full exports.
