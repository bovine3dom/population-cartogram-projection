#!/usr/bin/env python3
"""Test joint island translations from several nearby source coasts."""
import argparse
import csv
import json
from pathlib import Path

import numpy as np
from scipy.sparse import lil_matrix
from scipy.sparse.linalg import lsqr
from shapely import STRtree, transform, union_all
from shapely.geometry import Point, shape
from shapely.ops import nearest_points

from coast_anchors import template_point
from partition_land import contact_groups
from place_islands import tile_contacts
from prepare_flow import equal_earth
from review_layout import load, read_csv, NEIGHBOURS
from save_review import digest
from shape_placement import place


def coast_edges(source, neighbours, fixed=frozenset()):
    labels = sorted(source)
    tree = STRtree([source[c] for c in labels])
    pairs = set()
    distances = {}
    for c in labels:
        if c in fixed:
            continue
        # Small coastal islets must not displace all regional anchors from
        # a large island's neighbour list. Smaller bodies still add edges.
        eligible = {b for b in labels if b != c and source[b].area >= .25*source[c].area}
        radius = .001
        nearby = []
        while len(nearby) < min(neighbours, len(eligible)):
            candidates = tree.query(source[c], predicate='dwithin', distance=radius)
            nearby = []
            for i in candidates:
                b = labels[i]
                if b not in eligible:
                    continue
                key = tuple(sorted((c, b)))
                if key not in distances:
                    distances[key] = source[c].distance(source[b])
                nearby.append((distances[key], b))
            nearby.sort()
            radius *= 2
        pairs.update(tuple(sorted((c, b))) for _, b in nearby[:neighbours])
    return sorted(pairs)


def solve_translations(labels, fixed, edges, retention):
    indices = {c: i for i, c in enumerate(c for c in labels if c not in fixed)}
    matrix = lil_matrix((len(edges)+len(indices), len(indices)))
    rhs = np.zeros((matrix.shape[0], 2))
    for i, edge in enumerate(edges):
        weight = np.sqrt(edge['weight'])
        for c, sign in [(edge['a'], -1), (edge['b'], 1)]:
            if c in indices:
                matrix[i, indices[c]] = sign*weight
        rhs[i] = np.asarray(edge['shift_difference'])*weight
    for c, j in indices.items():
        matrix[len(edges)+j, j] = np.sqrt(retention)
    result = {c: np.zeros(2) for c in labels}
    if indices:
        matrix = matrix.tocsr()
        fits = [lsqr(matrix, rhs[:, axis], atol=1e-9, btol=1e-9) for axis in range(2)]
        if any(fit[1] not in (0, 1, 2) for fit in fits):
            raise ValueError('Translation solve did not converge')
        for c, j in indices.items():
            result[c] = np.array([fit[0][j] for fit in fits])
    return result


def mapped_coast_point(point, members, source, tiles, transport=None):
    """Map through the nearest component, not through a whole continent."""
    p = Point(point)
    member = min(members, key=lambda c: (source[c].distance(p), c))
    if transport is not None:
        return transport.point(member, point)
    cells = np.asarray(sorted(tiles[member]))
    centre = cells.mean(axis=0)
    factor = np.sqrt(len(cells)/source[member].area)
    offset = (point-np.asarray(source[member].centroid.coords[0]))*factor
    return centre+template_point(cells-centre, offset)


def order_constraints(native, bodies, pairs):
    """Keep source centre orders that the baseline already preserves."""
    centres = {c: np.mean(list(p), axis=0) for c, p in bodies.items()}
    result = []
    for a, b in pairs:
        ca, cb = native[a].centroid, native[b].centroid
        for axis, delta in enumerate([cb.x-ca.x, cb.y-ca.y]):
            if abs(delta) < 3 or (axis == 0 and abs(delta) > 180):
                continue
            left, right = (a, b) if delta > 0 else (b, a)
            bound = int(np.floor(centres[right][axis]-centres[left][axis]-1))
            if bound >= 0:
                result.append(dict(a=left, b=right, axis=axis, bound=bound))
    return result


