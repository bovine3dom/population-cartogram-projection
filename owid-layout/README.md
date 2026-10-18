# Population-aware OWID-style cartograms

This Julia package adjusts island populations in an existing square-tile
cartogram. It then fits population sources to those tiles and writes Arrow files
for H3-MON. It does not generate a new world layout or fit borders between
countries.

## Start here

- [Supported workflow and commands](workflow.md)
- [Layout rules and limits](clean-build.md)
- [Current world map](../examples/auto-cartogram/results/owid-clean-build/world.svg)
- [Current review gallery](../examples/auto-cartogram/results/owid-clean-build/index.html)

The layout needs three datasets: a cartogram CSV, Kontur population, and Natural
Earth map-unit boundaries. The cartogram is an input. Its size, tile count, and
country set are not fixed. Custom country-code and scope tables are supported.
See the workflow for the required formats.

The tag `owid-clean-layout-baseline-v1` preserves the reviewed island layout.
Two full builds produced identical results across all 17 output files. The
mainland trials did not change that layout. H3-MON deployment is a separate step.

## Test

Run from the repository root with Julia 1.12:

```sh
julia --project=owid-layout -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

Tests use small source fixtures and the checked-in OWID CSV. They do not need
the full Kontur dataset. The fixture tests include a custom regional cartogram,
a custom country code, and a complete fit and Arrow export.

## Separate research

The package does not load the methods in `research/mainland/`. The research
commands load them explicitly. These trials are not supported build stages:

- [West Africa border trials](west-africa.md)
- [Two-piece movement trials](block-slide.md)
- [Earlier corner-group resize trial](group-resize.md)

The older reviewed scope-split layout is preserved at the tag
`owid-reviewed-scope-splits-2026-10-18`. Earlier identity reports remain in
`research/identity-audit/` and the published review galleries. Checked island
identities are test expectations. They are not inputs to the matcher.
