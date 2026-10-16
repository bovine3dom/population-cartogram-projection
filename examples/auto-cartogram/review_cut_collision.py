#!/usr/bin/env python3
"""Replay a rejected cut-border move and publish its largest collision."""
import argparse
import gzip
import json
from pathlib import Path
import subprocess

import numpy as np
from shapely.geometry import Point, box

from review_flow import draw
from save_review import digest
from welded_boundary_fit import WeldedMesh


def replay(fixture):
    """Restore only the geometry needed to evaluate collision constraints."""
    mesh = WeldedMesh.__new__(WeldedMesh)
    mesh.contact_clearance = 0.
    mesh.labels = sorted(fixture['rings'])
    mesh.rings = {c:[np.array(r) for r in rings] for c,rings in fixture['rings'].items()}
    current,step = np.array(fixture['current']),np.array(fixture['step'])
    mesh.size = len(current)
    mesh.n = mesh.size//2-len(mesh.labels)
    mesh.budgets = np.array([fixture['budgets'][c] for c in mesh.labels])
    mesh.remesh(current)
    jac,lower = mesh.inequalities(current)
    return mesh,current,step,max(0.,float(np.max(lower-jac@step)))


def run(source, output):
    if output.exists():
        raise ValueError('Use a new output directory')
    trace = json.loads((source/'trace.json').read_text())
    data = np.load(source/'step.npz')
    pair = trace['overlaps'][0]
    labels = sorted([pair['a'],pair['b']])
    ids = sorted({i for c in labels for ring in trace['rings'][c] for i in ring})
    compact = {old:new for new,old in enumerate(ids)}
    all_labels = sorted(trace['rings'])
    n = len(data['current'])//2-len(all_labels)
    selected = ids+[n+all_labels.index(c) for c in labels]
    fixture = dict(rings={c:[[compact[i] for i in r] for r in trace['rings'][c]] for c in labels},
                   budgets={c:trace['budgets'][c] for c in labels},
                   current=data['current'].reshape(-1,2)[selected].ravel().tolist(),
                   step=data['step'].reshape(-1,2)[selected].ravel().tolist(),
                   source_sha256={p.name:digest(p) for p in [source/'trace.json',source/'step.npz']},
                   original_full_mesh_violation=trace['maximum_linear_violation'])
    mesh,current,step,violation = replay(fixture)
    before,after = mesh.polygons(current),mesh.polygons(current+step)
    inside = []
    for a,b in [labels,labels[::-1]]:
        xy = current.reshape(-1,2)
        samples = [p for ring in mesh.rings[a] for i,j in zip(ring,np.roll(ring,-1))
                   for p in (xy[i],(xy[i]+xy[j])/2)]
        distances = [before[b].boundary.distance(Point(p)) for p in samples if before[b].contains(Point(p))]
        inside.append(dict(country=a,inside=b,samples=len(distances),
                           wrong_sign_samples=sum(1e-8<d<.02 for d in distances),maximum_depth=max(distances,default=0.)))
    intersection = after[labels[0]].intersection(after[labels[1]])
    pieces = list(intersection.geoms) if intersection.geom_type == 'MultiPolygon' else [intersection]
    largest = max(pieces,key=lambda p:p.area)
    xmin,ymin,xmax,ymax = largest.bounds
    crop = box(xmin-.2,ymin-.2,xmax+.2,ymax+.2)
    groups = {c:dict(country_id=c[:3],fill=colour) for c,colour in zip(labels,['#80b1d3','#fb8072'])}
    groups['zzz-overlap'] = dict(country_id='Overlap',fill='#b00020')
    output.mkdir(parents=True)
    for stage,geometries in [('current',before),('proposed',after)]:
        clipped = {c:g.intersection(crop) for c,g in geometries.items()}
        overlap = clipped[labels[0]].intersection(clipped[labels[1]])
        if overlap.area > 1e-12:
            clipped['zzz-overlap'] = overlap
        draw(output/(stage+'.svg'),clipped,groups,'Actual cut-border collision: '+stage,
             'Russia–Mongolia close-up. Dark red marks overlap. The proposed move was rejected.',
             method='Replay of a rejected solver step; not a layout.')
        subprocess.run(['rsvg-convert',str(output/(stage+'.svg')),'-o',str(output/(stage+'.png'))],check=True)
    checks = dict(pair=pair,inside_samples=inside,original_full_mesh_violation=trace['maximum_linear_violation'],
                  corrected_pair_violation=violation,source_current_checks=trace['current_checks'],
                  source_proposed_checks=trace['proposed_checks'],overlap_by_step=[])
    for alpha in [0.,.0001,.001,.01,.1,1.]:
        g = mesh.polygons(current+alpha*step)
        checks['overlap_by_step'].append(dict(alpha=alpha,area=g[labels[0]].intersection(g[labels[1]]).area))
    (output/'fixture.json.gz').write_bytes(gzip.compress(json.dumps(fixture,separators=(',',':')).encode(),mtime=0))
    (output/'checks.json').write_text(json.dumps(checks,indent=2)+'\n')
    (output/'trace.json.gz').write_bytes(gzip.compress((source/'trace.json').read_bytes(),mtime=0))
    (output/'index.html').write_text('''<!doctype html><meta charset="utf-8"><title>Cut-border collision replay</title>
<style>body{font:18px system-ui;max-width:1500px;margin:30px auto;padding:20px}img{width:100%}.pair{display:grid;grid-template-columns:1fr 1fr;gap:16px}</style>
<h1>Russia–Mongolia collision: a sign error</h1>
<p>This is a rejected movement, not a new layout. Russia–Mongolia accounts for more than 99% of this proposal's overlap.</p>
<p>A small overlap passed the geometric tolerance. At the next step, some points inside the neighbouring country were treated as having positive clearance.
The separating direction pointed inward. The correction uses a negative clearance for these points and an outward direction.</p>
<div class="pair"><section><h2>Before the rejected move</h2><img src="current.png" alt="Current border close-up"></section>
<section><h2>Rejected move</h2><img src="proposed.png" alt="Rejected border move with overlap in dark red"></section></div>
<p>The images use the same crop. The corrected constraints reject this captured move. This does not by itself prove that a new fit succeeds.</p>
<h2>Follow-up fits</h2>
<p><a href="../three-country-signed/index.html">Signed-clearance fit</a> · <a href="../three-country-collision/index.html">Optional 0.0001-tile numerical clearance</a></p>
<p>Both tests retain the complete China–Mongolia border and release Russia's borders with those two countries.
Neither gives a useful visible release of the pinch. The numerical-clearance cut case has negligible overlap and 0.020% maximum area error,
but stops at the solver iteration limit. Its iteration budget differs from the signed-only test; this is not a controlled timing comparison.
The full-planet current best is unchanged.</p>
<p><a href="checks.json">Replay checks</a> · <a href="fixture.json.gz">Two-country regression fixture</a> · <a href="trace.json.gz">Original full-mesh trace</a> · <a href="checksums.json">Checksums</a></p>
''')
    (output/'checksums.json').write_text(json.dumps({p.name:digest(p) for p in sorted(output.iterdir()) if p.name!='checksums.json'},indent=2)+'\n')
    return checks


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    parser.add_argument('output',type=Path)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
