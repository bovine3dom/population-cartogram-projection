#!/usr/bin/env python3
"""Compare retained and released contacts in an area-preserving affine assembly."""
import argparse
from functools import lru_cache
import itertools
import json
import math
from pathlib import Path
import subprocess
import time

import numpy as np
from scipy.optimize import minimize
from shapely import affinity
from shapely.geometry import mapping

from independent_kontur_flow import normalized
from review_flow import read_shapes, draw
from review_layout import read_csv
from save_review import digest
from trace_kazakhstan import outline_error

COUNTRIES = 'RUS CHN KAZ MNG KGZ UZB TJK AFG PAK IND IRN AZE'.split()
CUTS = [('RUS', 'KAZ'), ('CHN', 'KAZ'), ('RUS', 'CHN'), ('RUS', 'MNG')]


def matrix(a, shear):
    return np.array([[np.exp(a), shear], [0., np.exp(-a)]])


class Assembly:
    def __init__(self, shapes, centres, required):
        self.labels = sorted(shapes)
        self.ids = {c: i for i, c in enumerate(self.labels)}
        self.shapes = [shapes[c] for c in self.labels]
        self.centres = np.array([centres[c] for c in self.labels])
        self.required = {tuple(sorted(p)) for p in required}
        if any(a not in self.ids or b not in self.ids or a == b for a,b in self.required):
            raise ValueError('Invalid required contact')
        self.pairs = list(itertools.combinations(range(len(self.labels)), 2))
        self.radii = np.array([g.area/math.pi for g in self.shapes])
        self.start = np.column_stack((self.centres, np.zeros((len(self.labels), 2)))).ravel()
        # Finite differences change one country at a time. Reuse unaffected pairs.
        self.geometry = lru_cache(maxsize=2048)(self.transform)
        self.pair = lru_cache(maxsize=16384)(self.pair_terms)

    def transform(self, i, values):
        x, y, a, shear = values
        m = matrix(a, shear)
        return affinity.affine_transform(self.shapes[i], [*m[0], *m[1], x, y])

    def geometries(self, flat):
        return [self.geometry(i, tuple(p)) for i,p in enumerate(flat.reshape(-1,4))]

    def pair_terms(self, i, j, left, right):
        ga, gb = self.geometry(i, left), self.geometry(j, right)
        gap = ga.distance(gb) if (self.labels[i], self.labels[j]) in self.required else 0.
        overlap = ga.intersection(gb).area if ga.intersects(gb) else 0.
        direction = self.centres[j]-self.centres[i]
        axis = int(np.argmax(np.abs(direction)))
        signed = np.sign(direction[axis])*(right[axis]-left[axis])
        # Intersection area is flat when one country is wholly inside another.
        # Interior-centre depth supplies an escape direction in that case.
        penetration = 0.
        if overlap > 0:
            for outer, inner in [(ga,gb), (gb,ga)]:
                if outer.contains(inner.centroid):
                    penetration += outer.boundary.distance(inner.centroid)**2
        return gap**2, overlap, max(0., -signed)**2, penetration

    def terms(self, flat):
        state = flat.reshape(-1, 4)
        positions = [tuple(p) for p in state]
        # Shape cost is mean-square displacement under the affine transform,
        # approximated with an isotropic second moment. Translation is free here.
        shape_cost = sum(r*np.sum((matrix(a,s)-np.eye(2))**2)
                         for r, (_,_,a,s) in zip(self.radii, state))
        anchor = float(np.sum((state[:, :2]-self.centres)**2))
        contact, overlap, order, penetration = 0., 0., 0., 0.
        for i,j in self.pairs:
            gap, area, inversion, depth = self.pair(i, j, positions[i], positions[j])
            contact += gap
            overlap += area
            order += inversion
            penetration += depth
        return dict(shape=float(shape_cost), anchor=anchor, contact=float(contact),
                    overlap=float(overlap), order=float(order), penetration=float(penetration))

    def objective(self, flat, contact_weight, collision_weight, shape_weight):
        t = self.terms(flat)
        return shape_weight*t['shape']+.002*t['anchor']+contact_weight*t['contact']+collision_weight*(t['overlap']+t['penetration'])+10*t['order']


