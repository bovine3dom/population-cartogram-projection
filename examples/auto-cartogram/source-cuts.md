# Border cuts before flow

## Result

[View the comparisons](http://proto.olie.science:8642/results/geography/strategic-source-cuts/index.html).
The selected [current best](current-best.md) is unchanged.

Five cut trials and two fresh controls completed. Each trial ran the 0%, 50%,
and 90% population blends. All 21 solver runs succeeded. All trials retained
189 mainland components, 369 patches, and 7,221,236,218 people. Each component
kept its population and target tile budget.

The cuts precede patch construction and continuous fitting. Two-border trials
open Russia–Kazakhstan and China–Kazakhstan, with nominal widths of 1, 25, and
50 km. Four-border trials also open Russia–China and Russia–Mongolia, with
widths of 1 and 5 km. Widths use Equal Earth coordinates, not local distances.

Visual checks show no useful large-scale shape change. Russia remains a thin
strip above China. Kazakhstan changes slightly. Its outline error falls from
0.797–0.804 in the controls to 0.743 with the two 50 km cuts. Russia's error is
0.728–0.732 in the controls and 0.729 in that trial. Small changes must be
compared with the variation between repeated controls.

The two sides still share one continuous deformation. Source gaps alone do not
release this constraint. Do not spend a full tile fit on these results. The
next test needs separate deformation freedom across selected borders, with
constraints on dense borders, shape change, and excessive separation.

## Guards and limits

- All selected borders pass the existing 25 km population corridor audit.
  Whole-border statistics do not prove that every segment is sparse.
- No unselected source contact may disappear. Four-border 25 km and 50 km
  preparations failed this guard because Russia–North Korea also disappears.
- Each resulting source component must be one valid polygon. Fragment removal
  is off by default. Wider trials permit removal of small fragments up to
  0.01% of component source area. Total area loss must remain below 10%.
- Samples in removed strips or fragments stay in their original component.
  The density builder assigns them to the nearest patch in that component.
- The geographic reference for shape scores is unchanged. Cuts do not redefine
  the reference. Each trial uses the same patches for all three blends; patch
  boundaries and populations can change between trials.
- The 90% outputs contain valid, connected components. For Russia, China, India,
  and Kazakhstan, area errors are below 0.04%. The existing solver area floor
  still inflates some tiny components. These are not exact tile layouts.
- No tile fit, island placement, lake placement, or H3-MON export was run.
  Any future tile experiment must remove selected cuts from the required-contact
  policy and measure whether those contacts return.

## Reproduce a trial

Use a new output directory for each run. Run from the repository root:

```sh
export PYTHONDONTWRITEBYTECODE=1
PY=output/auto-cartogram/geometry-env/bin/python
ROOT=output/auto-cartogram
TRIAL=$ROOT/strategic-source-cuts-repeat

$PY examples/auto-cartogram/cut_flow_source.py "$ROOT" "$TRIAL/seams-50" \
  --pair RUS:KAZ --pair CHN:KAZ --width-km 50 --maximum-fragment-loss .0001
$PY examples/auto-cartogram/kontur_subregion_flow.py "$ROOT" "$TRIAL/flow-50" \
  --geometry "$TRIAL/seams-50/geometry.geojson"
$PY examples/auto-cartogram/kontur_subregion_flow.py "$ROOT" "$TRIAL/control"
```

The published gallery contains input hashes, solver commands, per-component
scores, source cut manifests, compressed source and flow geometry, and world
and regional images. `review_source_cuts.py` builds the gallery from the seven
named trial directories. `checksums.json` covers the published files.
