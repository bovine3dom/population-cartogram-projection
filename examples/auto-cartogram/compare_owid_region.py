#!/usr/bin/env python3
"""Compare regional outline errors and separations with the OWID reference."""
import argparse
import gzip
import itertools
import json
from pathlib import Path
import tempfile

from shapely.geometry import shape

from compact_regions import adjacent
from relax_sparse_borders import gap_distance
from review_gaps import read_cells, draw_layout
from review_layout import load
from review_sparse_borders import shape_error
from save_review import digest


def largest_part(points):
    remaining = set(points)
    parts = []
    while remaining:
        start = min(remaining)
        remaining.remove(start)
        part, queue = {start}, [start]
        while queue:
            for q in adjacent(queue.pop()):
                if q in remaining:
                    remaining.remove(q)
                    part.add(q)
                    queue.append(q)
        parts.append(part)
    return max(parts, key=len)


def run(inputs, layout, guides, owid, output, country):
    if output.exists():
        raise ValueError('Use a new output directory')
    codes = dict(c.split(':') for c in country)
    rows, tiles, owners = load(inputs, layout)
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder)/'owid.csv'
        path.write_bytes(gzip.decompress(owid.read_bytes()))
        reference, source = read_cells(path, owid=True)
    main = {c: max((k for k in tiles if rows[k]['country_id'] == c), key=lambda k: len(tiles[k])) for c in codes}
    current = {c: tiles[k] for c, k in main.items()}
    old = {c: largest_part({p for p, label in reference.items() if int(label) == int(code)}) for c, code in codes.items()}
    features = json.loads((guides/'geometry.geojson').read_text())['features']
    native = {f['properties']['component_id']: shape(f['geometry']) for f in features if f['properties']['feature_kind'] == 'land'}
    records = [dict(country=c, component=main[c], current_tiles=len(current[c]), owid_tiles=len(old[c]),
                    current_shape_error=shape_error(current[c], native[main[c]]),
                    owid_shape_error=shape_error(old[c], native[main[c]])) for c in sorted(codes)]
    pairs = [dict(a=a, b=b, current_nearest_centre=gap_distance(current[a], current[b]),
                  owid_nearest_centre=gap_distance(old[a], old[b])) for a, b in itertools.combinations(sorted(codes), 2)]
    report = dict(records=records, pairs=pairs, owid_source=source,
                  current_world_tiles=len(owners), owid_world_tiles=len(reference),
                  inputs={str(p): digest(p) for p in [inputs/'groups.csv', layout/'cells.csv', guides/'geometry.geojson', owid, Path(__file__)]},
                  limits=['Use the largest represented source component in the new map and the largest four-connected country part in OWID.',
                          'OWID country parts do not have the same source-component or population scope. Outline scores are approximate references.',
                          'Shape error is one minus outline intersection-over-union after equal-area scaling and centroid alignment. No rotation is fitted.',
                          'Separations use grid Chebyshev centre distances: 1 can mean edge or corner contact. Subtract 1 for an approximate blank-cell width.',
                          'Nearest separation does not measure the full gap. The world tile totals are similar, but country budgets differ.',
                          'This is a diagnostic, not a new layout or a gap target.'])
    output.mkdir(parents=True)
    (output/'comparison.json').write_text(json.dumps(report, indent=2)+'\n')
    for name, points in [('current', current), ('owid', old)]:
        draw_layout(output/(name+'.svg'), {p: c for c, part in points.items() for p in part},
                    name.upper()+': selected mainland shapes and relative positions', {}, {})
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'guides', 'owid', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--country', action='append', required=True, help='ISO code:OWID numeric code')
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