def metrics(state, flat, native, preferred, all_contacts, cuts):
    shapes = dict(zip(state.labels, state.geometries(flat)))
    pairs = []
    for a,b in itertools.combinations(state.labels, 2):
        overlap = shapes[a].intersection(shapes[b]).area
        gap = shapes[a].distance(shapes[b])
        pairs.append(dict(a=a, b=b, required=(a,b) in state.required, cut=(a,b) in cuts,
                          source_contact=(a,b) in all_contacts, gap=gap, overlap=overlap))
    records = [dict(component=c, country=c[:3], area=shapes[c].area,
                    area_error=shapes[c].area/preferred[c].area-1,
                    geographic_error=outline_error(shapes[c], native[c]),
                    preferred_error=outline_error(shapes[c], preferred[c]),
                    valid=bool(shapes[c].is_valid)) for c in state.labels]
    required = [p for p in pairs if p['required']]
    total_overlap = sum(p['overlap'] for p in pairs)
    max_gap = max((p['gap'] for p in required), default=0.)
    return shapes, dict(countries=records, pairs=pairs, terms=state.terms(flat),
                        total_overlap=total_overlap, maximum_required_gap=max_gap,
                        required_gaps_over_point_one=sum(p['gap'] > .1 for p in required),
                        contact_proxy_pass=total_overlap < .01 and max_gap < .1,
                        full_border_fit=False)


