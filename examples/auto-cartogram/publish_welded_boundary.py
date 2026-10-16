#!/usr/bin/env python3
"""Publish the shared-border invariant checks and a small release example."""
import argparse
import contextlib
import gzip
import io
import json
from pathlib import Path
import shutil
import subprocess

from shapely import box
from shapely.geometry import Polygon, mapping

from independent_kontur_flow import normalized
from review_flow import draw
from save_review import digest
from welded_boundary_fit import WeldedMesh, fit


def demo(output):
    source = {'A':box(0,0,4,4),'B':Polygon([(4,0),(8,0),(8,2),(8,4),(4,4)]),'C':box(8,0,16,2)}
    preferred = {c:normalized(box(0,0,4,4),16) for c in source}
    groups = {c:dict(country_id=c,fill=colour) for c,colour in zip(source,['#80b1d3','#8dd3c7','#fb8072'])}
    records = []
    for name,cuts in [('retained',set()),('cut',{('B','C')})]:
        mesh = WeldedMesh(source,preferred,{c:16 for c in source},cuts)
        with contextlib.redirect_stdout(io.StringIO()):
            flat,history = fit(mesh,40)
        shapes = mesh.polygons(flat)
        records.append(dict(name=name,retained_length=shapes['A'].boundary.intersection(shapes['B'].boundary).length,
                            released_gap=shapes['B'].distance(shapes['C']),iterations=len(history),
                            last_step=history[-1],**mesh.checks(flat)))
        geometry = dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in shapes.items()])
        (output/(name+'.geojson')).write_text(json.dumps(geometry)+'\n')
        draw(output/(name+'.svg'),shapes,groups,'Three-region test: '+name,
             'A-B remains a complete shared edge. C prefers a square, with the same area as its initial long rectangle.',
             method='Synthetic solver test; no geographic data in this panel.')
        svg = output/(name+'.svg')
        svg.write_text(svg.read_text().replace('Sources: Kontur population; Natural Earth. ','Sources: synthetic rectangles. '))
        subprocess.run(['rsvg-convert',str(svg),'-o',str(output/(name+'.png'))],check=True)
    (output/'checks.json').write_text(json.dumps(records,indent=2)+'\n')


