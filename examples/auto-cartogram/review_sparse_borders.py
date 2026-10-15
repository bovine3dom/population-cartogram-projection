#!/usr/bin/env python3
"""Compare shape error and blank gaps independently of the search objective."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np
from shapely import affinity, box, union_all
from shapely.geometry import shape

from review_geography import exterior_water
from review_layout import load, read_csv, quality
from save_review import digest


def shape_error(points, native):
    """Compare equal-area outlines after centroid alignment, without rotation."""
    xy = np.array(sorted(points))
    tiles = union_all(box(xy[:, 0]-.5, xy[:, 1]-.5, xy[:, 0]+.5, xy[:, 1]+.5))
    centre = tiles.centroid
    scale = np.sqrt(len(points)/native.area)
    guide = affinity.translate(affinity.scale(native, scale, scale, origin=native.centroid),
                               centre.x-native.centroid.x, centre.y-native.centroid.y)
    overlap = tiles.intersection(guide).area
    return 1-overlap/(tiles.area+guide.area-overlap)


def run(inputs, baseline, candidate, guides, output):
    if output.exists():
        raise ValueError('Use a new output directory')
    rows, before, original = load(inputs, baseline)
    _, after, owners = load(inputs, candidate)
    if set(before) != set(after) or any(len(before[c]) != len(after[c]) for c in before):
        raise ValueError('Component budgets changed')
    features = json.loads((guides/'geometry.geojson').read_text())['features']
    native = {f['properties']['component_id']: shape(f['geometry']) for f in features if f['properties']['feature_kind'] == 'land'}
    if set(native) != set(before):
        raise ValueError('Guide labels differ')
    records = []
    for c in sorted(before):
        a, b = shape_error(before[c], native[c]), shape_error(after[c], native[c])
        records.append(dict(component_id=c, country_id=rows[c]['country_id'], tiles=len(before[c]),
            before_error=a, after_error=b, improvement=a-b,
            before_perimeter=quality(before[c])['perimeter'], after_perimeter=quality(after[c])['perimeter']))
    water = {(int(r['x']), int(r['y'])) for r in read_csv(baseline/'lake-cells.csv')}
    candidate_water = {(int(r['x']), int(r['y'])) for r in read_csv(candidate/'lake-cells.csv')}
    if water != candidate_water or water & set(owners):
        raise ValueError('Named lake space changed')
    exterior = exterior_water(owners)
    newly_empty = set(original)-set(owners)
    report = dict(tiles=len(owners), components=len(after),
        before_tile_weighted_shape_error=sum(r['tiles']*r['before_error'] for r in records)/len(owners),
        after_tile_weighted_shape_error=sum(r['tiles']*r['after_error'] for r in records)/len(owners),
        newly_empty_cells=len(newly_empty), new_enclosed_empty_cells=len(newly_empty-exterior),
        named_lake_cells=len(water), records=records,
        inputs={str(p): digest(p) for p in [inputs/'groups.csv', baseline/'cells.csv', candidate/'cells.csv', baseline/'lake-cells.csv', candidate/'lake-cells.csv', guides/'geometry.geojson']},
        script_sha256=digest(Path(__file__)),
        limits=['Shape error is one minus intersection-over-union with the native dry-land outline, scaled to equal area and aligned at the tile centroid.',
                'No rotation is fitted. This measures outline similarity, not relative position or population mapping quality.',
                'New enclosed blank space is not declared to be a real lake. It includes experimental separation gaps.',
                'Tile weighting is an approximation to population weighting because component tile budgets are rounded.'])
    output.mkdir(parents=True)
    (output/'shape-comparison.json').write_text(json.dumps(report, indent=2)+'\n')
    with (output/'shape-comparison.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]), lineterminator='\n')
        writer.writeheader()
        writer.writerows(records)
    return {k: v for k, v in report.items() if k not in ('records', 'inputs', 'limits')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'baseline', 'candidate', 'guides', 'output']:
        parser.add_argument(name, type=Path)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
