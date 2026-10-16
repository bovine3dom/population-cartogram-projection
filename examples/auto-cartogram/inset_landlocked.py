#!/usr/bin/env python3
"""Test a three-component exchange that moves an inland component off the coast."""
import argparse
import csv
import json
from pathlib import Path
import shutil

from compact_regions import adjacent
from dock_true_borders import contacts
from lake_vacancies import VacancyLayout
from review_geography import water_edges
from review_layout import connectivity, load, read_csv
from save_review import digest


def trial(tiles, required, inland, target, donor, cover, shift, fixed_cells=(), reach=16):
    if len({target, donor, cover}) != 3 or target not in inland or {donor, cover} & inland:
        raise ValueError('Use one inland target and two distinct coastal components')
    owner = {p: c for c, cells in tiles.items() for p in cells}
    actual = contacts(owner)
    wanted = actual & required
    old = tiles[target]
    new = {(x+shift[0], y+shift[1]) for x, y in old}
    if not new-old or any(owner.get(p) != donor for p in new-old):
        return None, 'Shift does not enter a single donor'
    neighbours = {b if a == target else a for a, b in wanted if target in (a, b)}
    def touching(points):
        return {owner[q] for p in points for q in adjacent(p) if q not in points and q in owner and owner[q] in neighbours}
    # Retain a former boundary cell when the translation would lose a true border.
    # Exchange it for a donor cell; do not add a connector or change the budget.
    retained = []
    for neighbour in sorted(neighbours-touching(new)):
        if neighbour in touching(new):
            continue
        offers = []
        for p in old-new:
            if not any(q in new for q in adjacent(p)) or not any(owner.get(q) == neighbour for q in adjacent(p)):
                continue
            for q in new-old:
                candidate = (new-{q}) | {p}
                if not (touching(new) | {neighbour}) <= touching(candidate) or connectivity(candidate) != 1:
                    continue
                score = (sum(r in candidate for r in adjacent(q)), abs(p[0]-q[0])+abs(p[1]-q[1]), p, q)
                offers.append((score, candidate))
        if not offers:
            return None, 'Cannot retain a true target border locally'
        score, new = min(offers, key=lambda item: item[0])
        retained.append(dict(kept=score[-2], returned=score[-1]))
    if not neighbours <= touching(new):
        return None, 'Target border lost'
    vacated, invaded = old-new, new-old
    changed = vacated | invaded
    if changed & set(fixed_cells):
        return None, 'Protected shore cell changed'
    provisional = dict(tiles)
    provisional[target] = new
    provisional[cover] = tiles[cover] | vacated
    provisional[donor] = tiles[donor]-invaded
    affected = {target, donor, cover}
    if any(connectivity(provisional[c]) != 1 for c in affected):
        return None, 'Coastal cover or donor is disconnected'
    state = VacancyLayout(provisional, required, inland)
    present = {p for p, n in state.contacts.items() if n > 0}
    if wanted-present or present-required-actual:
        return None, 'Initial border regression'
    if state.ocean_edges(target):
        return None, 'Target still reaches the sea'
    wanted |= present & required
    distances = {p: min(abs(p[0]-q[0])+abs(p[1]-q[1]) for q in old)
                 for p in tiles[cover]-set(fixed_cells)}
    eligible = {p for p, d in distances.items() if d <= reach}
    transfers = []
    for _ in range(len(vacated)):
        offers = []
        for p in eligible & state.tiles[cover]:
            neighbours_at_p = [state.owners.get(q) for q in adjacent(p)]
            if donor in neighbours_at_p:
                offers.append((neighbours_at_p.count(cover)-neighbours_at_p.count(donor), distances[p], p))
        for _, _, p in sorted(offers):
            undo = state.update({p: donor})
            present = {pair for pair, n in state.contacts.items() if n > 0}
            if wanted-present or present-required-actual or connectivity(state.tiles[cover]) != 1:
                state.update(undo)
                continue
            transfers.append(p)
            break
        else:
            return None, 'Cannot balance the coastal cover locally'
    result = state.tiles
    assert set(state.owners) == set(owner)
    assert all(len(result[c]) == len(tiles[c]) for c in tiles)
    assert all(connectivity(result[c]) == 1 for c in affected)
    assert all(state.owners.get(p) == owner.get(p) for p in fixed_cells)
    before_coast = water_edges(tiles, owner, state.exterior)
    after_coast = water_edges(result, state.owners, state.exterior)
    if any(after_coast[c]['exterior_water_edges'] > before_coast[c]['exterior_water_edges'] for c in inland & set(tiles)):
        return None, 'An inland coast grew'
    if any(before_coast[c]['exterior_water_edges'] and not after_coast[c]['exterior_water_edges'] for c in affected-inland):
        return None, 'Coastal access lost'
    perimeter = sum(q not in result[c] for c in affected for p in result[c] for q in adjacent(p))
    old_perimeter = sum(q not in tiles[c] for c in affected for p in tiles[c] for q in adjacent(p))
    record = dict(target=target, donor=donor, cover=cover, shift=shift, retained_border_cells=retained,
                  cover_to_donor=transfers, changed_cells=sum(owner[p] != state.owners[p] for p in owner),
                  perimeter=perimeter, perimeter_change=perimeter-old_perimeter,
                  gained_true=sorted((present & required)-actual))
    return result, record


