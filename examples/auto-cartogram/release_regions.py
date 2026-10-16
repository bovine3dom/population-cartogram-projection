#!/usr/bin/env python3
"""Separate population-linked regions with unrestricted whole-region translations."""
import argparse
from collections import defaultdict
import csv
import json
from pathlib import Path

import networkx as nx
import numpy as np
from shapely import STRtree, distance, transform
from shapely.geometry import shape

from compact_regions import adjacent
from dock_true_borders import contacts
from prepare_flow import equal_earth
from review_layout import load, read_csv, connectivity
from save_review import digest
from shape_placement import place


def lake_links(water, owners):
    lakes = defaultdict(set)
    for r in water:
        lakes[r['lake_id']].add((int(r['x']), int(r['y'])))
    links = set()
    for points in lakes.values():
        shore = sorted({owners[q] for p in points for q in adjacent(p) if q in owners})
        if not shore:
            raise ValueError('A lake has no represented shore')
        links.update((shore[0], c) for c in shore[1:])
    return lakes, links


def communities(labels, hard, weighted, resolution):
    graph = nx.Graph()
    graph.add_nodes_from(sorted(labels))
    graph.add_edges_from(sorted(hard))
    atoms = sorted((sorted(g) for g in nx.connected_components(graph)), key=lambda g: g[0])
    atom_for = {c: i for i, g in enumerate(atoms) for c in g}
    contracted = nx.Graph()
    contracted.add_nodes_from(range(len(atoms)))
    for a, b, weight in sorted(weighted):
        i, j = atom_for[a], atom_for[b]
        if i != j and weight > 0:
            old = contracted.get_edge_data(i, j, {}).get('weight', 0.)
            contracted.add_edge(i, j, weight=old+weight)
    # Use one global weight scale; separate optimization of each continent
    # over-segments small networks such as Central and South America.
    groups = nx.community.greedy_modularity_communities(contracted, weight='weight', resolution=resolution) if contracted.number_of_edges() else [{i} for i in contracted]
    return sorted((sorted(c for i in g for c in atoms[i]) for g in groups), key=lambda g: g[0])


def fit_frame(source, target, weights):
    source, target, weights = map(np.asarray, (source, target, weights))
    a, b = np.average(source, axis=0, weights=weights), np.average(target, axis=0, weights=weights)
    denominator = np.sum(weights[:, None]*(source-a)**2)
    scale = float(np.sum(weights[:, None]*(source-a)*(target-b))/denominator) if denominator > 0 else 0
    if not np.isfinite(scale) or scale <= 0:
        raise ValueError('Invalid world frame')
    return a, b, scale


