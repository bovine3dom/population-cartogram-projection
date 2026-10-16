#!/usr/bin/env python3
"""Publish paired regional assembly trials without hiding failed constraints."""
import argparse
import gzip
import json
from pathlib import Path
import shutil
import subprocess

from review_flow import draw, read_shapes
from review_layout import read_csv

from save_review import digest

TRIALS = [('initial', 'independent-assembly-cached'), ('strong-shape', 'independent-assembly-shape1'),
          ('containment', 'independent-assembly-depth'), ('scaled', 'independent-assembly-scaled'),
          ('slsqp', 'independent-assembly-slsqp'), ('constrained', 'independent-assembly-common-start')]


def run(root, output):
    output.mkdir(parents=True, exist_ok=True)
    groups = {r['component_id']:r for r in read_csv(root/'world-55000-dissolved-input/groups.csv')}
    panels, rows, summary = [], [], []
    for name, directory in TRIALS:
        source = root/directory
        report = json.loads((source/'experiment.json').read_text())
        if len(report['cases']) != 2 or any('countries' not in c for c in report['cases']):
            raise ValueError('Incomplete trial: '+name)
        left,right = report['cases']
        if (left['initial_parameters'] != right['initial_parameters']
                or left.get('polish_start_parameters') != right.get('polish_start_parameters')):
            raise ValueError('Initial states differ between paired trials')
        if set(map(tuple,left['required']))-set(map(tuple,right['required'])) != set(map(tuple,report['cuts'])):
            raise ValueError('The paired contact policy differs from the cut manifest')
        folder = output/name
        folder.mkdir(exist_ok=True)
        shutil.copyfile(source/'experiment.json', folder/'experiment.json')
        sections = []
        for case in report['cases']:
            trial = case['name']
            target = folder/trial
            target.mkdir(exist_ok=True)
            path = source/trial/'components.geojson'
            if digest(path) != case['geometry_sha256']:
                raise ValueError('Geometry checksum differs')
            (target/'components.geojson.gz').write_bytes(gzip.compress(path.read_bytes(), mtime=0))
            draw(target/'review.svg', read_shapes(path), groups, f'{name}: {trial}',
                 f'Contact-only test. Overlap {case["total_overlap"]:.4f} tile areas; maximum retained gap {case["maximum_required_gap"]:.3f} tile widths.',
                 method='Independent Kontur guides; area-preserving affine assembly.')
            subprocess.run(['rsvg-convert', str(target/'review.svg'), '-o', str(target/'review.png')], check=True)
            record = dict(trial=name, case=trial, overlap=case['total_overlap'], maximum_required_gap=case['maximum_required_gap'],
                          missing_contacts=case['required_gaps_over_point_one'], contact_proxy_pass=case['contact_proxy_pass'],
                          mean_preferred_error=sum(r['preferred_error'] for r in case['countries'])/len(case['countries']),
                          maximum_area_error=max(abs(r['area_error']) for r in case['countries']),
                          cut_gaps=[dict(a=p['a'],b=p['b'],gap=p['gap']) for p in case['pairs'] if p['cut']],
                          countries=case['countries'])
            summary.append(record)
            rows.append(f'<tr><td>{name}</td><td>{trial}</td><td>{record["overlap"]:.4f}</td><td>{record["maximum_required_gap"]:.3f}</td><td>{record["missing_contacts"]}</td><td>{record["mean_preferred_error"]:.3f}</td><td>{record["contact_proxy_pass"]}</td></tr>')
            link = f'{name}/{trial}'
            sections.append(f'<section><h3>{trial}</h3><a href="{link}/review.png"><img src="{link}/review.png" alt="{name}: {trial}"></a><p><a href="{link}/components.geojson.gz">Geometry</a></p></section>')
        panels.append(f'<h2 id="{name}">{name}</h2><p><a href="{name}/experiment.json">Settings, contacts, shapes, and solver checks</a></p><div class="pair">'+''.join(sections)+'</div>')
    # Archive the additional independent neighbour fits used by every trial.
    neighbour = root/'independent-eurasia-neighbours'
    shutil.copyfile(neighbour/'experiment.json', output/'neighbour-fits.json')
    report = json.loads((neighbour/'experiment.json').read_text())
    for country in report['countries']:
        code = country['country']
        path = neighbour/code/'blend-0.9/component.geojson'
        (output/(code+'.geojson.gz')).write_bytes(gzip.compress(path.read_bytes(), mtime=0))
    if any(r['contact_proxy_pass'] for r in summary):
        raise ValueError('A trial now passes; update the written review before publishing')
    (output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    (output/'index.html').write_text('''<!doctype html><meta charset="utf-8"><title>Independent-shape regional assembly</title>
<style>body{font:17px system-ui;max-width:1800px;margin:30px auto;padding:0 20px}.pair{display:grid;grid-template-columns:repeat(auto-fit,minmax(500px,1fr));gap:12px}img{width:100%}table{border-collapse:collapse}td,th{padding:8px;border:1px solid #aaa}</style>
<h1>Independent shapes, retained contacts, and sparse cuts</h1>
<p><b>All six pairs fail the contact-only check. No layout is approved.</b> The last cut case opens real gaps at Kazakhstan,
but leaves Azerbaijan–Iran and Kazakhstan–Uzbekistan too far apart and has small overlaps. India becomes narrower.
These results do not establish a useful shape improvement. The next model needs local deformation and matching along retained border curves.</p>
<p>A cut removes the direct contact term entirely.
There is no cut-specific spring, boundary matching, or target gap. General collision and geographic ordering still apply.</p>
<p><a href="#constrained">Latest paired comparison</a> · <a href="../independent-kontur-flow/index.html">Independent shapes</a> · <a href="../planet-kontur-coarse90/index.html">Current best: unchanged</a> · <a href="summary.json">Summary data</a></p>
<p>The region has 12 mainland components and 23 requested source contacts. The cut case removes Russia–Kazakhstan,
China–Kazakhstan, Russia–China, and Russia–Mongolia, leaving 19 requested contacts.
The required-contact graph still connects Russia to China through Azerbaijan, Iran, Afghanistan, Pakistan, and India.
Countries outside this region, islands, and lakes are omitted. White space is not necessarily sea.</p>
<p>Each pair starts with identical independent Kontur shapes and geographic positions. Each country can translate,
stretch, and shear, with area fixed. Shape weights, bounds, initial states, and solver schedules are identical within each pair.
The first two pairs exposed failures in overlap handling. The later pairs add a containment penalty and improve numerical conditioning.
The final constrained pair starts both cases from the same saved all-borders pose. It requests a maximum retained gap of 0.05 and total overlap below 0.001.
Check actual residuals, not the request alone. Earlier pairs are separate experiments, not successive maps in one pipeline.</p>
<p><b>Important limitation:</b> retained contacts use soft nearest-boundary distance penalties. They do not match complete border curves.
Thus, even a passing contact test is not a complete border-aware fit. Exact remaining overlaps and gaps are listed below.
No population was moved between components. The simplified outlines were rescaled to their original tile-area budgets.</p>
<h2>Checks</h2><p>Overlap is in tile-area units. Gap is in tile-width units. A missing contact has a gap greater than 0.1.
The contact-only check requires total overlap below 0.01 and every required gap below 0.1.
Shape error compares against the independent preferred shape after area and centre alignment. Lower is better.</p>
<table><tr><th>Trial</th><th>Case</th><th>Overlap</th><th>Maximum required gap</th><th>Missing contacts</th><th>Mean preferred-shape error</th><th>Contact-only check</th></tr>'''+''.join(rows)+'''</table>
<p>Do not compare shape scores alone when the required contacts fail. A lower score obtained by losing required borders is not a successful assembly.
The current best and production H3-MON mapping are unchanged.</p>
'''+''.join(reversed(panels))+'\n')
    (output/'checksums.json').write_text(json.dumps({str(p.relative_to(output)):digest(p) for p in sorted(output.rglob('*'))
                                                  if p.is_file() and p.name != 'checksums.json'}, indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    run(**vars(parser.parse_args()))
