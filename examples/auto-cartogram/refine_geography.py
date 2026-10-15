#!/usr/bin/env python3
"""Refine an existing layout without splitting source-connected landmasses."""
import argparse
import csv
from collections import Counter
import json
import time
from pathlib import Path

import numpy as np
from scipy.ndimage import binary_closing, binary_dilation, distance_transform_edt
from shapely import affinity, contains_xy
from shapely.geometry import Polygon

from compact_regions import Deformation, adjacent
from geographic_baseline import simple_toggle
from partition_land import contact_groups
from review_flow import read_shapes
from review_layout import load, read_csv, connectivity
from save_review import digest


def raster(geometry, xx, yy, origin):
    mask = contains_xy(geometry, xx, yy)
    if not mask.any():
        p = geometry.representative_point()
        x, y = round(p.x)-origin[0], round(p.y)-origin[1]
        if not (0 <= y < mask.shape[0] and 0 <= x < mask.shape[1]):
            raise ValueError('Shape guide lies outside cost grid')
        mask[y, x] = True
    return mask


class GuardedDeformation(Deformation):
    def __init__(self, *args, groups, landlocked=(), coast_weight=0., preserve_contacts=False, **kwargs):
        super().__init__(*args, **kwargs)
        self.group_for = {c: i for i, group in enumerate(groups) for c in group}
        if set(self.group_for) != set(self.tiles):
            raise ValueError('Landmass labels differ')
        self.land = {i: set().union(*(self.tiles[c] for c in group)) for i, group in enumerate(groups)}
        if any(connectivity(points) != 1 for points in self.land.values()):
            raise ValueError('Starting source landmasses must be connected')
        self.landlocked = set(landlocked)
        self.coast_weight = coast_weight
        self.rejected_splits = 0
        self.rejected_contacts = 0
        self.contacts = Counter()
        for p, owner in self.owners.items():
            for q in adjacent(p):
                other = self.owners.get(q)
                if other is not None and other != owner and p < q:
                    self.contacts[tuple(sorted((owner, other)))] += 1
        self.preserve_contacts = preserve_contacts
        self.protected_contacts = self.required & {pair for pair, count in self.contacts.items() if count}

    def edge(self, a, b):
        value = super().edge(a, b)
        if (a is None and b in self.landlocked) or (b is None and a in self.landlocked):
            value += self.coast_weight
        return value

    def change(self, p, target):
        owner = self.owners.get(p)
        for q in adjacent(p):
            other = self.owners.get(q)
            if other is None:
                continue
            for c, delta in [(owner, -1), (target, 1)]:
                if c is not None and c != other:
                    self.contacts[tuple(sorted((c, other)))] += delta
        super().change(p, target)
        a, b = self.group_for.get(owner), self.group_for.get(target)
        if a != b:
            if a is not None:
                self.land[a].remove(p)
            if b is not None:
                self.land[b].add(p)
        return owner

    def exchange(self, p, q):
        a, b = self.owners.get(p), self.owners.get(q)
        if a == b or not self.possible(p, b):
            return False
        # Most removals have a local topology certificate. Only ambiguous
        # removals need a complete landmass check after the paired exchange.
        check = set()
        def mark(point, owner, target):
            group = self.group_for.get(owner)
            if group is not None and group != self.group_for.get(target) and not simple_toggle(self.land[group], point):
                check.add(group)
        mark(p, a, b)
        first = self.delta(p, b)
        self.change(p, b)
        if self.possible(q, a) and first+self.delta(q, a) < -1e-8:
            mark(q, b, a)
            self.change(q, a)
            lost_contact = self.preserve_contacts and any(self.contacts[pair] == 0 for pair in self.protected_contacts)
            if lost_contact:
                self.rejected_contacts += 1
            elif all(connectivity(self.land[g]) == 1 for g in check):
                if self.preserve_contacts:
                    self.protected_contacts |= self.required & {pair for pair, count in self.contacts.items() if count}
                return True
            else:
                self.rejected_splits += 1
            self.change(q, b)
        self.change(p, a)
        return False