def run(root, output, iterations=250, shape_weight=.1, optimizer='L-BFGS-B'):
    if (output.exists() or iterations < 1 or not math.isfinite(shape_weight) or shape_weight <= 0
            or optimizer not in ['L-BFGS-B', 'SLSQP']):
        raise ValueError('Use a new output and positive settings')
    inputs = root/'world-55000-dissolved-input'
    source = root/'world-55000-mainland-flow/input/geometry.geojson'
    native = read_shapes(source)
    rows = {r['component_id']: r for r in read_csv(inputs/'groups.csv')}
    main = {code: max((c for c in native if rows[c]['country_id'] == code), key=lambda c: int(rows[c]['tiles'])) for code in COUNTRIES}
    native = {c:native[c] for c in main.values()}
    paths = [source, inputs/'groups.csv', inputs/'geographic-contacts.csv']
    preferred, simplification = {}, []
    for code,c in main.items():
        folder = root/('independent-kontur-flow' if code in ['RUS','CHN','IND','KAZ'] else 'independent-eurasia-neighbours')
        path = folder/code/'blend-0.9/component.geojson'
        report = json.loads((folder/'experiment.json').read_text())
        record = next(r for r in report['countries'] if r['component'] == c)
        entry = next(r for r in record['runs'] if r['strength'] == .9)
        if not entry['complete'] or entry['exit_code'] or entry['output_sha256'] != digest(path):
            raise ValueError('Independent shape is not verified')
        g = read_shapes(path)[c]
        # Cheap collision geometry; quantify this change before optimizing.
        simple = normalized(g.simplify(.15, preserve_topology=True), int(rows[c]['tiles']))
        simplification.append(dict(component=c, error=outline_error(simple, g)))
        preferred[c] = simple
        paths.extend([path, folder/'experiment.json'])
    all_contacts = {tuple(sorted((r['a'],r['b']))) for r in read_csv(inputs/'geographic-contacts.csv')
                    if r['both_represented'] == 'true' and r['a'] in native and r['b'] in native}
    cuts = {tuple(sorted((main[a], main[b]))) for a,b in CUTS}
    audit_path = root/'sparse-border-audit-25-wide/border-population.json'
    audit = json.loads(audit_path.read_text())
    for p in [inputs/'groups.csv', inputs/'geographic-contacts.csv']:
        if audit['inputs'].get(str(p)) != digest(p):
            raise ValueError('Population audit inputs differ')
    eligible = {tuple(sorted((b['a'],b['b']))) for b in audit['borders'] if b['eligible']}
    if not cuts <= all_contacts & eligible:
        raise ValueError('A selected cut is not an audited regional contact')
    paths.append(audit_path)
    scale = math.sqrt(sum(g.area for g in preferred.values())/sum(g.area for g in native.values()))
    centres = {c:np.array([g.centroid.x, g.centroid.y])*scale for c,g in native.items()}
    origin = np.mean(list(centres.values()), axis=0)
    centres = {c:p-origin for c,p in centres.items()}
    output.mkdir(parents=True)
    report = dict(cuts=sorted(cuts), retained_control_contacts=sorted(all_contacts), iterations=iterations,
                  shape_weight=shape_weight, optimizer=optimizer, simplification=simplification, cases=[],
                  inputs={str(p):digest(p) for p in paths}, script_sha256=digest(Path(__file__)),
                  limits=['Regional diagnostic, not a world layout. External neighbours are omitted.',
                          'Per-country area-preserving affine stretch and shear, plus translation. No shared flow field.',
                          'Retained contacts use a soft nearest-boundary distance penalty, not matched full-border curves.',
                          'Cuts have no contact penalty, no target gap, and no boundary matching. General collision and ordering apply to all pairs.',
                          'Affine freedom is limited: log stretch and shear are each bounded to [-0.7, 0.7]. No independent rotation.',
                          'Exact polygon overlaps and residual gaps are reported. A small objective is not proof of feasibility.',
                          'Simplified shapes are uniformly rescaled to their original tile-area budgets. Population is not reassigned.'])
    def save():
        (output/'experiment.json').write_text(json.dumps(report, indent=2)+'\n')
    save()
    for name, required in [('all-borders', all_contacts), ('sparse-cuts', all_contacts-cuts)]:
        state = Assembly(preferred, centres, required)
        flat = state.start.copy()
        case = dict(name=name, required=sorted(required), stages=[], initial_parameters=state.start.reshape(-1,4).tolist())
        report['cases'].append(case)
        # Scale translations to the same order as the deformation variables.
        translation_scale = math.sqrt(np.median([g.area for g in preferred.values()]))
        parameter_scale = np.tile([translation_scale, translation_scale, 1., 1.], len(state.labels))
        case['optimizer_translation_scale'] = translation_scale
        # Identical initial positions, shape weights, and penalty schedule in both cases.
        for contact, collision in [(1.,20.), (10.,200.), (100.,2000.)]:
            start = time.monotonic()
            options = (dict(maxiter=iterations, maxfun=iterations*100, maxls=40, ftol=1e-10, gtol=1e-5)
                       if optimizer == 'L-BFGS-B' else dict(maxiter=iterations, ftol=1e-8, eps=1e-6))
            result = minimize(lambda p: state.objective(p*parameter_scale, contact, collision, shape_weight),
                              flat/parameter_scale, method=optimizer,
                              bounds=[b for _ in state.labels for b in [(None,None),(None,None),(-.7,.7),(-.7,.7)]],
                              options=options)
            flat = result.x*parameter_scale
            case['stages'].append(dict(contact_weight=contact, collision_weight=collision, objective=float(result.fun),
                                       success=bool(result.success), message=str(result.message), iterations=int(result.nit),
                                       seconds=time.monotonic()-start))
            save()
            print(name, case['stages'][-1], flush=True)
        shapes, checks = metrics(state, flat, native, preferred, all_contacts, cuts)
        case.update(checks)
        case['parameters'] = flat.reshape(-1,4).tolist()
        case['labels'] = state.labels
        folder = output/name
        folder.mkdir()
        geometry = folder/'components.geojson'
        geometry.write_text(json.dumps(dict(type='FeatureCollection', features=[dict(type='Feature', properties=dict(component_id=c), geometry=mapping(g)) for c,g in sorted(shapes.items())]), separators=(',', ':'))+'\n')
        case['geometry_sha256'] = digest(geometry)
        draw(folder/'review.svg', shapes, rows, f'Independent-shape assembly: {name}',
             f'Regional contact-only prototype. Overlap {checks["total_overlap"]:.2f} tile areas; maximum required gap {checks["maximum_required_gap"]:.2f} tile widths.',
             method='Independent Kontur guides; area-preserving affine assembly.')
        subprocess.run(['rsvg-convert', str(folder/'review.svg'), '-o', str(folder/'review.png')], check=True)
        save()
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--iterations', type=int, default=250)
    parser.add_argument('--shape-weight', type=float, default=.1)
    parser.add_argument('--optimizer', choices=['L-BFGS-B', 'SLSQP'], default='L-BFGS-B')
    run(**vars(parser.parse_args()))
