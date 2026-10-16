#!/usr/bin/env python3
"""Enforce numerical contact and overlap limits on a saved affine assembly."""
import argparse
import json
from pathlib import Path
import subprocess
import time

import numpy as np
from scipy.optimize import minimize
from shapely.geometry import mapping

from assemble_independent import Assembly, metrics
from independent_kontur_flow import normalized
from review_flow import read_shapes, draw
from review_layout import read_csv
from save_review import digest


def constraints(state, flat, required, gap_limit=.05, overlap_limit=.001):
    if set(required) != state.required:
        raise ValueError('Constraint policy differs from the assembly')
    positions = [tuple(p) for p in flat.reshape(-1,4)]
    pairs = {(state.labels[i],state.labels[j]):state.pair(i,j,positions[i],positions[j]) for i,j in state.pairs}
    overlap = sum(p[1] for p in pairs.values())
    return np.array([gap_limit-np.sqrt(pairs[a,b][0]) for a,b in sorted(required)]+[overlap_limit-overlap])


def run(root, source, output, iterations=500):
    if output.exists() or iterations < 1:
        raise ValueError('Use a new output and positive iteration limit')
    original = source/'experiment.json'
    prior = json.loads(original.read_text())
    for path, expected in prior['inputs'].items():
        if digest(Path(path)) != expected:
            raise ValueError('Prior input hash differs: '+path)
    rows = {r['component_id']:r for r in read_csv(root/'world-55000-dissolved-input/groups.csv')}
    native = read_shapes(root/'world-55000-mainland-flow/input/geometry.geojson')
    preferred = {}
    for path in prior['inputs']:
        if path.endswith('/blend-0.9/component.geojson'):
            for c,g in read_shapes(Path(path)).items():
                preferred[c] = normalized(g.simplify(.15, preserve_topology=True), int(rows[c]['tiles']))
    output.mkdir(parents=True)
    report = {k:v for k,v in prior.items() if k != 'cases'}
    report.update(cases=[], prior_sha256=digest(original), prior_path=str(original),
                  script_sha256=digest(Path(__file__)), optimizer='SLSQP with explicit inequalities',
                  iterations=iterations, maximum_gap_constraint=.05, total_overlap_constraint=.001)
    common = next(c for c in prior['cases'] if c['name'] == 'all-borders')
    report['limits'] += ['Both polish cases start from the same saved all-borders pose. Constraints limit point-contact gaps and total overlap, not full border curves.']
    def save():
        (output/'experiment.json').write_text(json.dumps(report, indent=2)+'\n')
    save()
    for old in prior['cases']:
        labels = old['labels']
        centres = {c:np.array(p[:2]) for c,p in zip(labels, old['initial_parameters'])}
        required = set(map(tuple,old['required']))
        state = Assembly(preferred, centres, required)
        if state.labels != labels:
            raise ValueError('Label order differs')
        scale = np.tile([old['optimizer_translation_scale']]*2+[1.,1.], len(labels))
        if common['labels'] != labels:
            raise ValueError('Common start labels differ')
        initial = np.array(common['parameters']).ravel()/scale
        start = time.monotonic()
        result = minimize(lambda p: state.objective(p*scale, 100., 2000., prior['shape_weight']), initial,
                          method='SLSQP', bounds=[b for c in labels for b in [(None,None),(None,None),(-.7,.7),(-.7,.7)]],
                          constraints=[dict(type='ineq', fun=lambda p: constraints(state, p*scale, required))],
                          options=dict(maxiter=iterations, ftol=1e-8, eps=1e-6))
        flat = result.x*scale
        shapes, checks = metrics(state, flat, native, preferred, set(map(tuple,prior['retained_control_contacts'])), set(map(tuple,prior['cuts'])))
        case = dict(name=old['name'], required=old['required'], labels=labels, initial_parameters=old['initial_parameters'],
                    polish_start_parameters=common['parameters'],
                    parameters=flat.reshape(-1,4).tolist(), stages=[dict(success=bool(result.success), message=str(result.message),
                    iterations=int(result.nit), seconds=time.monotonic()-start)], **checks)
        folder = output/case['name']
        folder.mkdir()
        geometry = folder/'components.geojson'
        geometry.write_text(json.dumps(dict(type='FeatureCollection', features=[dict(type='Feature', properties=dict(component_id=c), geometry=mapping(g)) for c,g in shapes.items()]), separators=(',', ':'))+'\n')
        case['geometry_sha256'] = digest(geometry)
        draw(folder/'review.svg', shapes, rows, 'Constrained contact assembly: '+case['name'],
             f'Not a full-border fit. Overlap {checks["total_overlap"]:.4f}; maximum required gap {checks["maximum_required_gap"]:.3f} tile widths.',
             method='Independent Kontur guides; constrained area-preserving affine assembly.')
        subprocess.run(['rsvg-convert', str(folder/'review.svg'), '-o', str(folder/'review.png')], check=True)
        report['cases'].append(case)
        save()
        print(case['name'],case['stages'],case['total_overlap'],case['maximum_required_gap'],flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['root','source','output']:
        parser.add_argument(name,type=Path)
    parser.add_argument('--iterations',type=int,default=500)
    run(**vars(parser.parse_args()))
