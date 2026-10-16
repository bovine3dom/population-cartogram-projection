#!/usr/bin/env python3
"""Restore filled reference water with count-preserving, single-country vacancy paths."""
import argparse
from collections import Counter
import csv
import json
from pathlib import Path
import shutil

from compact_regions import adjacent
from dock_true_borders import contacts
from lake_vacancies import VacancyLayout
from review_geography import exterior_water
from review_layout import axis_order, load, read_csv
from save_review import digest


def enclosed(owner):
    sea = exterior_water(owner)
    bounds = [range(min(p[i] for p in owner), max(p[i] for p in owner)+1) for i in (0, 1)]
    return {(x, y) for x in bounds[0] for y in bounds[1] if (x, y) not in owner and (x, y) not in sea}


def restore(tiles, reference, required, inland, maximum_cost=32, limit=64, order_guard=None):
    if Counter(reference.values()) != Counter({c: len(p) for c, p in tiles.items()}):
        raise ValueError('Reference and candidate budgets differ')
    state = VacancyLayout(tiles, required, inland)
    water = enclosed(reference)
    shores = {q for p in water for q in adjacent(p)}-water
    if any(reference.get(p) != state.owners.get(p) for p in shores):
        raise ValueError('Reference water shore labels already changed')
    original_contacts = contacts(state.owners)
    coastal = {c for c in tiles if c not in inland and state.ocean_edges(c)}
    moves = []
    for p in sorted(water & state.owners.keys()):
        c = state.owners[p]
        best = None
        for path in state.paths(p, maximum_cost=maximum_cost, limit=limit):
            if path[-1] in water or any(state.owners[q] != c for q in path[:-1]):
                continue
            action = state.attempt(path)
            if action is None:
                continue
            actual = {pair for pair, n in state.contacts.items() if n > 0}
            valid = (not (actual-required-original_contacts)
                     and all(state.ocean_edges(c) for c in coastal)
                     and (order_guard is None or order_guard(state.tiles)))
            if valid:
                perimeter = sum(q not in state.tiles[c] for v in state.tiles[c] for q in adjacent(v))
                score = (perimeter, len(path), path[-1])
                if best is None or score < best[0]:
                    best = score, path
            state.undo(action)
        if best is None:
            raise ValueError('No safe single-country path for reference water at '+str(p))
        action = state.attempt(best[1])
        assert action is not None
        moves.append(dict(component=c, restored_water=p, added_coast=best[1][-1], path=best[1]))
    if enclosed(state.owners) != water:
        raise ValueError('Enclosed water differs after restoration')
    if order_guard is not None and not order_guard(state.tiles):
        raise ValueError('Source-axis order guard failed')
    assert all(reference.get(p) == state.owners.get(p) for p in shores)
    assert all(len(state.tiles[c]) == len(tiles[c]) for c in tiles)
    actual = contacts(state.owners)
    assert not (original_contacts & required)-actual and not actual-required-original_contacts
    return state.tiles, moves


def run(inputs, layout, reference, source_coasts, output):
    if output.exists():raise ValueError('Use a new output')
    rows, tiles, _ = load(inputs, layout)
    _, reference_tiles, reference_owner = load(inputs, reference)
    if any(len(tiles[c]) != int(rows[c]['tiles']) for c in tiles):raise ValueError('Exact counts required')
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}
    coast_rows = read_csv(source_coasts)
    if not set(tiles) <= {r['component_id'] for r in coast_rows}:raise ValueError('Missing coast labels')
    inland = {r['component_id'] for r in coast_rows if int(r['uncovered_samples']) == 0}
    old_errors = set(axis_order(rows, reference_tiles)[1])
    result, moves = restore(tiles, reference_owner, required, inland,
                            order_guard=lambda t: set(axis_order(rows, t)[1]) <= old_errors)
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w', newline='') as stream:
        writer = csv.writer(stream); writer.writerow(['component_id', 'x', 'y'])
        for c, points in sorted(result.items()):writer.writerows((c, x, y) for x, y in sorted(points))
    for name in ('lake-cells.csv', 'lake-placement.json'):
        if (layout/name).exists():shutil.copyfile(layout/name, output/name)
    record = dict(moves=moves,
                  inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', layout/'cells.csv', reference/'cells.csv', source_coasts]
                          + [layout/name for name in ('lake-cells.csv', 'lake-placement.json') if (layout/name).exists()]},
                  script_sha256=digest(Path(__file__)), cells_sha256=digest(output/'cells.csv'),
                  limits=['Restore existing enclosed water only; this does not identify real lakes.',
                          'Paths stay within one component. Only the two endpoints change ownership.',
                          'Keep exact budgets, true borders, reference water shores, and sampled coast access. Add no false border pairs.',
                          'Do not add same-country source-axis errors relative to the reference. This heuristic is not a geographic proof.',
                          'Existing opened holes or changed shore labels can make restoration fail. No production approval.'])
    (output/'water-restoration.json').write_text(json.dumps(record, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=reference-water-restoration\ncounts=exact\napproval=none\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'reference', 'source_coasts', 'output']:
        parser.add_argument(name, type=Path)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
