#!/usr/bin/env python3
"""Fit fresh Mercator mainland shapes with soft population-weighted border anchors."""
import argparse
import csv
import html
import json
from pathlib import Path
import subprocess

import numpy as np
from scipy.optimize import LinearConstraint, minimize
from scipy.spatial import cKDTree
from shapely import transform, union_all
from shapely.geometry import shape
from shapely.ops import nearest_points

from dock_true_borders import contacts
from geographic_baseline import grow
from geographic_order import GeographicOrder
from review_layout import read_csv, connectivity
from review_projection_shapes import mercator, normalize, tile_geometry
from save_review import digest
from shape_placement import place
from smooth_raster_stress import SmoothRasterStress


def inverse_equal_earth(points):
    """Invert the radius-one projection used by the population source table."""
    points = np.asarray(points, dtype=float)
    x, y = points.T
    a, b, c, d = 1.340264, -.081106, .000893, .003796
    theta = y/a
    for _ in range(10):
        derivative = a+3*b*theta**2+7*c*theta**6+9*d*theta**8
        theta -= (theta*(a+b*theta**2+c*theta**6+d*theta**8)-y)/derivative
    lat = np.arcsin(np.clip(2*np.sin(theta)/np.sqrt(3), -1, 1))
    lon = x*3*(a+3*b*theta**2+7*c*theta**6+9*d*theta**8)/(2*np.sqrt(3)*np.cos(theta))
    return np.rad2deg(np.column_stack((lon, lat)))


def population_centres(sources, rows):
    selected = [r for r in read_csv(sources) if r['group_id'] in rows]
    lonlat = inverse_equal_earth([[float(r['x']), float(r['y'])] for r in selected])
    projected = mercator(lonlat)
    sums = {c: np.zeros(2) for c in rows}
    geographic = {c: np.zeros(2) for c in rows}
    masses = dict.fromkeys(rows, 0.)
    for r, p, ll in zip(selected, projected, lonlat):
        c, mass = r['group_id'], float(r['value'])
        sums[c] += mass*p
        geographic[c] += mass*ll
        masses[c] += mass
    if any(not np.isclose(masses[c], float(rows[c]['group_population']), rtol=0, atol=.01) for c in rows):
        raise ValueError('Population budgets differ')
    centres = {c: sums[c]/masses[c] for c in rows}
    order_rows = {c: dict(r, west=geographic[c][0]/masses[c], east=geographic[c][0]/masses[c],
                        south=geographic[c][1]/masses[c], north=geographic[c][1]/masses[c]) for c, r in rows.items()}
    return centres, order_rows


def border_energy(delta, weights, release):
    """Quadratic control or Cauchy loss; distant anchors need not pull harder."""
    squared = np.sum(delta*delta, axis=1)
    if release == 0:
        return .5*np.dot(weights, squared), weights[:, None]*delta
    scale = release*release
    return .5*np.dot(weights, scale*np.log1p(squared/scale)), (weights/(1+squared/scale))[:, None]*delta


class Fit(SmoothRasterStress):
    def objective(self, flat):
        value, gradient = super().objective(flat)
        points = flat.reshape(-1, 2)
        a, b = self.border_edges.T
        delta = points[b]-points[a]-self.border_targets
        cost, forces = border_energy(delta, self.border_weights, self.release)
        gradient = gradient.reshape(-1, 2)
        np.add.at(gradient, a, -forces)
        np.add.at(gradient, b, forces)
        return value+cost, gradient.ravel()


def select(rows, required, countries, neighbours):
    primary = {}
    for c, row in sorted(rows.items()):
        country = row['country_id']
        if country not in primary or int(row['tiles']) > int(rows[primary[country]]['tiles']):
            primary[country] = c
    chosen = {primary[c] for c in countries}
    eligible = set(primary.values())
    for _ in range(neighbours):
        chosen |= {b for a, b in required if a in chosen and b in eligible} | {a for a, b in required if b in chosen and a in eligible}
    return chosen


