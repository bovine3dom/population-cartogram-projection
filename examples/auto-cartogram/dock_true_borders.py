#!/usr/bin/env python3
"""Translate small true-border groups without adding connector tiles."""
import argparse
import csv
import json
import math
from pathlib import Path

from compact_regions import adjacent
from partition_land import contact_groups
from review_layout import connectivity, load, read_csv
from save_review import digest


def contacts(owners):
    return {tuple(sorted((c, owners[q]))) for p, c in owners.items()
            for q in adjacent(p) if q in owners and owners[q] != c}


def groups_for(labels, edges):
    groups = contact_groups(edges)
    covered = {c for group in groups for c in group}
    return groups+[[c] for c in sorted(set(labels)-covered)]


def candidates(body, tiles, owners, required, radius):
    """Align boundary cells across a missing true border."""
    shifts = set()
    for a, b in required:
        if (a in body) == (b in body):
            continue
        if b in body:
            a, b = b, a
        boundary = [p for p in tiles[a] if any(owners.get(q) != a for q in adjacent(p))]
        water = {q for p in tiles[b] for q in adjacent(p) if owners.get(q) is None or owners.get(q) in body}
        for x, y in boundary:
            for u, v in water:
                dx, dy = u-x, v-y
                if 0 < dx*dx+dy*dy <= radius*radius:
                    shifts.add((dx, dy))
    return shifts


def place(tiles, required, max_tiles=550, radius=32, rounds=4, positions=None, axis_degrees=2., detached_only=False, dependents=None):
    tiles = {c: set(points) for c, points in tiles.items()}
    owners = {p: c for c, points in tiles.items() for p in points}
    landmasses = groups_for(tiles, required)
    landmass_for = {c: group for group in landmasses for c in group}
    if not detached_only and any(connectivity(set().union(*(tiles[c] for c in g))) != 1 for g in landmasses):
        raise ValueError('Starting source landmasses must be connected')
    moves = []
    for iteration in range(rounds):
        actual = contacts(owners)
        edges = {pair for pair in actual if landmass_for[pair[0]] == landmass_for[pair[1]]} if detached_only else required & actual
        bodies = groups_for(tiles, edges)
        # Keep the largest true-border group in each source landmass fixed.
        largest = {}
        for body in bodies:
            key = min(landmass_for[body[0]])
            if key not in largest or sum(len(tiles[c]) for c in body) > sum(len(tiles[c]) for c in largest[key]):
                largest[key] = body
        changed = False
        for body in sorted(bodies, key=lambda g: (sum(len(tiles[c]) for c in g), sorted(g))):
            body = set(body)
            anchor = set(largest[min(landmass_for[min(body)])])
            if sum(len(tiles[c]) for c in body) > max_tiles or body == anchor:
                continue
            land_labels = set(landmass_for[min(body)])
            if dependents:
                body |= {c for c, parent in dependents.items() if parent in body}
            current = {pair for pair in actual if (pair[0] in body) != (pair[1] in body)}
            # Earlier translations can join this body to its neighbours. Do
            # not remove those new borders with a stale group definition.
            if current & required:
                continue
            body_points = set().union(*(tiles[c] for c in body))
            outside = {p: c for p, c in owners.items() if c not in body}
            centres = {c: tuple(sum(p[k] for p in cells)/len(cells) for k in [0, 1]) for c, cells in tiles.items()}
            constraints = []
            if positions:
                for a, b in required:
                    if (a in body) == (b in body):
                        continue
                    if b in body:
                        a, b = b, a
                    for axis in [0, 1]:
                        difference = positions[a][axis]-positions[b][axis]
                        if abs(difference) > axis_degrees:
                            constraints.append((a, b, axis, 1 if difference > 0 else -1))
            ranked = []
            for dx, dy in sorted(candidates(body, tiles, owners, required, radius)):
                if any(sign*(centres[a][axis]+(dx, dy)[axis]-centres[b][axis]) <= 0 for a, b, axis, sign in constraints):
                    continue
                shifted = {(x+dx, y+dy): c for c in body for x, y in tiles[c]}
                if any(p in outside for p in shifted):
                    continue
                boundary = {tuple(sorted((c, outside[q]))) for p, c in shifted.items()
                            for q in adjacent(p) if q in outside}
                gained = boundary & required
                if not gained or len(boundary-required) > len(current-required):
                    continue
                core_gains = sum(a in anchor or b in anchor for a, b in gained)
                ranked.append(((-core_gains, -len(gained), len(boundary-required), dx*dx+dy*dy, dx, dy), shifted, boundary))
            land = set().union(*(tiles[c] for c in land_labels))
            for score, shifted, boundary in sorted(ranked, key=lambda item: item[0]):
                shifted_land = {p for p, c in shifted.items() if c in land_labels}
                parts = connectivity((land-body_points) | shifted_land)
                if (parts >= connectivity(land) if detached_only else parts != 1):
                    continue
                dx, dy = score[-2:]
                for c in body:
                    tiles[c] = {(x+dx, y+dy) for x, y in tiles[c]}
                owners = outside | shifted
                actual = (actual-current) | boundary
                moves.append(dict(round=iteration+1, components=sorted(body), dx=dx, dy=dy,
                                  gained_true_contacts=sorted(boundary & required),
                                  old_false_contacts=sorted(current-required), new_false_contacts=sorted(boundary-required)))
                changed = True
                break
        if not changed:
            break
    return tiles, moves


