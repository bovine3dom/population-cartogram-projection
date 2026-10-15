#!/usr/bin/env python3
"""Measure water access and nearby component order without changing the layout."""
import argparse
import csv
import json
from collections import deque
from pathlib import Path

import numpy as np
from shapely import STRtree, transform
from shapely.geometry import shape

from prepare_flow import equal_earth
from review_layout import load, read_csv, connectivity, NEIGHBOURS
from partition_land import contact_groups
from save_review import digest


def exterior_water(owner):
    """Find empty cells with a four-neighbour path to the outer frame."""
    if not owner:
        raise ValueError('Empty layout')
    xmin, xmax = min(x for x, y in owner)-1, max(x for x, y in owner)+1
    ymin, ymax = min(y for x, y in owner)-1, max(y for x, y in owner)+1
    start = (xmin, ymin)
    water = {start}
    queue = deque([start])
    while queue:
        x, y = queue.popleft()
        for dx, dy in NEIGHBOURS:
            p = x+dx, y+dy
            if xmin <= p[0] <= xmax and ymin <= p[1] <= ymax and p not in owner and p not in water:
                water.add(p)
                queue.append(p)
    return water


def water_edges(tiles, owner, water):
    result = {}
    for c, points in tiles.items():
        ocean = enclosed = 0
        for x, y in points:
            for dx, dy in NEIGHBOURS:
                p = x+dx, y+dy
                if p not in owner:
                    ocean += p in water
                    enclosed += p not in water
        result[c] = dict(exterior_water_edges=ocean, enclosed_water_edges=enclosed)
    return result


def separated_axes(a, b, ta, tb):
    """Report source box separations lost by the tile boxes."""
    errors = []
    for axis in range(2):
        if a.bounds[axis+2] < b.bounds[axis] and ta[:, axis].max() >= tb[:, axis].min():
            errors.append(['east', 'north'][axis])
        elif b.bounds[axis+2] < a.bounds[axis] and tb[:, axis].max() >= ta[:, axis].min():
            errors.append(['west', 'south'][axis])
    return errors


def landmass_connectivity(tiles, pairs):
    return [dict(components=group, parts=connectivity(set().union(*(tiles[c] for c in group))))
            for group in contact_groups(pairs)]


def run(inputs, layout, polygons, output, neighbours=4):
    if output.exists() or neighbours < 1:
        raise ValueError('Use a new output and a positive neighbour count')
    rows, tiles, owner = load(inputs, layout)
    features = json.loads(polygons.read_text())['features']
    source = {f['properties']['component_id']: transform(shape(f['geometry']), equal_earth)
              for f in features if f['properties']['component_id'] in tiles}
    if set(source) != set(tiles):
        raise ValueError('Source components differ from layout components')
    points = {c: np.asarray(sorted(p)) for c, p in tiles.items()}
    water = exterior_water(owner)
    access = water_edges(tiles, owner, water)
    pairs = set()
    labels = sorted(source)
    tree = STRtree([source[c] for c in labels])
    count = min(neighbours, len(labels)-1)
    for c in labels:
        radius = 1.
        nearby = []
        while len(nearby) < count:
            candidates = tree.query(source[c], predicate='dwithin', distance=radius)
            nearby = sorted((source[c].distance(source[labels[i]]), labels[i])
                            for i in candidates if labels[i] != c)
            radius *= 2
        pairs.update(tuple(sorted((c, b))) for _, b in nearby[:count])
    relations = []
    for a, b in sorted(pairs):
        relations.append(dict(a=a, b=b, country_a=rows[a]['country_id'], country_b=rows[b]['country_id'],
            source_gap_projected=source[a].distance(source[b]),
            lost_box_separations=separated_axes(source[a], source[b], points[a], points[b])))
    contacts = read_csv(inputs/'geographic-contacts.csv')
    landmass_parts = landmass_connectivity(tiles, [(r['a'], r['b']) for r in contacts if r['both_represented'] == 'true'])
    report = dict(neighbours=neighbours, pairs=len(relations),
        source_landmasses_split=sum(r['parts'] > 1 for r in landmass_parts),
        extra_landmass_parts=sum(r['parts']-1 for r in landmass_parts),
        pairs_with_lost_separation=sum(bool(r['lost_box_separations']) for r in relations),
        components_without_exterior_water=sum(not r['exterior_water_edges'] for r in access.values()),
        inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', layout/'cells.csv', polygons]},
        script_sha256=digest(Path(__file__)),
        limits=['Exterior water is a tile-grid measurement, not a source coastline classification.',
                'Enclosed water can be a real lake or a layout defect.',
                'Nearest neighbours use Equal Earth planar distance, not geodesic distance.',
                'Lost box separation is a review flag, not proof of incorrect geography.',
                'The source antimeridian can affect neighbour distances.'])
    output.mkdir(parents=True)
    with (output/'water-access.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=['component_id', 'country_id', 'name', 'tiles', 'exterior_water_edges', 'enclosed_water_edges'])
        writer.writeheader()
        for c in sorted(tiles):
            writer.writerow(dict(component_id=c, country_id=rows[c]['country_id'], name=rows[c]['name'], tiles=len(tiles[c]), **access[c]))
    (output/'landmass-parts.json').write_text(json.dumps(landmass_parts, indent=2)+'\n')
    (output/'nearby-relations.json').write_text(json.dumps(relations, indent=2)+'\n')
    (output/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'polygons', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--neighbours', type=int, default=4)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