def pack(templates, desired, rows, required):
    """Keep broad source axis order during exact collision-free translation."""
    result, occupied, halos = {}, set(), {}
    native = {c: np.array([(float(r[lo])+float(r[hi]))/2 for lo, hi in [('west', 'east'), ('south', 'north')]])
              for c, r in rows.items()}
    for c in sorted(templates, key=lambda c: (-len(templates[c]), c)):
        centre = np.mean(sorted(templates[c]), axis=0)
        lower, upper = np.full(2, -np.inf), np.full(2, np.inf)
        blocked = set(occupied)
        for other, points in result.items():
            if tuple(sorted((c, other))) not in required:
                blocked.update(halos[other])
            delta = native[c]-native[other]
            target = np.mean(sorted(points), axis=0)
            for axis in range(2):
                if axis == 0 and abs(delta[axis]) > 180:
                    continue
                if delta[axis] > 3:
                    lower[axis] = max(lower[axis], target[axis]+1-centre[axis])
                elif delta[axis] < -3:
                    upper[axis] = min(upper[axis], target[axis]-1-centre[axis])
        result[c] = place(templates[c], desired[c], blocked, maximum_radius=128, translation_bounds=(lower, upper))
        occupied.update(result[c])
        halos[c] = {(x+dx, y+dy) for x, y in result[c] for dx, dy in [(1, 0), (-1, 0), (0, 1), (0, -1)]}
    return result


def pack_expanding(templates, desired, rows, required):
    centre = np.mean(list(desired.values()), axis=0)
    for expansion in [1., 1.25, 1.6, 2., 3., 4.]:
        try:
            return pack(templates, {c: centre+(p-centre)*expansion for c, p in desired.items()}, rows, required), expansion
        except ValueError:
            continue
    raise ValueError('Exact packing failed at all tested spacings')


def draw(rows, result, output, title):
    shapes = {c: tile_geometry(p) for c, p in result.items()}
    from shapely import affinity
    shapes = {c: affinity.translate(shapes[c], *np.mean(sorted(result[c]), axis=0)) for c in shapes}
    x0, y0, x1, y1 = union_all(list(shapes.values())).bounds
    scale = min(1740/(x1-x0+8), 900/(y1-y0+8))
    left = (1800-(x1-x0+8)*scale)/2
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="1100">',
             '<rect width="1800" height="1100" fill="#faf9f6"/>',
             f'<text x="30" y="38" font-family="sans-serif" font-size="26">{html.escape(title)}</text>',
             '<text x="30" y="70" font-family="sans-serif" font-size="17">Fresh Mercator shapes; exact component populations. Regional mainland test, not a world map.</text>',
             '<text x="30" y="97" font-family="sans-serif" font-size="17">No connector paths. Blank gaps need not be water. Named lakes and other islands are not included.</text>',
             f'<g transform="translate({left},1020) scale({scale}, {-scale}) translate({4-x0},{4-y0})">']
    palette = ['#d5a18c', '#9bce88', '#9a91d1', '#8dcbd0', '#d8cd8c', '#d48ea2', '#91b8ce']
    for i, (c, geometry) in enumerate(sorted(shapes.items())):
        parts.append(geometry.svg(fill_color=palette[i % len(palette)], opacity=1).replace('stroke-width="2.0"', 'stroke-width="0.12"'))
    parts.append('</g>')
    for c, g in shapes.items():
        p = g.representative_point()
        x, y = left+(p.x+4-x0)*scale, 1020-(p.y+4-y0)*scale
        parts.append(f'<text x="{x}" y="{y}" text-anchor="middle" font-family="sans-serif" font-size="14" paint-order="stroke" stroke="#faf9f6" stroke-width="2">{html.escape(rows[c]["country_id"])}</text>')
    parts.append('<text x="30" y="1070" font-family="sans-serif" font-size="15">Sources: Natural Earth outlines; existing Kontur population budgets. No production mapping changed.</text></svg>')
    (output/'review.svg').write_text('\n'.join(parts)+'\n')
    subprocess.run(['rsvg-convert', str(output/'review.svg'), '-o', str(output/'review.png')], check=True)