def run(inputs, layout, source_coasts, output, target, radius=4, reach=16):
    if output.exists() or min(radius, reach) < 1:
        raise ValueError('Use a new output and positive limits')
    rows, tiles, owner = load(inputs, layout)
    if any(len(tiles[c]) != int(rows[c]['tiles']) or connectivity(tiles[c]) != 1 for c in tiles):
        raise ValueError('Exact connected starting components required')
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}
    coast_rows = read_csv(source_coasts)
    if not set(tiles) <= {r['component_id'] for r in coast_rows}:
        raise ValueError('Missing source coast labels')
    inland = {r['component_id'] for r in coast_rows if int(r['uncovered_samples']) == 0}
    if target not in inland or target not in tiles:
        raise ValueError('Use a represented inland target')
    lakes = layout/'lake-cells.csv'
    fixed = {q for r in read_csv(lakes) for q in adjacent((int(r['x']), int(r['y'])))} if lakes.exists() else set()
    covers = {b if a == target else a for a, b in required if target in (a, b)}-inland
    attempts = []; best = None
    shifts = sorted(((dx, dy) for dx in range(-radius, radius+1) for dy in range(-radius, radius+1)
                     if 0 < dx*dx+dy*dy <= radius*radius), key=lambda p: (p[0]**2+p[1]**2, p))
    for shift in shifts:
        added = {(x+shift[0], y+shift[1]) for x, y in tiles[target]}-tiles[target]
        donors = {owner.get(p) for p in added}
        if len(donors) != 1 or None in donors:
            continue
        donor = next(iter(donors))
        if donor in inland:
            continue
        for cover in sorted(covers-{donor}):
            result, detail = trial(tiles, required, inland, target, donor, cover, shift, fixed, reach)
            attempts.append(dict(shift=shift, donor=donor, cover=cover, accepted=result is not None, detail=detail))
            print(json.dumps(attempts[-1]), flush=True)
            if result is not None:
                score = (detail['perimeter_change'], detail['changed_cells'], shift)
                if best is None or score < best[0]:
                    best = score, result, detail
    result = tiles if best is None else best[1]
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w', newline='') as stream:
        writer = csv.writer(stream); writer.writerow(['component_id', 'x', 'y'])
        for c, points in sorted(result.items()):
            writer.writerows((c, x, y) for x, y in sorted(points))
    for name in ('lake-cells.csv', 'lake-placement.json'):
        if (layout/name).exists():shutil.copyfile(layout/name, output/name)
    record = dict(target=target, radius=radius, reach=reach, selected=None if best is None else best[2], attempts=attempts,
                  inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', layout/'cells.csv', source_coasts]+([lakes] if lakes.exists() else [])},
                  script_sha256=digest(Path(__file__)), cells_sha256=digest(output/'cells.csv'),
                  limits=['A bounded three-component exchange, not a global fit. No connector tiles are added.',
                          'The land footprint, exact counts, lake shores, and all existing true borders stay fixed. No new false border pairs.',
                          'Coastal cover uses whole-component source coast labels, not coast orientation. Shapes need visual review. No production approval.'])
    (output/'inset.json').write_text(json.dumps(record, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=inland-three-component-exchange\ncounts=exact\napproval=none\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'source_coasts', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--target', required=True)
    parser.add_argument('--radius', type=int, default=4)
    parser.add_argument('--reach', type=int, default=16)
    run(**vars(parser.parse_args()))
