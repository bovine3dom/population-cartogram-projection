#!/usr/bin/env python3
"""Test count-preserving local lake insertion in an existing tile layout."""
import argparse
from collections import deque
import csv
import json
from pathlib import Path
import time

import numpy as np
from scipy.ndimage import binary_closing
from shapely import STRtree, transform
from shapely.geometry import shape

from compact_regions import adjacent
from geographic_baseline import grow
from lake_vacancies import VacancyLayout
from partition_land import contact_groups
from prepare_flow import equal_earth
from review_layout import load, read_csv, connectivity
from save_review import digest


def protected_bays(owners, radius):
    points = np.array(sorted(owners))
    lower, upper = points.min(axis=0)-radius-2, points.max(axis=0)+radius+2
    mask = np.zeros((upper[1]-lower[1]+1, upper[0]-lower[0]+1), dtype=bool)
    mask[points[:, 1]-lower[1], points[:, 0]-lower[0]] = True
    yy, xx = np.nonzero(binary_closing(mask, iterations=radius) & ~mask)
    return set(zip((xx+lower[0]).tolist(), (yy+lower[1]).tolist()))


def lake_order(points):
    centre = np.mean(sorted(points), axis=0)
    first = min(points, key=lambda p: (sum((p[k]-centre[k])**2 for k in [0, 1]), p))
    seen, queue, result = {first}, deque([first]), []
    while queue:
        p = queue.popleft()
        result.append(p)
        for q in adjacent(p):
            if q in points and q not in seen:
                seen.add(q)
                queue.append(q)
    if len(result) != len(points):
        raise ValueError('Disconnected water template')
    return result


def candidates(template, desired, owners, allowed, major, radius, limit):
    centre = np.mean(sorted(template), axis=0)
    origin = np.rint(desired-centre).astype(int)
    local_halo = {q for p in template for q in adjacent(p)}-template
    ranked = []
    for dx in range(-radius, radius+1):
        for dy in range(-radius, radius+1):
            shift = origin+np.array([dx, dy])
            points = {(x+int(shift[0]), y+int(shift[1])) for x, y in template}
            if any(owners.get(p) not in allowed for p in points):
                continue
            halo = {(x+int(shift[0]), y+int(shift[1])) for x, y in local_halo}
            shore = {owners.get(p) for p in halo}
            if not major <= shore or not shore <= allowed:
                continue
            ranked.append((dx*dx+dy*dy, dx, dy, points))
    chosen = []
    for _, dx, dy, points in sorted(ranked, key=lambda r: r[:3]):
        if any((dx-x)**2+(dy-y)**2 < 4 for x, y, _ in chosen):
            continue
        chosen.append((dx, dy, points))
        if len(chosen) == limit:
            break
    return [points for _, _, points in chosen]


def shore_is_valid(state, lakes):
    for lake in lakes:
        shore = {state.owners.get(q) for p in lake['points'] for q in adjacent(p) if q not in lake['points']}
        if not lake['major'] <= shore or not shore <= lake['allowed']:
            return False
    return True