def run(inputs, layout, flow_record, source_coasts, output, rounds=1000, choices=16,
        guide=1., coast_weight=32., minimum_landmass_tiles=550, checkpoint_rounds=25, preserve_contacts=False,
        water_weight=0., water_radius=8, water_margin=1, native_shape_weight=0.):
    if output.exists() or min(rounds, choices, minimum_landmass_tiles, checkpoint_rounds) < 1 or not np.isfinite([guide, coast_weight]).all() or min(guide, coast_weight) < 0:
        raise ValueError('Use a new output and valid settings')
    if not np.isfinite([water_weight, native_shape_weight]).all() or min(water_weight, native_shape_weight) < 0 or water_radius < 1 or water_margin < 0:
        raise ValueError('Invalid water cost settings')
    rows, tiles, owner = load(inputs, layout)
    if any(len(tiles[c]) != int(rows[c]['tiles']) for c in tiles):
        raise ValueError('Exact initial budgets required')
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}
    groups = contact_groups(sorted(required))
    grouped = {c for group in groups for c in group}
    groups += [[c] for c in sorted(set(tiles)-grouped)]
    fixed = {c for group in groups if len(group) == 1 or sum(len(tiles[m]) for m in group) < minimum_landmass_tiles for c in group}
    coast_rows = read_csv(source_coasts)
    if len(coast_rows) != len(tiles) or {r['component_id'] for r in coast_rows} != set(tiles):
        raise ValueError('Source coast labels differ')
    landlocked = {r['component_id'] for r in coast_rows if int(r['uncovered_samples']) == 0}
    record = json.loads(flow_record.read_text())
    geometry_file = Path(record['flow_geometry'])
    if digest(geometry_file) != record['inputs'][str(geometry_file)]:
        raise ValueError('Flow geometry changed')
    geometry = read_shapes(geometry_file)
    if set(tiles)-fixed-set(geometry):
        raise ValueError('Missing movable flow geometry')
    points = np.asarray(sorted(owner))
    lower, upper = points.min(axis=0)-32, points.max(axis=0)+32
    origin = tuple(lower)
    yy, xx = np.mgrid[lower[1]:upper[1]+1, lower[0]:upper[0]+1]
    zero = np.zeros(xx.shape, dtype=np.float32)
    costs = {c: zero for c in fixed}
    raw_land = np.zeros(xx.shape, dtype=bool)
    for c in sorted(set(tiles)-fixed):
        g = affinity.scale(geometry[c], record['flow']['x_scale'], record['flow']['y_scale'], origin=(0, 0))
        mask = raster(g, xx, yy, origin)
        raw_land |= mask
        costs[c] = (guide*distance_transform_edt(~mask)**2).astype(np.float32)
    protected_water = binary_closing(raw_land, iterations=water_radius) & ~raw_land
    if water_margin:
        protected_water = binary_dilation(protected_water, iterations=water_margin)
    for c in set(tiles)-fixed:
        costs[c] += water_weight*protected_water
    if native_shape_weight:
        lines = (inputs/'validated.wkt').read_text().splitlines()
        native = {lines[i].split('\t')[1]: Polygon([tuple(map(float, p.split())) for p in lines[i+1].split('\t')]) for i in range(2, len(lines), 3)}
        for c in set(tiles)-fixed:
            g = native[c]
            centre = np.mean(list(tiles[c]), axis=0)
            scale = np.sqrt(len(tiles[c])/g.area)
            g = affinity.translate(affinity.scale(g, scale, scale, origin=(g.centroid.x, g.centroid.y)), centre[0]-g.centroid.x, centre[1]-g.centroid.y)
            mask = raster(g, xx, yy, origin)
            costs[c] += (native_shape_weight*distance_transform_edt(~mask)**2/np.sqrt(len(tiles[c]))).astype(np.float32)
    state = GuardedDeformation(tiles, required, costs, origin, perimeter=1., false_contact=16.,
                               allow_holes=True, groups=groups, landlocked=landlocked, coast_weight=coast_weight, preserve_contacts=preserve_contacts)
    state.fixed = fixed
    output.mkdir(parents=True)
    started = time.monotonic()
    history = []
    provenance = dict(method='Paired tile exchanges with component topology checks and source-landmass connectivity guards',
        rounds=rounds, choices=choices, guide=guide, coast_weight=coast_weight, preserve_contacts=preserve_contacts,
        minimum_landmass_tiles=minimum_landmass_tiles, checkpoint_rounds=checkpoint_rounds,
        water_weight=water_weight, water_radius=water_radius, water_margin=water_margin, native_shape_weight=native_shape_weight,
        protected_water_cells=int(protected_water.sum()),
        inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv', inputs/'validated.wkt', layout/'cells.csv', flow_record, geometry_file, source_coasts]},
        scripts={n: digest(Path(__file__).with_name(n)) for n in ['refine_geography.py', 'compact_regions.py', 'geographic_baseline.py', 'partition_land.py']},
        limits=['Local search can stop before water access improves.', 'No required-border paths are constructed.',
                'The coast cost uses finite source samples and does not distinguish enclosed water.',
                'Source landmass connectivity is required. Optional contact guards retain existing true borders, not their positions.',
                'Water costs use concavities in the raw flow raster, not named seas or a verified source-water topology.',
                'Existing shape holes are allowed. No candidate is automatically approved.'])
    (output/'inputs.json').write_text(json.dumps(provenance, indent=2)+'\n')
    def save(name):
        target = output/name
        target.mkdir()
        if any(len(state.tiles[c]) != len(tiles[c]) or connectivity(state.tiles[c]) != 1 for c in tiles):
            raise AssertionError('Component budget or connectivity changed')
        if any(connectivity(p) != 1 for p in state.land.values()):
            raise AssertionError('Landmass split')
        with (target/'cells.csv').open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow(['component_id', 'x', 'y'])
            for c, cells in sorted(state.tiles.items()):
                writer.writerows((c, x, y) for x, y in sorted(cells))
        (target/'complete.txt').write_text('mode=guarded-geography\ncounts=exact\nsource-landmasses=connected\napproval=none\n')
        (target/'refinement.json').write_text(json.dumps(dict(history=history, rejected_splits=state.rejected_splits, rejected_contacts=state.rejected_contacts,
            elapsed_seconds=time.monotonic()-started, cells_sha256=digest(target/'cells.csv')), indent=2)+'\n')
    save('initial')
    previous = state.energy()
    for iteration in range(1, rounds+1):
        changed = state.step(choices)
        energy = state.energy()
        if energy > previous+1e-6:
            raise AssertionError('Energy increased')
        previous = energy
        history.append(dict(round=iteration, changed=changed, energy=energy, rejected_splits=state.rejected_splits, rejected_contacts=state.rejected_contacts))
        print(json.dumps(history[-1]), flush=True)
        if iteration % checkpoint_rounds == 0:
            save(f'round-{iteration}')
        if not changed:
            break
    save('final')
    return history[-1]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'flow_record', 'source_coasts', 'output']:
        parser.add_argument(name, type=Path)
    for name, default in [('rounds', 1000), ('choices', 16), ('minimum-landmass-tiles', 550), ('checkpoint-rounds', 25), ('water-radius', 8), ('water-margin', 1)]:
        parser.add_argument('--'+name, type=int, default=default)
    parser.add_argument('--native-shape-weight', type=float, default=0.)
    parser.add_argument('--water-weight', type=float, default=0.)
    parser.add_argument('--preserve-contacts', action='store_true')
    parser.add_argument('--guide', type=float, default=1.)
    parser.add_argument('--coast-weight', type=float, default=32.)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
