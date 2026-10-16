#!/usr/bin/env python3
"""Repair sampled coast access with short, count-preserving land swaps."""
import argparse
from collections import deque
import csv
import json
from pathlib import Path
import shutil

from compact_regions import adjacent
from lake_vacancies import VacancyLayout
from review_layout import load, read_csv, connectivity
from save_review import digest


def repair(tiles, required, landlocked, fixed=(), rounds=200, radius=12,
           buffer=0, fixed_cells=()):
    if buffer < 0:
        raise ValueError('Buffer must be non-negative')
    fixed_cells = set(fixed_cells)
    state = VacancyLayout(tiles, required, landlocked, fixed=fixed)
    # The footprint never changes, so exterior water and distances stay fixed.
    distance = {p: 1 for p in state.owners if any(q in state.exterior for q in adjacent(p))}
    queue = deque(sorted(distance))
    while queue:
        p = queue.popleft()
        for q in adjacent(p):
            if q in state.owners and q not in distance:
                distance[q] = distance[p]+1
                queue.append(q)
    # One lost sea edge outweighs all buffer costs in a component.
    weight = 1 + buffer * max(map(len, tiles.values()))
    costs = {p: weight * sum(q in state.exterior for q in adjacent(p))
             + max(0, buffer + 1 - distance.get(p, 10000)) for p in state.owners}
    def score(c):
        if c in landlocked:
            return sum(costs[p] for p in state.tiles[c])
        return max(0, min(distance.get(p, 10000) for p in state.tiles[c])-1)
    history = []
    for _ in range(rounds):
        changed = False
        for c in sorted(state.tiles, key=lambda c: (-score(c), c)):
            if c in state.fixed or score(c) == 0:
                continue
            points = state.tiles[c]
            frontier = {q for p in points for q in adjacent(p) if state.owners.get(q) not in (None, c)}
            offers = []
            for q in sorted(frontier):
                d = state.owners[q]
                if d in state.fixed or q in fixed_cells:
                    continue
                for p in sorted(points):
                    length = abs(p[0]-q[0])+abs(p[1]-q[1])
                    if p in fixed_cells or length > radius or not any(state.owners.get(r) == d for r in adjacent(p)):
                        continue
                    if c in landlocked:
                        benefit = costs[p]-costs[q]
                    else:
                        benefit = min(distance.get(r, 10000) for r in points)-distance.get(q, 10000)
                    if benefit > 0:
                        offers.append((-benefit, length, p, q, d))
            for _, _, p, q, d in sorted(offers):
                before_score = {v: score(v) for v in (c, d)}
                before_contacts = {k for k, n in state.contacts.items() if n > 0}
                before = state.update({p: d, q: c})
                after_contacts = {k for k, n in state.contacts.items() if n > 0}
                valid = (score(c) < before_score[c] and score(d) <= before_score[d]
                    and not ((before_contacts & required)-after_contacts)
                    and not (after_contacts-required-before_contacts)
                    and all(connectivity(state.tiles[v]) == 1 for v in (c, d)))
                if not valid:
                    state.update(before)
                    continue
                history.append(dict(component=c, other=d, removed=p, added=q,
                                    before=before_score, after={v: score(v) for v in (c, d)}))
                changed = True
                break
        if not changed:
            break
    assert set(state.owners) == set().union(*tiles.values())
    assert all(len(state.tiles[c]) == len(tiles[c]) for c in tiles)
    return state.tiles, history


def run(inputs, layout, source_coasts, output, rounds=200, radius=12, buffer=0):
    if output.exists() or min(rounds, radius) < 1:
        raise ValueError('Use a new output and positive limits')
    rows, tiles, _ = load(inputs, layout)
    if any(len(tiles[c]) != int(rows[c]['tiles']) for c in tiles):
        raise ValueError('Exact starting counts required')
    contacts = read_csv(inputs/'geographic-contacts.csv')
    required = {tuple(sorted((r['a'], r['b']))) for r in contacts if r['both_represented'] == 'true'}
    land = {c for p in required for c in p}
    coasts = read_csv(source_coasts)
    if not set(tiles) <= {r['component_id'] for r in coasts}:
        raise ValueError('Missing source coast classifications')
    inland = {r['component_id'] for r in coasts if int(r['uncovered_samples']) == 0}
    lakes = read_csv(layout/'lake-cells.csv') if (layout/'lake-cells.csv').exists() else []
    shores = {q for r in lakes for q in adjacent((int(r['x']), int(r['y'])))}
    result, history = repair(tiles, required, inland, set(tiles)-land, rounds, radius,
                             buffer=buffer, fixed_cells=shores)
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['component_id', 'x', 'y'])
        for c, points in sorted(result.items()):
            writer.writerows((c, x, y) for x, y in sorted(points))
    for name in ['lake-cells.csv', 'lake-placement.json']:
        if (layout/name).exists():
            shutil.copyfile(layout/name, output/name)
    record = dict(rounds=rounds, radius=radius, buffer=buffer, swaps=history,
                  inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', layout/'cells.csv', source_coasts]
                          + [layout/name for name in ('lake-cells.csv', 'lake-placement.json') if (layout/name).exists()]},
                  script_sha256=digest(Path(__file__)), cells_sha256=digest(output/'cells.csv'),
                  limits=['Source coast labels use finite samples, not a proof of ocean access.',
                          'The footprint, lakes, island cells, and all component budgets stay fixed.',
                          'Swaps keep all existing true contacts and add no false contacts.',
                          'A local search can stop with defects. Shapes need visual review.'])
    (output/'coast-repair.json').write_text(json.dumps(record, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=coast-access-swaps\ncounts=exact\napproval=none\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'source_coasts', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--rounds', type=int, default=200)
    parser.add_argument('--radius', type=int, default=12)
    parser.add_argument('--buffer', type=int, default=0)
    run(**vars(parser.parse_args()))
