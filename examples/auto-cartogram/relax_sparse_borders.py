#!/usr/bin/env python3
"""Test bounded separation of low-density borders with exact component budgets."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import time

import numpy as np
from scipy.ndimage import binary_dilation, distance_transform_edt
from scipy.spatial import cKDTree
from shapely import affinity
from shapely.geometry import Polygon

from compact_regions import adjacent
from lake_vacancies import pair
from place_lake_regions import protected_bays
from refine_geography import GuardedDeformation, raster
from review_layout import load, read_csv, connectivity
from save_review import digest


def gap_distance(a, b):
    """Return the nearest centre distance in the grid's Chebyshev metric."""
    return float(cKDTree(sorted(a)).query(sorted(b), p=np.inf)[0].min())


class SparseDeformation(GuardedDeformation):
    def __init__(self, tiles, required, costs, origin, soft, fixed, locked, protected_water,
                 gap_band, maximum_gap=3, gap_budget=300, **kwargs):
        # Each component remains connected. Source landmasses may now split.
        super().__init__(tiles, required, costs, origin, groups=[[c] for c in tiles],
                         preserve_contacts=True, allow_holes=True, **kwargs)
        self.soft = set(soft)
        self.fixed = set(fixed)
        self.locked = set(locked)
        self.protected_water = set(protected_water)
        self.gap_band = set(gap_band)
        self.original_land = set(self.owners)
        self.interior = {p for p in self.owners if all(q in self.owners for q in adjacent(p))}
        self.gaps = set()
        self.gap_budget = gap_budget
        self.gap_limits = {key: max(maximum_gap+1, gap_distance(self.tiles[key[0]], self.tiles[key[1]])) for key in self.soft}
        self.protected_contacts -= self.soft
        self.rejected_policy = 0

    def possible(self, p, target):
        if p in self.locked or (target is not None and p in self.protected_water):
            return False
        if target is None and p in self.interior and p not in self.gap_band:
            return False
        return super().possible(p, target)

    def change(self, p, target):
        owner = super().change(p, target)
        if hasattr(self, 'gaps') and p in self.interior:
            if target is None:
                self.gaps.add(p)
            else:
                self.gaps.discard(p)
        return owner

    def exchange(self, p, q):
        a, b = self.owners.get(p), self.owners.get(q)
        protected = set(self.protected_contacts)
        false_before = {k for k, n in self.contacts.items() if n > 0 and k not in self.required}
        if not super().exchange(p, q):
            return False
        # The base guard latches newly formed true contacts; sparse ones stay optional.
        self.protected_contacts -= self.soft
        false_after = {k for k, n in self.contacts.items() if n > 0 and k not in self.required}
        valid = false_after <= false_before and len(self.gaps) <= self.gap_budget
        if valid:
            valid = all(gap_distance(self.tiles[x], self.tiles[y]) <= limit
                        for (x, y), limit in self.gap_limits.items() if a in (x, y) or b in (x, y))
        if valid:
            return True
        self.change(q, b)
        self.change(p, a)
        self.protected_contacts = protected
        self.rejected_policy += 1
        return False