def run(inputs, layout, polygons, sources, audit, output, spacing=1.3, resolution=1., island_km=200., coast_km=500.):
    if output.exists() or not np.isfinite([spacing, resolution, island_km, coast_km]).all() or min(spacing, resolution, island_km, coast_km) <= 0:
        raise ValueError('Use a new output and positive settings')
    rows, tiles, owners = load(inputs, layout)
    if any(len(p) != int(rows[c]['tiles']) or connectivity(p) != 1 for c, p in tiles.items()):
        raise ValueError('Exact, connected starting components required')
    record = json.loads(audit.read_text())
    for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', sources]:
        if record['inputs'].get(str(p)) != digest(p):
            raise ValueError('Border audit inputs differ')
    source = {f['properties']['component_id']: transform(shape(f['geometry']), lambda xy: equal_earth(xy)/1000)
              for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in tiles}
    if set(source) != set(tiles):
        raise ValueError('Source geometry labels differ')
    population, sums = defaultdict(float), defaultdict(lambda: np.zeros(2))
    for r in read_csv(sources):
        c, mass = r['group_id'], float(r['value'])
        population[c] += mass
        sums[c] += mass*np.array([float(r['x']), float(r['y'])])
    if set(population) != set(tiles) or any(not np.isclose(population[c], float(rows[c]['group_population']), rtol=0, atol=.01) for c in tiles):
        raise ValueError('Source populations differ')
    sites = {c: sums[c]/population[c] for c in tiles}
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}
    mainland = {c for edge in required for c in edge}
    water = read_csv(layout/'lake-cells.csv')
    lakes, hard = lake_links(water, owners)
    # Build nearby island chains before choosing one coast for each whole chain.
    islands = sorted(set(tiles)-mainland)
    if islands:
        tree = STRtree([source[c] for c in islands])
        for i, c in enumerate(islands):
            for j in tree.query(source[c], predicate='dwithin', distance=island_km/6371):
                if i < j:
                    hard.add((c, islands[int(j)]))
    weighted = [(r['a'], r['b'], r.get('corridor_population', 0.)) for r in record['borders']]
    groups = communities(tiles, hard, weighted, resolution)
    group_for = {c: i for i, g in enumerate(groups) for c in g}
    coast_labels = sorted(mainland)
    attached = []
    for i, group in enumerate(groups):
        if any(c in mainland for c in group) or not coast_labels:
            continue
        distances = sum(population[c]*distance(source[c], [source[m] for m in coast_labels]) for c in group)/sum(population[c] for c in group)
        nearest = int(np.argmin(distances))
        if distances[nearest]*6371 <= coast_km:
            parent = group_for[coast_labels[nearest]]
            attached.append(dict(components=group, parent=coast_labels[nearest], distance_km=float(distances[nearest]*6371)))
            groups[parent].extend(group)
            groups[i] = []
    groups = sorted((sorted(g) for g in groups if g), key=lambda g: (-sum(len(tiles[c]) for c in g), g[0]))
    group_for = {c: i for i, g in enumerate(groups) for c in g}
    lake_group = {}
    for lake, points in lakes.items():
        neighbours = {group_for[owners[q]] for p in points for q in adjacent(p) if q in owners}
        if len(neighbours) != 1:
            raise AssertionError('Lake shores assigned to different regions')
        lake_group[lake] = neighbours.pop()
    labels = sorted(tiles)
    centres = {c: np.mean(sorted(tiles[c]), axis=0) for c in tiles}
    native_mean, tile_mean, scale = fit_frame([sites[c] for c in labels], [centres[c] for c in labels], [population[c] for c in labels])
    reserved, result, shifts, placed_centres, native_centres, moves = set(), {}, {}, {}, {}, []
    for i, group in enumerate(groups):
        weights = [population[c] for c in group]
        current = np.average([centres[c] for c in group], axis=0, weights=weights)
        native = np.average([sites[c] for c in group], axis=0, weights=weights)
        desired = tile_mean+(native-native_mean)*scale*spacing
        land = set().union(*(tiles[c] for c in group))
        lake_points = set().union(*(p for lake, p in lakes.items() if lake_group[lake] == i))
        footprint = land | lake_points
        lower, upper = np.full(2, -np.inf), np.full(2, np.inf)
        for j, other in native_centres.items():
            for axis in (0, 1):
                # Broad population-centre order, not a maximum separation.
                delta = native[axis]-other[axis]
                if delta > .08:
                    lower[axis] = max(lower[axis], placed_centres[j][axis]+1-current[axis])
                elif delta < -.08:
                    upper[axis] = min(upper[axis], placed_centres[j][axis]-1-current[axis])
        mean = np.mean(sorted(footprint), axis=0)
        try:
            placed = place(footprint, mean+desired-current, reserved, maximum_radius=256, translation_bounds=(lower, upper))
        except ValueError as error:
            raise ValueError(f'Region {i} ({group[0]}): no collision-free placement within the population-order constraints') from error
        shift = np.array(min(placed))-np.array(min(footprint))
        dx, dy = (int(v) for v in shift)
        for c in group:
            result[c] = {(x+dx, y+dy) for x, y in tiles[c]}
            shifts[c] = (dx, dy)
        if placed & reserved:
            raise AssertionError('Region collision')
        reserved |= placed | {q for p in placed for q in adjacent(p)}
        placed_centres[i], native_centres[i] = current+shift, native
        moves.append(dict(region=i, components=group, land_tiles=len(land), water_cells=len(lake_points),
                          dx=dx, dy=dy, target=desired.tolist(), actual=(current+shift).tolist(),
                          packing_shift=float(np.linalg.norm(current+shift-desired))))
    new_owners = {p: c for c, points in result.items() for p in points}
    if len(new_owners) != len(owners) or any(len(result[c]) != len(tiles[c]) for c in tiles):
        raise AssertionError('Population tile count changed')
    shifted_water = []
    for r in water:
        group = groups[lake_group[r['lake_id']]]
        dx, dy = shifts[group[0]]
        x, y = int(r['x'])+dx, int(r['y'])+dy
        if (x, y) in new_owners:
            raise AssertionError('Lake covered by land')
        for q, original_q in zip(adjacent((x, y)), adjacent((int(r['x']), int(r['y'])))):
            if owners.get(original_q) != new_owners.get(q):
                raise AssertionError('Lake shore changed')
        shifted_water.append(dict(r, x=x, y=y))
    before, after = contacts(owners), contacts(new_owners)
    if after-required-before:
        raise AssertionError('New false contact')
    internal = {edge for edge in before if group_for[edge[0]] == group_for[edge[1]]}
    if not internal <= after:
        raise AssertionError('Internal contact lost')
    audit_rows = {tuple(sorted((r['a'], r['b']))): r for r in record['borders']}
    lost = [dict(a=a, b=b, countries=rows[a]['country_id']+'–'+rows[b]['country_id'],
                 corridor_population=audit_rows[a, b].get('corridor_population'), sparse=audit_rows[a, b]['eligible'])
            for a, b in sorted((before & required)-after)]
    report = dict(spacing=spacing, resolution=resolution, island_km=island_km, coast_km=coast_km,
        regions=len(groups), moves=moves, attached_island_groups=attached, lost_borders=lost,
        lost_non_sparse_borders=sum(not r['sparse'] for r in lost), frame_scale=scale,
        inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', layout/'cells.csv', layout/'lake-cells.csv', polygons, sources, audit]},
        scripts={n: digest(Path(__file__).with_name(n)) for n in ['release_regions.py', 'shape_placement.py', 'dock_true_borders.py', 'prepare_flow.py']},
        networkx_version=nx.__version__, limits=[
            'Border-corridor population weights regional communities; inter-region dense contacts can also break and are reported.',
            'No maximum gap or old-centre anchor is imposed. Spacing scales the population-centre world frame.',
            'Every component is translated intact. This tests position and separation, not shape improvement.',
            'Lake shapes and immediate shore labels are preserved together. Nearby island chains choose a common coast.',
            'Greedy exact packing searches up to 256 tiles from each target translation; this is not a cap on inter-region gaps or movement from the input.',
            'Packing can displace regions from their targets or fail the order constraints. Geographic distances use an approximate Equal Earth plane.',
            'Blank separations are not geographic seas. No new population mapping or automatic approval.'])
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w', newline='') as stream:
        writer = csv.writer(stream, lineterminator='\n')
        writer.writerow(['component_id', 'x', 'y'])
        writer.writerows((c, x, y) for c, p in sorted(result.items()) for x, y in sorted(p))
    with (output/'lake-cells.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=['lake_id', 'name', 'x', 'y'], lineterminator='\n')
        writer.writeheader()
        writer.writerows(shifted_water)
    (output/'release.json').write_text(json.dumps(report, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=regional-release\ncounts=exact\napproval=none\n')
    return dict(regions=len(groups), lost_borders=len(lost), lost_non_sparse_borders=report['lost_non_sparse_borders'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'polygons', 'sources', 'audit', 'output']:
        parser.add_argument(name, type=Path)
    for name, default in [('spacing', 1.3), ('resolution', 1.), ('island-km', 200.), ('coast-km', 500.)]:
        parser.add_argument('--'+name, type=float, default=default)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