def coastal_dependents(polygons, tiles, required, radius_km):
    from shapely import STRtree, transform
    from shapely.geometry import shape
    from prepare_flow import equal_earth
    land = sorted({c for pair in required for c in pair})
    if not land:
        return {}
    source = {f['properties']['component_id']: transform(shape(f['geometry']), lambda xy: equal_earth(xy)/1000)
              for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in tiles}
    tree = STRtree([source[c] for c in land])
    dependents = {}
    for c in sorted(set(tiles)-set(land)):
        nearest = min((source[c].distance(source[land[int(i)]]), land[int(i)]) for i in tree.query_nearest(source[c], all_matches=True))
        if nearest[0]*6371 <= radius_km:
            dependents[c] = nearest[1]
    return dependents


def run(inputs, layout, output, max_tiles=550, radius=32, rounds=4, detached_only=False, polygons=None, coastal_islands_km=500.):
    if output.exists() or min(max_tiles, radius, rounds) < 1 or not math.isfinite(coastal_islands_km) or coastal_islands_km <= 0:
        raise ValueError('Use a new output and positive settings')
    rows, original, owners = load(inputs, layout)
    if any(len(original[c]) != int(rows[c]['tiles']) for c in original):
        raise ValueError('Exact initial tile counts required')
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}
    positions = {c: ((float(r['west'])+float(r['east']))/2, (float(r['south'])+float(r['north']))/2) for c, r in rows.items()}
    dependents = coastal_dependents(polygons, original, required, coastal_islands_km) if polygons else {}
    tiles, moves = place(original, required, max_tiles, radius, rounds, positions=positions, detached_only=detached_only, dependents=dependents)
    after = contacts({p: c for c, points in tiles.items() for p in points})
    before = contacts(owners)
    if (before & required)-after or len(after-required) > len(before-required):
        raise AssertionError('Border regression')
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['component_id', 'x', 'y'])
        for c, points in sorted(tiles.items()):
            writer.writerows((c, x, y) for x, y in sorted(points))
    report = dict(max_tiles=max_tiles, radius=radius, rounds=rounds, detached_only=detached_only,
                  coastal_islands_km=coastal_islands_km, dependent_islands=dependents, moves=moves,
                  missing_before=len(required-before), missing_after=len(required-after),
                  false_before=len(before-required), false_after=len(after-required),
                  inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', layout/'cells.csv']+([polygons] if polygons else [])},
                  script_sha256=digest(Path(__file__)),
                  limits=['Rigid translations retain shapes and budgets. Border-neighbour axis guards use source bounding-box centres and a two-degree threshold.',
                          'Bounding-box centres are approximate and can be misleading across the antimeridian. Other neighbour orders are not guarded.',
                          'No new connector tiles are made. Existing narrow shapes are retained.',
                          'Dependent islands use nearest source coast within an Equal Earth distance threshold, not country membership. Their relative positions within a moving group are unchanged.',
                          'Normal mode retains source-landmass connectivity. Detached-only mode requires each move to reduce the number of parts.',
                          'No result is automatically approved.'])
    (output/'docking.json').write_text(json.dumps(report, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=true-border-translation\ncounts=exact\napproval=none\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--polygons', type=Path, help='Move nearby independent islands with their nearest source land component')
    parser.add_argument('--coastal-islands-km', type=float, default=500.)
    parser.add_argument('--detached-only', action='store_true')
    for name, default in [('max-tiles', 550), ('radius', 32), ('rounds', 4)]:
        parser.add_argument('--'+name, type=int, default=default)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