def run(inputs, layout, audit, output, rounds=100, choices=8, maximum_gap=3, gap_budget=300,
        guide=4., gap_cost=4., preserve_all=False):
    if output.exists() or min(rounds, choices, maximum_gap, gap_budget) < 1 or not np.isfinite([guide, gap_cost]).all() or min(guide, gap_cost) < 0:
        raise ValueError('Use a new output and valid settings')
    rows, tiles, owners = load(inputs, layout)
    if any(len(p) != int(rows[c]['tiles']) for c, p in tiles.items()):
        raise ValueError('Exact starting budgets required')
    population = json.loads(audit.read_text())
    for path in [inputs/'groups.csv', inputs/'geographic-contacts.csv']:
        if population['inputs'].get(str(path)) != digest(path):
            raise ValueError('Population audit uses different inputs')
    required = {tuple(sorted((r['a'], r['b']))) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented'] == 'true'}
    eligible = {tuple(sorted((r['a'], r['b']))) for r in population['borders'] if r['eligible']}
    if not eligible <= required:
        raise ValueError('Unknown optional border')
    movable = {c for key in eligible for c in key if len(tiles[c]) >= 16}
    fixed = set(tiles)-movable
    soft = set() if preserve_all else eligible
    points = np.array(sorted(owners))
    lower, upper = points.min(axis=0)-16, points.max(axis=0)+16
    origin = tuple(int(v) for v in lower)
    yy, xx = np.mgrid[lower[1]:upper[1]+1, lower[0]:upper[0]+1]
    mask = np.zeros(xx.shape, dtype=bool)
    mask[points[:, 1]-lower[1], points[:, 0]-lower[0]] = True
    seam = np.zeros_like(mask)
    for p, c in owners.items():
        if any(pair(c, owners.get(q)) in eligible for q in adjacent(p)):
            seam[p[1]-lower[1], p[0]-lower[0]] = True
    seam = binary_dilation(seam, iterations=maximum_gap)
    ys, xs = np.nonzero(seam & mask)
    gap_band = set(zip((xs+lower[0]).tolist(), (ys+lower[1]).tolist()))
    lake_file = layout/'lake-cells.csv'
    water_rows = read_csv(lake_file) if lake_file.exists() else []
    lakes = {(int(r['x']), int(r['y'])) for r in water_rows}
    if lakes & set(owners):
        raise ValueError('Lake cells overlap population')
    locked = lakes | {q for p in lakes for q in adjacent(p)}
    # Keep existing internal holes and concave seas empty. No new named-water claims.
    from review_geography import exterior_water
    exterior = exterior_water(owners)
    all_empty = {(int(x), int(y)) for x, y in zip(xx[~mask], yy[~mask])}
    protected_water = protected_bays(owners, 8) | (all_empty-exterior)
    interior_mask = np.zeros_like(mask)
    for p in owners:
        if all(q in owners for q in adjacent(p)):
            interior_mask[p[1]-lower[1], p[0]-lower[0]] = True
    # Removing interior land pays a gap cost. Outside expansion gets no reward.
    penalty = -gap_cost*interior_mask.astype(np.float32)
    lines = (inputs/'validated.wkt').read_text().splitlines()
    native = {lines[i].split('\t')[1]: Polygon([tuple(map(float, p.split())) for p in lines[i+1].split('\t')]) for i in range(2, len(lines), 3)}
    zero = np.zeros_like(penalty)
    costs = {c: zero for c in fixed}
    for c in sorted(movable):
        g = native[c]
        centre = np.mean(sorted(tiles[c]), axis=0)
        scale = np.sqrt(len(tiles[c])/g.area)
        g = affinity.translate(affinity.scale(g, scale, scale, origin=g.centroid), centre[0]-g.centroid.x, centre[1]-g.centroid.y)
        target = raster(g, xx, yy, origin)
        costs[c] = (guide*distance_transform_edt(~target)**2/np.sqrt(len(tiles[c]))+penalty).astype(np.float32)
    state = SparseDeformation(tiles, required, costs, origin, soft, fixed, locked, protected_water, gap_band,
                              maximum_gap, gap_budget, perimeter=1., false_contact=16.)
    initial_contacts = {k for k, n in state.contacts.items() if n > 0}
    initial_energy = state.energy()
    history, previous = [], initial_energy
    started = time.monotonic()
    output.mkdir(parents=True)
    for turn in range(1, rounds+1):
        changed = state.step(choices)
        energy = state.energy()
        if energy > previous+1e-6:
            raise AssertionError('Energy increased')
        previous = energy
        history.append(dict(round=turn, changed=changed, energy=energy, interior_gap_cells=len(state.gaps)))
        print(json.dumps(history[-1]), flush=True)
        if not changed:
            break
    if any(len(state.tiles[c]) != len(tiles[c]) or connectivity(state.tiles[c]) != 1 for c in tiles):
        raise AssertionError('Count or component connectivity changed')
    if any(state.owners.get(p) != owners.get(p) for p in locked) or any(state.tiles[c] != tiles[c] for c in fixed):
        raise AssertionError('Lake shore or fixed component changed')
    actual = {k for k, n in state.contacts.items() if n > 0}
    lost = (initial_contacts & required)-actual
    if not lost <= soft or not (actual-required) <= (initial_contacts-required):
        raise AssertionError('Protected border lost or new false border formed')
    with (output/'cells.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['component_id', 'x', 'y'])
        writer.writerows((c, x, y) for c, p in sorted(state.tiles.items()) for x, y in sorted(p))
    if lake_file.exists():
        shutil.copyfile(lake_file, output/'lake-cells.csv')
    report = dict(rounds=rounds, choices=choices, maximum_gap=maximum_gap, gap_budget=gap_budget,
        guide=guide, gap_cost=gap_cost, preserve_all=preserve_all, eligible_borders=len(eligible), movable_components=len(movable),
        initial_energy=initial_energy, final_energy=previous, history=history, lost_borders=sorted(lost),
        interior_gap_cells=len(state.gaps), changed_land_cells=len(set(owners)^set(state.owners)),
        rejected_policy=state.rejected_policy, rejected_contacts=state.rejected_contacts,
        gap_distances=[dict(a=a, b=b, before=gap_distance(tiles[a], tiles[b]), after=gap_distance(state.tiles[a], state.tiles[b])) for a, b in sorted(eligible)],
        elapsed_seconds=time.monotonic()-started, inputs={str(p): digest(p) for p in [inputs/'groups.csv', inputs/'validated.wkt', inputs/'geographic-contacts.csv', layout/'cells.csv', audit]+([lake_file] if lake_file.exists() else [])},
        scripts={n: digest(Path(__file__).with_name(n)) for n in ['relax_sparse_borders.py', 'refine_geography.py', 'compact_regions.py', 'place_lake_regions.py']},
        limits=['Experimental blank separations are not geographic seas or lakes.',
                'Every component keeps its count and stays connected. Source landmasses may split.',
                'Only borders below both population thresholds may lose an existing contact. Already missing borders are not repaired by force.',
                'The gap limit measures nearest component distance, not the width of every point along a border.',
                'Interior gaps are limited to a band around initially touching eligible borders and a total cell budget.',
                'Native outlines are fitted at fixed current centroids. Lower energy alone does not prove better geography.',
                'Lake cells and their immediate shore labels are fixed. Independent islands are fixed. No population export is made.'])
    (output/'sparse-borders.json').write_text(json.dumps(report, indent=2)+'\n')
    (output/'complete.txt').write_text('mode=sparse-border-relaxation\ncounts=exact\napproval=none\n')
    return dict(lost_borders=len(lost), interior_gap_cells=len(state.gaps), initial_energy=initial_energy, final_energy=previous)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['inputs', 'layout', 'audit', 'output']:
        parser.add_argument(name, type=Path)
    for name, default in [('rounds', 100), ('choices', 8), ('maximum-gap', 3), ('gap-budget', 300)]:
        parser.add_argument('--'+name, type=int, default=default)
    parser.add_argument('--guide', type=float, default=4.)
    parser.add_argument('--gap-cost', type=float, default=4.)
    parser.add_argument('--preserve-all', action='store_true')
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