def run(inputs, layout, polygons, guides, source_coasts, output, maximum_lakes=48,
        search_radius=24, placement_attempts=8, maximum_path_cost=96, path_attempts=64, bay_radius=8):
    if output.exists() or min(maximum_lakes, search_radius, placement_attempts, maximum_path_cost, path_attempts, bay_radius) < 1:
        raise ValueError('Use a new output and positive settings')
    rows, original, owners = load(inputs, layout)
    original_land = set(owners)
    if any(len(p) != int(rows[c]['tiles']) for c, p in original.items()):
        raise ValueError('Exact starting budgets required')
    source = {f['properties']['component_id']: transform(shape(f['geometry']), equal_earth)
              for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in original}
    guide_features = json.loads((guides/'geometry.geojson').read_text())['features']
    guide_shapes = {f['properties']['component_id']: shape(f['geometry']) for f in guide_features}
    water = {f['properties']['component_id']: f['properties']['name'] for f in guide_features if f['properties']['feature_kind'] == 'water'}
    budgets = {r['component_id']: int(r['tiles']) for r in read_csv(guides/'areas.csv')}
    if any(budgets.get(c) != len(p) for c, p in original.items()) or set(source) != set(original):
        raise ValueError('Guide and layout budgets or labels differ')
    source_record = json.loads((guides/'summary.json').read_text())
    excluded = {tuple(sorted((r['a'], r['b']))) for r in source_record['lake_separated_contacts']}
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}-excluded
    land = {c for pair in required for c in pair}
    fixed = set(original)-land
    coast_rows = read_csv(source_coasts)
    if {r['component_id'] for r in coast_rows} != set(original):
        raise ValueError('Source coast labels differ')
    landlocked = {r['component_id'] for r in coast_rows if int(r['uncovered_samples']) == 0}
    state = VacancyLayout(original, required, landlocked, protected_bays(owners, bay_radius), fixed)
    groups = contact_groups(required)
    initial_parts = [connectivity(set().union(*(original[c] for c in group))) for group in groups]
    labels = sorted(original)
    tree = STRtree([guide_shapes[c] for c in labels])
    reports, accepted = [], []
    started = time.monotonic()
    for c in sorted(water, key=lambda c: (-budgets[c], c))[:maximum_lakes]:
        geometry = guide_shapes[c]
        strip = geometry.boundary.buffer(.001)
        weights = {labels[int(i)]: guide_shapes[labels[int(i)]].boundary.intersection(strip).length
                   for i in tree.query(strip, predicate='intersects')}
        weights = {m: w for m, w in weights.items() if w > 0 and m not in fixed}
        total = sum(weights.values())
        allowed = {m for m, w in weights.items() if w >= .005*total}
        major = {m for m, w in weights.items() if w >= .05*total and len(original[m]) >= 2}
        report = dict(lake_id=c, name=water[c], requested=budgets[c], accepted=False,
                      source_shores=weights, allowed_shores=sorted(allowed), required_shores=sorted(major))
        reports.append(report)
        if not major:
            report['reason'] = 'No represented main shore'
            continue
        centre = np.array(geometry.centroid.coords[0])
        desired = np.average([np.mean(sorted(state.tiles[m]), axis=0)+(centre-np.array(source[m].centroid.coords[0]))*np.sqrt(len(state.tiles[m])/source[m].area) for m in sorted(allowed)],
                             axis=0, weights=[weights[m] for m in sorted(allowed)])
        template, _ = grow(geometry, budgets[c])
        placements = candidates(template, desired, state.owners, allowed, major, search_radius, placement_attempts)
        report.update(desired_centre=desired.tolist(), candidate_placements=len(placements), attempted_placements=0, trials=[])
        for points in placements:
            if not points <= original_land:
                continue
            report['attempted_placements'] += 1
            actions = []
            for point in lake_order(points):
                for path in state.paths(point, maximum_path_cost, path_attempts):
                    action = state.attempt(path)
                    if action is not None:
                        actions.append(action)
                        break
                else:
                    break
            lake = dict(points=points, major=major, allowed=allowed, lake_id=c, name=water[c])
            shores_valid = shore_is_valid(state, accepted+[lake])
            report['trials'].append(dict(inserted_cells=len(actions), shores_valid=shores_valid))
            valid = len(actions) == len(points) and shores_valid
            if valid:
                valid = all(connectivity(set().union(*(state.tiles[m] for m in group))) <= before for group, before in zip(groups, initial_parts))
            if valid:
                accepted.append(lake)
                report.update(accepted=True, centre=np.mean(sorted(points), axis=0).tolist(),
                              maximum_path_length=max(a['length'] for a in actions),
                              total_changed_cell_events=sum(a['changed_cells'] for a in actions))
                break
            for action in reversed(actions):
                state.undo(action)
        if not report['accepted']:
            report['reason'] = 'No complete placement passed counts, shores, connectivity, and border checks'
        print(json.dumps(report), flush=True)
    if any(len(state.tiles[c]) != len(original[c]) or connectivity(state.tiles[c]) != 1 for c in original):
        raise AssertionError('Component count or connectivity changed')
    lake_cells = set().union(*(lake['points'] for lake in accepted)) if accepted else set()
    if lake_cells & set(state.owners) or original_land-set(state.owners) != lake_cells:
        raise AssertionError('Unexplained empty land cells')
    if any(state.tiles[c] != original[c] for c in fixed):
        raise AssertionError('Fixed island moved')
    output.mkdir(parents=True)
    for name, header, records in [
        ('cells.csv', ['component_id', 'x', 'y'], ((c, x, y) for c, p in sorted(state.tiles.items()) for x, y in sorted(p))),
        ('lake-cells.csv', ['lake_id', 'name', 'x', 'y'], ((lake['lake_id'], lake['name'], x, y) for lake in accepted for x, y in sorted(lake['points'])))]:
        with (output/name).open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow(header)
            writer.writerows(records)
    report = dict(accepted_lakes=len(accepted), water_cells=len(lake_cells), requested_lakes=len(reports), lakes=reports,
        rejected_paths=dict(state.rejections), excluded_water_only_borders=sorted(excluded),
        maximum_lakes=maximum_lakes, search_radius=search_radius, placement_attempts=placement_attempts,
        maximum_path_cost=maximum_path_cost, path_attempts=path_attempts, bay_radius=bay_radius,
        protected_sea_cells=len(state.protected_sea), elapsed_seconds=time.monotonic()-started,
        inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', layout/'cells.csv', polygons, guides/'geometry.geojson', guides/'areas.csv', guides/'summary.json', source_coasts]},
        scripts={n: digest(Path(__file__).with_name(n)) for n in ['place_lake_regions.py', 'lake_vacancies.py', 'geographic_baseline.py', 'review_geography.py']},
        limits=['Experimental local insertion, not a population export. Every component keeps its original tile budget.',
                'Lake centres use approximate source-to-tile frames and represented shoreline constraints.',
                'Paths shift labels outward; no water channels or land connector paths remain after a move.',
                'Lake templates are connected, hole-free raster approximations. Lake-island population components remain unresolved.',
                'Failed lake placements are rolled back. Existing unclassified holes remain unchanged.',
                'Existing land borders are protected except recorded water-only contacts. No result is automatically approved.'])
    (output/'lake-placement.json').write_text(json.dumps(report, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=explicit-lake-vacancies\ncounts=exact\napproval=none\n')
    return dict(accepted_lakes=len(accepted), water_cells=len(lake_cells), attempted_lakes=len(reports))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'polygons', 'guides', 'source_coasts', 'output']:
        parser.add_argument(name, type=Path)
    for name, default in [('maximum-lakes', 48), ('search-radius', 24), ('placement-attempts', 8), ('maximum-path-cost', 96), ('path-attempts', 64), ('bay-radius', 8)]:
        parser.add_argument('--'+name, type=int, default=default)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
