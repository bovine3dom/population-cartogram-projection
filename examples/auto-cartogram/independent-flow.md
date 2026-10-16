# Independent Kontur flow

[View the comparison images](http://proto.olie.science:8642/results/geography/independent-kontur-flow/index.html).
The [current best](current-best.md) is unchanged.

## Result

Removing neighbouring countries from each flow solve changes the shapes clearly.
China becomes more compact. Russia no longer forms a thin strip over China.
India and Kazakhstan retain much more recognisable outlines. Canada also improves
in the successful 512-grid test.

| Mainland component | Shared flow error | Independent error, grid 256 | Independent error, grid 512 |
| --- | ---: | ---: | ---: |
| Russia | 0.728 | 0.528 | 0.531 |
| China | 0.670 | 0.379 | 0.382 |
| India | 0.444 | 0.128 | Not run |
| Kazakhstan | 0.787 | 0.227 | Not run |
| Canada | 0.769 | Failed | 0.202 |

Lower error means a closer outline match. The score aligns area and centre,
without rotation. The independent uniform-density controls have errors below
0.0006. Thus, internal population distribution still causes distortion, but the
shared world flow adds substantial distortion. This is not a strict causal
separation: the solver domain and effective spatial resolution also change.

## Method and limits

Each call receives only one mainland component. It reuses the exact saved
coarse patch geometry and target rows for the uniform and 90% blends. Population
and target-area sums are checked. No density samples are reassigned.

Each independent result is uniformly scaled to its component tile-area budget.
The comparison panels use equal areas within each page. They do not show relative
country sizes or positions. No world assembly, island placement, lake placement,
or tile fitting is performed. These tests release all neighbouring constraints,
not only the selected sparse borders.

Fifteen of sixteen solver calls succeeded. Canada's 256-grid 90% call failed
because a patch boundary became non-simple. That output is not used. All accepted
outputs are valid, connected polygons. Maximum patch area errors are below 0.9%.
The gallery retains inputs, commands, checksums, outputs, and the failure log.

The next step is a small regional assembly test. Use these shapes as references.
Keep dense borders connected. Permit audited sparse borders to separate. Penalize
overlap, excessive gaps, and shape change. Check whether that assembly preserves
the observed shape improvement before attempting a full planet fit.

## Reproduce

Run from the repository root, with new output paths:

```sh
export PYTHONDONTWRITEBYTECODE=1
PY=output/auto-cartogram/geometry-env/bin/python
ROOT=output/auto-cartogram
$PY examples/auto-cartogram/independent_kontur_flow.py "$ROOT" \
  "$ROOT/independent-repeat-256" --countries RUS CHN IND KAZ
$PY examples/auto-cartogram/independent_kontur_flow.py "$ROOT" \
  "$ROOT/independent-repeat-512" --countries RUS CHN CAN --grid 512
```

`publish_independent_flow.py` rebuilds the gallery from the saved
`independent-kontur-flow` and `independent-kontur-flow-512` directories.
The solver interface was checked against the
[cartogram-cpp documentation](https://github.com/mgastner/cartogram-cpp).
