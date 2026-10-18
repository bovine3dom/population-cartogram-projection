# Supported workflow

## Layout baseline

The current layout is the [clean build](clean-build.md).
[Open the world map](../examples/auto-cartogram/results/owid-clean-build/world.svg).
The tag `owid-clean-layout-baseline-v1` preserves the code and review files.
The SHA-256 of `examples/auto-cartogram/results/owid-clean-build/cells.csv` is:

```text
ecb5033efa791e51f6fd3aeb9f857ba74903341040642a60991938fa0f009629
```

The two full builds produced identical files. The mainland trials did not change
this layout. Their methods are in `research/mainland/`. The package does not load
them. To run their separate tests:

```sh
julia --project=owid-layout owid-layout/research/mainland/tests.jl
```

## Work log

- Selected the clean layout as the baseline. Kept all earlier review files.
- Removed the mainland trial methods from the supported package load path.
- Next: add the clean-build adapter, grouped H3 fitting, and Julia Arrow export.
