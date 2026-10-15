#!/usr/bin/env python3
"""Compare sampled source coasts with exterior water in a tile layout."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np
from shapely import STRtree, line_interpolate_point, transform
from shapely.geometry import Polygon, shape

from prepare_flow import equal_earth
from review_geography import exterior_water, water_edges
from review_layout import load
from save_review import digest


def uncovered_samples(geometry, index, tree, samples, tolerance):
    # The dissolved input contains polygons. Use the exterior only so that
    # lakes inside a component do not count as a source coast.
    points = line_interpolate_point(geometry.exterior, (np.arange(samples)+.5)/samples, normalized=True)
    hits = tree.query(points, predicate='dwithin', distance=tolerance)
    covered = np.zeros(samples, dtype=bool)
    covered[hits[0, hits[1] != index]] = True
    return int((~covered).sum())


def run(inputs, layout, polygons, output, samples=512, tolerance=5e-6):
    if output.exists() or samples < 16 or not np.isfinite(tolerance) or tolerance <= 0:
        raise ValueError('Use a new output and valid sampling settings')
    rows, tiles, owner = load(inputs, layout)
    features = json.loads(polygons.read_text())['features']
    labels, source = [], []
    for feature in features:
        geometry = shape(feature['geometry'])
        if geometry.geom_type != 'Polygon':
            raise ValueError('Expected dissolved Polygon components')
        labels.append(feature['properties']['component_id'])
        source.append(transform(Polygon(geometry.exterior), lambda xy: equal_earth(xy)/1000))
    if len(set(labels)) != len(labels) or not set(tiles) <= set(labels):
        raise ValueError('Invalid source component labels')
    tree = STRtree(source)
    access = water_edges(tiles, owner, exterior_water(owner))
    records = []
    for i, c in enumerate(labels):
        if c not in tiles:
            continue
        uncovered = uncovered_samples(source[i], i, tree, samples, tolerance)
        has_water = access[c]['exterior_water_edges'] > 0
        flag = 'lost-water-access' if uncovered and not has_water else 'possible-false-coast' if not uncovered and has_water else ''
        records.append(dict(component_id=c, country_id=rows[c]['country_id'], name=rows[c]['name'],
                            tiles=len(tiles[c]), uncovered_samples=uncovered, samples=samples,
                            **access[c], review_flag=flag))
    report = dict(samples=samples, tolerance=tolerance, source_components=len(labels),
        represented_components=len(tiles),
        lost_water_access=sum(r['review_flag'] == 'lost-water-access' for r in records),
        possible_false_coast=sum(r['review_flag'] == 'possible-false-coast' for r in records),
        inputs={str(p): digest(p) for p in [inputs/'groups.csv', layout/'cells.csv', polygons]},
        scripts={n: digest(Path(__file__).with_name(n)) for n in ['review_source_coasts.py', 'review_geography.py', 'prepare_flow.py']},
        limits=['Source coasts are boundary samples not covered by another source component.',
                'All source components are included, also those with no tiles.',
                'Finite sampling can miss short coasts. Tolerance can hide narrow straits.',
                'Exterior rings exclude internal lakes, but inter-component lakes can remain.',
                'Source water connectivity is not tested. These are review flags, not proof.'])
    output.mkdir(parents=True)
    with (output/'source-coasts.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    (output/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'polygons', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--samples', type=int, default=512)
    parser.add_argument('--tolerance', type=float, default=5e-6)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