def run(inputs, layout, polygons, output, neighbours=4, retention=.1,
        maximum_area_fraction=.03, shift_scale=3., centroid_weight=0., preserve_order=False, transport_root=None, transport_layout=None):
    if output.exists():
        raise ValueError('Use a new output')
    if neighbours < 1 or not np.isfinite([retention, maximum_area_fraction, shift_scale, centroid_weight]).all() or retention <= 0 or not 0 < maximum_area_fraction < 1 or shift_scale <= 0 or not 0 <= centroid_weight <= 1:
        raise ValueError('Invalid settings')
    rows, tiles, owner = load(inputs, layout)
    if any(len(tiles[c]) != int(rows[c]['tiles']) for c in tiles):
        raise ValueError('Exact tile budgets required')
    if transport_layout is not None and transport_root is None:
        raise ValueError('A reference layout requires a transport root')
    transport = None
    if transport_root is not None:
        from transport_coast_frames import TransportCoastFrames
        reference = load(inputs, transport_layout)[1] if transport_layout else None
        transport = TransportCoastFrames(transport_root, tiles, reference)
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}
    before = tile_contacts(owner)
    groups = contact_groups(sorted(required | before))
    grouped = {c for group in groups for c in group}
    groups += [[c] for c in sorted(set(tiles)-grouped)]
    members = {min(group): sorted(group) for group in groups}
    bodies = {c: set().union(*(tiles[m] for m in group)) for c, group in members.items()}
    features = json.loads(polygons.read_text())['features']
    native = {f['properties']['component_id']: shape(f['geometry'])
              for f in features if f['properties']['component_id'] in tiles}
    component_source = {c: transform(g, lambda xy: equal_earth(xy)/1000).simplify(1e-5) for c, g in native.items()}
    native = {c: union_all([native[m] for m in group]) for c, group in members.items()}
    source = {c: union_all([component_source[m] for m in group]) for c, group in members.items()}
    area = sum(g.area for g in source.values())
    fixed = {c for c in bodies if source[c].area >= maximum_area_fraction*area}
    if not fixed:
        raise ValueError('No fixed landmass')
    centres = {c: np.mean(list(p), axis=0) for c, p in bodies.items()}
    native_centres = {c: np.array(g.centroid.coords[0]) for c, g in source.items()}
    total = sum(map(len, bodies.values()))
    scale, ocean_length = np.sqrt(total/area), .1*np.sqrt(total)
    edges = []
    pairs = coast_edges(source, neighbours, fixed)
    constraints = order_constraints(native, bodies, pairs) if preserve_order else []
    for a, b in pairs:
        if a in fixed and b in fixed:
            continue
        pa, pb = [np.array(p.coords[0]) for p in nearest_points(source[a], source[b])]
        gap = (pb-pa)*scale
        length = np.linalg.norm(gap)
        if length:
            gap *= ocean_length*np.arcsinh(length/ocean_length)/length
        oa = mapped_coast_point(pa, members[a], component_source, tiles, transport)-centres[a]
        ob = mapped_coast_point(pb, members[b], component_source, tiles, transport)-centres[b]
        coast_target = oa-ob+gap
        # A second target uses the regional centre direction. Its scale comes
        # from both bodies, rather than from the island alone.
        pair_scale = np.sqrt((len(bodies[a])+len(bodies[b]))/(source[a].area+source[b].area))
        centre_target = (native_centres[b]-native_centres[a])*pair_scale
        target = (1-centroid_weight)*coast_target+centroid_weight*centre_target
        weight = 1/(1+length)**2
        edges.append(dict(a=a, b=b, weight=weight,
                          shift_difference=(target-(centres[b]-centres[a])).tolist()))
    shifts = solve_translations(sorted(bodies), fixed, edges, retention)
    placed = dict(bodies)
    def halo(points):
        return points | {(x+dx, y+dy) for x, y in points for dx, dy in NEIGHBOURS}
    packing = []
    for c in sorted(set(bodies)-fixed, key=lambda c: (-len(bodies[c]), c)):
        # Reserve every other body's current cells. An island cannot consume
        # the only feasible space of a smaller island that is not yet placed.
        blocked = halo(set().union(*(p for other, p in placed.items() if other != c)))
        limit = int(np.ceil(shift_scale*np.sqrt(len(bodies[c]))))
        bounds = np.array([[-limit, -limit], [limit, limit]])
        for edge in constraints:
            a, b, axis, bound = (edge[k] for k in ['a', 'b', 'axis', 'bound'])
            if c == a:
                other_shift = min(placed[b])[axis]-min(bodies[b])[axis]
                bounds[1, axis] = min(bounds[1, axis], other_shift+bound)
            elif c == b:
                other_shift = min(placed[a])[axis]-min(bodies[a])[axis]
                bounds[0, axis] = max(bounds[0, axis], other_shift-bound)
        placed[c] = place(bodies[c], centres[c]+shifts[c], blocked,
                          maximum_radius=512, translation_bounds=bounds)
        shift = np.asarray(min(placed[c]))-np.asarray(min(bodies[c]))
        if {(x+int(shift[0]), y+int(shift[1])) for x, y in bodies[c]} != placed[c]:
            raise AssertionError('Body shape changed')
        packing.append(dict(body=c, proposed=shifts[c].tolist(), accepted=shift.tolist()))
    result = {}
    for c, group in members.items():
        dx, dy = np.asarray(min(placed[c]))-np.asarray(min(bodies[c]))
        for m in group:
            result[m] = {(x+int(dx), y+int(dy)) for x, y in tiles[m]}
    after_owner = {p: c for c, points in result.items() for p in points}
    if len(after_owner) != total or tile_contacts(after_owner) != before:
        raise AssertionError('Overlap or contacts changed')
    report = dict(neighbours=neighbours, retention=retention, maximum_area_fraction=maximum_area_fraction,
        shift_scale=shift_scale, centroid_weight=centroid_weight, source_simplification=1e-5,
        anchor_minimum_relative_area=.25, coast_frame='nearest represented component',
        transport_root=str(transport_root) if transport_root else None,
        transport_layout=str(transport_layout) if transport_layout else None,
        transport_inputs=transport.hashes if transport else None,
        members=members, fixed=sorted(fixed),
        edges=edges, preserve_order=preserve_order, order_constraints=constraints,
        packing=packing, moved_components=sum(result[c] != tiles[c] for c in tiles),
        inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', layout/'cells.csv', polygons]+([transport_layout/'cells.csv'] if transport_layout else [])},
        scripts={n: digest(Path(__file__).with_name(n)) for n in ['place_coast_graph.py', 'coast_anchors.py', 'transport_coast_frames.py', 'partition_land.py', 'place_islands.py', 'prepare_flow.py', 'shape_placement.py']},
        limits=['Experimental translations only. Fixed mainland shapes do not change.',
                'Nearest coast targets approximate source-to-tile correspondence.',
                'A different transport reference is aligned by component-centroid translation and current-coast snapping. No population weights are transferred.',
                'Area threshold selects fixed bodies; it is not an island classification.',
                'Packing is sequential and can change the joint solution.',
                'Equal Earth distances and centroids can be misleading near the antimeridian.'])
    output.mkdir(parents=True)
    with (output/'cells.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['component_id', 'x', 'y'])
        for c, points in sorted(result.items()):
            writer.writerows((c, x, y) for x, y in sorted(points))
    (output/'coast-graph.json').write_text(json.dumps(report, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=coast-graph\ncounts=exact\ncontacts=unchanged\n')
    return dict(moved_components=report['moved_components'], bodies=len(bodies), fixed=len(fixed))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'polygons', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--neighbours', type=int, default=4)
    parser.add_argument('--preserve-order', action='store_true')
    parser.add_argument('--transport-root', type=Path, help='Use a checked transport map for local coast positions')
    parser.add_argument('--transport-layout', type=Path, help='Original layout for a transport-based placement guide on a changed layout')
    for name, default in [('retention', .1), ('maximum-area-fraction', .03), ('shift-scale', 3.), ('centroid-weight', 0.)]:
        parser.add_argument('--'+name, type=float, default=default)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