def run(source, output):
    report = json.loads((source/'experiment.json').read_text())
    if {c['name'] for c in report['cases']} != {'all-borders','sparse-cuts'}:
        raise ValueError('Need both completed regional cases')
    control = next(c for c in report['cases'] if c['name'] == 'all-borders')
    pairs = {(p['a'],p['b']) for p in control['contacts']}
    cuts = {tuple(p) for p in report['cuts']}
    if not cuts <= pairs:
        raise ValueError('Cut missing from control contacts')
    output.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(source/'experiment.json',output/'experiment.json')
    rows,panels = [],[]
    for case in report['cases']:
        name = case['name']
        retained = [p for p in case['contacts'] if not p['cut']]
        if (case['welded_edge_mismatches'] or not case['valid'] or case['overlap'] > 1e-6
                or any(p['gap'] > 1e-8 or p['shared_length'] <= 1e-6 for p in retained)):
            raise ValueError('Retained border or validity check failed')
        selected_cuts = set() if name == 'all-borders' else cuts
        if ({(p['a'],p['b']) for p in case['contacts']} != pairs
                or {(p['a'],p['b']) for p in case['contacts'] if p['cut']} != selected_cuts):
            raise ValueError('Contact set or cut policy differs between cases')
        folder = output/name
        folder.mkdir(exist_ok=True)
        path = source/name/'components.geojson'
        if digest(path) != case['geometry_sha256']:
            raise ValueError('Output geometry hash differs')
        (folder/'components.geojson.gz').write_bytes(gzip.compress(path.read_bytes(),mtime=0))
        shutil.copyfile(source/name/'review.png',folder/'review.png')
        accepted = sum('alpha' in step for step in case['history'])
        status = case['history'][-1]['status']
        rows.append(f'<tr><td>{name}</td><td>{len(retained)}</td><td>0</td><td>{case["overlap"]:.8f}</td><td>{case["maximum_area_error"]:.3%}</td><td>{accepted}/{len(case["history"])}</td><td>{status}</td></tr>')
        panels.append(f'<section><h2>{name}</h2><a href="{name}/review.png"><img src="{name}/review.png" alt="Shared-border regional fit: {name}"></a><p><a href="{name}/components.geojson.gz">Geometry</a></p></section>')
    (output/'demo').mkdir(exist_ok=True)
    demo(output/'demo')
    correspondence = ('''<p>This pair uses patch-labelled contour guides. Source vertices anchor the correspondence.
Crossing target chords trigger shared-edge subdivision. New samples interpolate fixed target parameters;
they are not projected again across nearby bays. The mapped rings pass their self-intersection checks.
Single-label rings and ambiguous label cycles still use whole-outline matching. See the fallback records in the report.</p>'''
                      if report.get('patch_guides') else '''<p>This pair uses whole-outline arclength matching.
A later patch-guided experiment repairs crossing target chords with shared-edge subdivision.</p>''')
    settings = f'<p>Source simplification: {report["source_simplify"]} tile units. Maximum initial edge length: {report["edge_length"]}. Iteration limit: {report.get("iterations","not recorded")}.</p>'
    cut_names = ', '.join(a[:3]+'–'+b[:3] for a,b in sorted(cuts))
    scope = f'<p>This {len(control["countries"])}-country test releases {cut_names}. '
    scope += f'Numerical contact clearance: {report.get("contact_clearance",0.)} tile units. '
    scope += 'A nonzero clearance is an experimental numerical buffer at nearby non-welded edges, not a required visible gap. It never separates welded edges.</p>'
    (output/'index.html').write_text('''<!doctype html><meta charset="utf-8"><title>Shared-boundary fit: border checks</title>
<style>body{font:18px system-ui;max-width:1800px;margin:32px auto;padding:0 20px}img{width:100%}.pair{display:grid;grid-template-columns:repeat(auto-fit,minmax(500px,1fr));gap:16px}table{border-collapse:collapse}td,th{padding:9px;border:1px solid #aaa}</style>
<h1>Retained borders now share complete edges</h1>
<p><b>This replaces the rejected point-contact model, not the current-best map.</b>
The previous assembly let countries touch at isolated points. That did not preserve their borders.
Here, both countries use identical vertex variables along every retained border. Only selected cuts get separate copies.</p>
<p><b>This is a border-preservation checkpoint, not a shape improvement.</b> The regional optimizer still makes too little progress.
Do not mistake an intact starting layout for a successful new layout. The full-planet current best and H3-MON mapping are unchanged.</p>
<p><a href="../planet-kontur-coarse90/index.html">Current best</a> · <a href="experiment.json">Settings and checks</a> · <a href="../independent-assembly/index.html">Rejected point-contact experiments</a> · <a href="../contour-refinement/index.html">Contour refinement test</a></p>
<h2>Regional checks</h2><p>All retained borders have zero geometric gap and positive shared length.
The mesh also checks that no source border segment was omitted during vertex matching.
Overlap is in tile-area units. Country areas are approximate continuous areas; these are not tile layouts.</p>
<table><tr><th>Case</th><th>Complete retained borders</th><th>Border gaps</th><th>Overlap</th><th>Maximum area error</th><th>Accepted steps / attempts</th><th>Last solver status</th></tr>'''+''.join(rows)+'''</table>
'''+scope+'''
<p>There is no cut-specific attraction. General collision checks still apply.
A cut allows separation; it does not require a visible gap.</p>
<p>The test starts from the saved continuous guide to obtain valid border topology.
Independent Kontur shapes supply the preferred outlines. The regional panels omit other countries, islands, and lakes.
White areas must not be read as a new sea map.</p>
<div class="pair">'''+''.join(panels)+'''</div>
<h2>Small test: release one border without breaking the other</h2>
<p>A and B start as squares. C starts as a long rectangle with the same area and prefers a square.
In the cut case, C can reshape and separate while A-B remains a complete shared edge.
This tests the mechanism; it does not prove that the Eurasian fit is solved.</p>
<div class="pair"><section><h3>A-B and B-C retained</h3><img src="demo/retained.png" alt="Synthetic retained-border test"></section>
<section><h3>A-B retained, B-C cut</h3><img src="demo/cut.png" alt="Synthetic cut-border test"></section></div>
<p><a href="demo/checks.json">Synthetic checks</a> · <a href="checksums.json">Archive checksums</a></p>
<h2>Contour correspondence</h2>'''+correspondence+settings+'''
<h2>Remaining problem</h2><p>Large steps toward the independent outlines can make narrow coastlines cross themselves.
Released borders can also overlap during a proposed step. The validity and overlap checks reject those steps.
Solver convergence is a separate check: a saved final polygon can be the unchanged initial polygon after failed attempts.
Small accepted steps preserve borders but do not yet fix the Kazakhstan pinch.
Do not weaken the border or collision checks to make an image look better.</p>
''')
    (output/'checksums.json').write_text(json.dumps({str(p.relative_to(output)):digest(p) for p in sorted(output.rglob('*'))
                                                  if p.is_file() and p.name != 'checksums.json'},indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    parser.add_argument('output',type=Path)
    run(**vars(parser.parse_args()))
