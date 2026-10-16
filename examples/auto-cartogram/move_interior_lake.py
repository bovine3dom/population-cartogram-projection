#!/usr/bin/env python3
"""Test a rigid lake move inside one shore component without changing its budget."""
import argparse
import csv
import json
from pathlib import Path

from compact_regions import adjacent
from dock_true_borders import contacts
from review_layout import connectivity, load, read_csv
from save_review import digest


def move(tiles, waters, lake_id, shift):
    """Exchange an interior lake with land. Reject shared or exposed shores."""
    owner = {p: c for c, points in tiles.items() for p in points}
    water = set().union(*waters.values())
    if water & owner.keys():
        raise ValueError('Starting lake overlaps land')
    if sum(map(len, waters.values())) != len(water):
        raise ValueError('Starting lakes overlap')
    points = waters[lake_id]
    shore = {owner.get(q) for p in points for q in adjacent(p) if q not in points}
    if len(shore) != 1 or None in shore:
        raise ValueError('Lake must be enclosed by one component')
    c = next(iter(shore))
    moved = {(x+shift[0], y+shift[1]) for x, y in points}
    if moved & (water-points) or any(owner.get(p) != c for p in moved-points):
        raise ValueError('Destination must be inside the same shore component')
    result = dict(tiles)
    result[c] = (tiles[c] | points)-moved
    after = {p: v for v, cells in result.items() for p in cells}
    lakes = dict(waters, **{lake_id: moved})
    for key, cells in lakes.items():
        for p in cells:
            for q in adjacent(p):
                if q in cells:
                    continue
                if key == lake_id:
                    if after.get(q) != c:
                        raise ValueError('Moved lake is not enclosed by its shore component')
                elif owner.get(q) != after.get(q):
                    raise ValueError('Another lake shore changed')
    if len(result[c]) != len(tiles[c]) or connectivity(result[c]) != 1:
        raise ValueError('Budget or component connectivity changed')
    if contacts(after) != contacts(owner):
        raise ValueError('Country borders changed')
    return result, lakes


def run(inputs, layout, output, lake_id, dx, dy):
    if output.exists() or (dx, dy) == (0, 0):
        raise ValueError('Use a new output and a nonzero shift')
    rows, tiles, _ = load(inputs, layout)
    if any(len(tiles[c]) != int(rows[c]['tiles']) or connectivity(tiles[c]) != 1 for c in tiles):
        raise ValueError('Exact connected starting components required')
    lake_rows = read_csv(layout/'lake-cells.csv')
    waters = {}
    for r in lake_rows:
        waters.setdefault(r['lake_id'], set()).add((int(r['x']), int(r['y'])))
    report = json.loads((layout/'lake-placement.json').read_text())
    accepted = {r['lake_id']: r for r in report['lakes'] if r.get('accepted')}
    if set(accepted) != set(waters):
        raise ValueError('Lake report and cells differ')
    result, lakes = move(tiles, waters, lake_id, (dx, dy))
    owner = {p: c for c, cells in result.items() for p in cells}
    for key, points in lakes.items():
        shore = {owner.get(q) for p in points for q in adjacent(p) if q not in points}
        lake = accepted[key]
        if not set(lake['required_shores']) <= shore <= set(lake['allowed_shores']):
            raise ValueError('Lake shore rules failed: '+lake['name'])
    accepted[lake_id]['centre'] = [sum(p[i] for p in lakes[lake_id])/len(lakes[lake_id]) for i in (0, 1)]
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w', newline='') as stream:
        writer = csv.writer(stream); writer.writerow(['component_id', 'x', 'y'])
        for c, points in sorted(result.items()):
            writer.writerows((c, x, y) for x, y in sorted(points))
    with (output/'lake-cells.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=['lake_id', 'name', 'x', 'y']); writer.writeheader()
        for key, points in sorted(lakes.items()):
            writer.writerows(dict(lake_id=key, name=accepted[key]['name'], x=x, y=y) for x, y in sorted(points))
    record = dict(lake_id=lake_id, dx=dx, dy=dy,
                  inputs={str(p): digest(p) for p in [inputs/'groups.csv', layout/'cells.csv', layout/'lake-cells.csv', layout/'lake-placement.json']},
                  script_sha256=digest(Path(__file__)),
                  cells_sha256=digest(output/'cells.csv'), lake_cells_sha256=digest(output/'lake-cells.csv'),
                  limits=['Interior lake exchange only. Shared-shore lakes cannot move.',
                          'The lake shape, water count, land budget, borders, and other lake shores stay fixed.',
                          'The lake moves in tile coordinates, not from a new source-geography fit. No production approval.'])
    report['interior_move'] = record
    (output/'lake-placement.json').write_text(json.dumps(report, indent=2)+'\n')
    (output/'lake-move.json').write_text(json.dumps(record, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=interior-lake-exchange\ncounts=exact\napproval=none\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--lake-id', required=True)
    parser.add_argument('--dx', type=int, required=True)
    parser.add_argument('--dy', type=int, required=True)
    run(**vars(parser.parse_args()))
