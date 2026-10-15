# Native H3-6 publication

Use a new directory for each factor and packing setting. Do not replace H3-5.
The native source fit uses KernelAbstractions and oneAPI. Target subdivision
and bounded moment packing use CPU linear programming.

1. Finish all countries. Retain `input.toml` and each country checkpoint.
2. Run `native_export.jl FIT NATIVE GUIDES NEW_EXPORT FACTOR`.
3. Run `native_quality.jl FIT GUIDES FACTOR BORDERS NEW_QUALITY`.
4. For approximate moment packing, also export its full reference. Run
   `audit_native_packing.jl REFERENCE_EXPORT PACKED_EXPORT NATIVE_ARROW REPORT`.
   This checks the actual binary city and navigation anchors, query changes,
   mass, geographic means, density, and the configured source-position bound.
5. Use `mobile/pack_stream.py` on each Arrow file. This is lossless dictionary
   packing, not HTTP compression. Keep the generated packing reports.
6. Use `mobile/verify_stream.jl` on each original and stream file. Name the
   reports `transport-verified.toml` and `density-verified.toml` in the stream
   directory. Each comparison must check every column.
7. Run a headless browser check. Record source cells, target cells, displayed
   labels, errors, and memory. A file-size result is not a browser-memory result.
8. Run `publish_native.py EXPORT STREAM QUALITY NEW_DESTINATION [PACKING_AUDIT]`.

The publisher verifies the hash chain before staging files. It refuses an
existing destination. It adds `population_density_hilo.json` and then renames
the staging directory. It does not start H3-MON, alter application code, change
compression, or add a viewport geometry option.

Use `Arrow.Stream` with Arrow.jl 2.8.1. `Arrow.Table` can read replacement
dictionaries incorrectly. Apache Arrow JavaScript supports the stream format.
See `mobile/stream.md` for the reader checks.

The baseline native planet retained about 1.3 GB of browser backing storage.
It is not established as phone-safe. Keep H3-5 available. Higher subdivision
factors add target cells; they do not reduce the native geographic layer.