def run(inputs, polygons, audit, output, countries=('RUS', 'CHN', 'IND'), neighbours=1, release=8., iterations=1000, sources=None):
    if output.exists() or not np.isfinite(release) or release < 0 or neighbours < 0 or iterations < 1:
        raise ValueError('Use a new output and valid settings')
    rows = {r['component_id']: r for r in read_csv(inputs/'groups.csv') if int(r['tiles']) > 0}
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}
    selected = select(rows, required, countries, neighbours)
    rows = {c: rows[c] for c in sorted(selected)}
    required = {edge for edge in required if set(edge) <= selected}
    audit_record = json.loads(audit.read_text())
    for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv']:
        if audit_record['inputs'][str(p)] != digest(p):
            raise ValueError('Audit inputs differ')
    audited = {tuple(sorted((r['a'], r['b']))): r for r in audit_record['borders']}
    source = {f['properties']['component_id']: transform(shape(f['geometry']), mercator)
              for f in json.loads(polygons.read_text())['features'] if f['properties']['component_id'] in selected}
    if set(source) != selected:
        raise ValueError('Missing source geometry')
    templates = {c: grow(source[c], int(rows[c]['tiles']))[0] for c in source}
    scale = np.sqrt(sum(map(len, templates.values()))/sum(g.area for g in source.values()))
    centres = {c: np.array(g.centroid.coords[0])*scale for c, g in source.items()}
    if sources is not None:
        if audit_record['inputs'].get(str(sources)) != digest(sources):
            raise ValueError('Population source audit differs')
        centres, rows = population_centres(sources, rows)
        centres = {c: p*scale for c, p in centres.items()}
    state = Fit(templates, centres, required, collision=100., spring=1., anchor=.01, spatial=.03, gap=.6)
    state.order = GeographicOrder(state.labels, rows, margin=1., local_degrees=180.)
    state.order_weight = 5.
    edges, targets, populations = [], [], []
    for a, b in sorted(required):
        # Map the same source border position into each independently scaled shape.
        line = source[a].boundary.intersection(source[b].boundary)
        if line.length:
            point = line.interpolate(line.length/2)
            pa = pb = np.array(point.coords[0])
        else:
            pa, pb = [np.array(p.coords[0]) for p in nearest_points(source[a], source[b])]
        offsets = [(point-np.array(source[c].centroid.coords[0]))*np.sqrt(len(templates[c])/source[c].area)
                   for c, point in [(a, pa), (b, pb)]]
        # Growth shifts the raster centroid slightly away from the source centroid.
        offsets = [offset-np.mean(sorted(templates[c]), axis=0) for c, offset in zip([a, b], offsets)]
        edges.append((state.ids[a], state.ids[b]))
        targets.append(offsets[0]-offsets[1])
        populations.append(audited[a, b]['corridor_population'] or 0.)
    keep = [i for i, (a, b) in enumerate(state.edges) if (state.labels[a], state.labels[b]) not in required]
    state.edges, state.targets, state.weights = state.edges[keep], state.targets[keep], state.weights[keep]
    state.border_edges = np.array(edges, dtype=int).reshape(-1, 2)
    state.border_targets = np.array(targets).reshape(-1, 2)
    # Population changes border importance; it never changes tile budgets.
    state.border_weights = np.clip(np.log1p(np.array(populations)/100000), .05, 5.)
    state.release = release
    seed, seed_expansion = pack_expanding(templates, centres, rows, required)
    start = np.array([np.mean(sorted(seed[c]), axis=0) for c in state.labels])
    initial = state.objective(start.ravel())[0]
    order = state.order
    matrix = np.zeros((order.count, start.size))
    matrix[np.arange(order.count), order.a] = -order.sign
    matrix[np.arange(order.count), order.b] = order.sign
    fit = minimize(state.objective, start.ravel(), jac=True, method='SLSQP',
                   constraints=[LinearConstraint(matrix, order.margin, np.inf)],
                   options=dict(maxiter=iterations, ftol=1e-7))
    if not np.isfinite(fit.x).all() or fit.fun > initial+1e-6:
        raise ValueError('Invalid fit')
    positions = fit.x.reshape(-1, 2)
    result, packing_expansion = pack_expanding(templates, {c: positions[state.ids[c]] for c in templates}, rows, required)
    owners = {p: c for c, points in result.items() for p in points}
    actual = contacts(owners)
    if actual-required or len(owners) != sum(map(len, templates.values())):
        raise AssertionError('Collision or false contact')
    records = []
    for c, points in sorted(result.items()):
        shift = np.array(min(points))-np.array(min(templates[c]))
        if points != {tuple(np.array(p)+shift) for p in templates[c]} or connectivity(points) != 1:
            raise AssertionError('Template changed')
        guide = normalize(source[c], len(points))
        land = tile_geometry(points)
        records.append(dict(component=c, country=rows[c]['country_id'], tiles=len(points),
                            outline_iou=land.intersection(guide).area/land.union(guide).area,
                            packing_shift=float(np.linalg.norm(np.mean(sorted(points), axis=0)-positions[state.ids[c]]))))
    final_positions = np.array([np.mean(sorted(result[c]), axis=0) for c in state.labels])
    trees = {c: cKDTree(sorted(points)) for c, points in result.items()}
    border_records = [dict(a=a, b=b, countries=rows[a]['country_id']+'–'+rows[b]['country_id'],
                           nearest_tile_distance=float(trees[a].query(sorted(result[b]))[0].min()),
                           retained=(a, b) in actual, corridor_population=audited[a, b]['corridor_population'],
                           sparse=audited[a, b]['eligible']) for a, b in sorted(required)]
    report = dict(projection='Spherical Mercator; fresh independently scaled outlines', countries=list(countries), neighbours=neighbours,
                  position_basis='population centres' if sources else 'geometric centres',
                  release=release, border_weight='clip(log1p(corridor_population / 100000), 0.05, 5)',
                  tiles=len(owners), components=len(result), required_contacts=len(required), retained_contacts=len(actual),
                  lost_non_sparse=sum(not r['retained'] and not r['sparse'] for r in border_records),
                  seed_expansion=seed_expansion, packing_expansion=packing_expansion,
                  initial_energy=initial, continuous_energy=float(fit.fun), packed_energy=state.objective(final_positions.ravel())[0],
                  success=bool(fit.success), message=str(fit.message), iterations=int(fit.nit),
                  order_energy=state.order.objective(final_positions)[0], records=records, borders=border_records,
                  inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', polygons, audit]+([sources] if sources else [])},
                  scripts={n: digest(Path(__file__).with_name(n)) for n in ['fit_mercator_shapes.py', 'review_projection_shapes.py', 'geographic_baseline.py', 'smooth_raster_stress.py', 'raster_stress.py', 'shape_stress.py', 'shape_placement.py', 'geographic_order.py']},
                  limits=['Regional largest-component test only; no world fit or new population mapping.',
                          'Named lakes and secondary islands are not included. Not a replacement for the lake-aware map.',
                          'Fresh shapes remain rigid. Border losses are soft preferences, not permission restricted to sparse borders.',
                          'Final packing can change the continuous solution. Inspect order and packing shifts.',
                          'Blank gaps are not geographic seas. A smaller objective is not proof of better geography.'])
    output.mkdir(parents=True)
    for name, data in [('cells', result), ('templates', templates)]:
        with (output/(name+'.csv')).open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow(['component_id', 'x', 'y'])
            writer.writerows((c, x, y) for c, points in sorted(data.items()) for x, y in sorted(points))
    (output/'fit.json').write_text(json.dumps(report, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=mercator-regional-fit\ncounts=exact\napproval=none\n')
    title = f'Mercator shape-first fit: border release {release:g}'
    draw(rows, result, output, title if fit.success else title+'; solver did not converge')
    return {k: report[k] for k in ['tiles', 'components', 'retained_contacts', 'required_contacts', 'lost_non_sparse', 'success', 'iterations']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'polygons', 'audit', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--sources', type=Path, help='Population sources in radius-one Equal Earth coordinates')
    parser.add_argument('--countries', nargs='+', default=['RUS', 'CHN', 'IND'])
    parser.add_argument('--neighbours', type=int, default=1)
    parser.add_argument('--release', type=float, default=8.)
    parser.add_argument('--iterations', type=int, default=1000)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
