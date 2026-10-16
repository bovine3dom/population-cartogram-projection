#!/usr/bin/env python3
"""Publish the independent-flow diagnostic and its saved inputs."""
import argparse
import gzip
import json
from pathlib import Path
import shutil
import subprocess

from review_flow import draw, read_shapes
from review_layout import read_csv
from save_review import digest


def run(root, output):
    output.mkdir(parents=True, exist_ok=True)
    groups = {r['component_id']: r for r in read_csv(root/'world-55000-dissolved-input/groups.csv')}
    for name, path in [('source', root/'world-55000-mainland-flow/input/geometry.geojson'),
                       ('shared', root/'kontur-patch-flow-200-floor/blend-0.9/components.geojson')]:
        data = json.loads(path.read_text())
        data['features'] = [f for f in data['features'] if groups[f['properties']['component_id']]['country_id'] in ['RUS', 'CHN', 'IND', 'KAZ', 'CAN']]
        (output/(name+'.geojson.gz')).write_bytes(gzip.compress(json.dumps(data, separators=(',', ':')).encode(), mtime=0))
    rows, panels = [], []
    for grid in [256, 512]:
        source = root/('independent-kontur-flow'+('-512' if grid == 512 else ''))
        report = json.loads((source/'experiment.json').read_text())
        folder = output/f'grid-{grid}'
        folder.mkdir(exist_ok=True)
        shutil.copyfile(source/'experiment.json', folder/'experiment.json')
        for country in report['countries']:
            code = country['country']
            target = folder/code
            target.mkdir(exist_ok=True)
            successful = all(r.get('complete') and r.get('exit_code') == 0 for r in country['runs'])
            for entry in country['runs']:
                name = f'blend-{entry["strength"]:g}'
                saved = target/name
                saved.mkdir(exist_ok=True)
                for file in ['areas.csv', 'solver.log']:
                    shutil.copyfile(source/code/name/file, saved/file)
                for file in ['patches.geojson', 'component.geojson']:
                    path = source/code/name/file
                    if path.exists():
                        (saved/(file+'.gz')).write_bytes(gzip.compress(path.read_bytes(), mtime=0))
            if not successful:
                rows.append(f'<tr><td>{code}</td><td>{grid}</td><td>{country["shared_shape_error"]:.3f}</td><td colspan="2">Failed: non-simple boundary. See solver log.</td></tr>')
                continue
            independent = next(r for r in country['runs'] if r['strength'] == .9)
            rows.append(f'<tr><td>{code}</td><td>{grid}</td><td>{country["shared_shape_error"]:.3f}</td><td>{independent["shape_error"]:.3f}</td><td>{independent["maximum_patch_relative_area_error"]:.2%}</td></tr>')
            shutil.copyfile(source/code/'comparison.png', target/'comparison.png')
            draw(target/'independent.svg', read_shapes(source/code/'blend-0.9/component.geojson'), groups,
                 f'{code}: independent 90% Kontur flow, grid {grid}',
                 'Mainland only, scaled to fit this page. No neighbours or border constraints. Not a world layout.')
            subprocess.run(['rsvg-convert', str(target/'independent.svg'), '-o', str(target/'independent.png')], check=True)
            link = f'grid-{grid}/{code}'
            panels.append(f'<section id="{code}-{grid}"><h2>{code}, grid {grid}</h2><p><a href="{link}/independent.png">Independent shape: enlarged</a> · <a href="grid-{grid}/experiment.json">Settings and checks</a></p><a href="{link}/comparison.png"><img src="{link}/comparison.png" alt="{code} comparison at grid {grid}"></a></section>')
    (output/'index.html').write_text('''<!doctype html><meta charset="utf-8"><title>Independent Kontur flow</title>
<style>body{font:18px system-ui;max-width:1600px;margin:32px auto;padding:0 20px}img{width:100%}td,th{padding:8px;border:1px solid #aaa}table{border-collapse:collapse}</style>
<h1>Let each country deform independently</h1>
<p><b>There is now a clear shape change.</b> China is more compact. Russia no longer forms a long strip above China.
India and Kazakhstan also retain much more recognisable outlines. The extra Canada test succeeds at grid 512.</p>
<p><a href="#RUS-256">Russia</a> · <a href="#CHN-256">China</a> · <a href="#IND-256">India</a> · <a href="#KAZ-256">Kazakhstan</a> · <a href="#CAN-512">Canada</a> · <a href="../planet-kontur-coarse90/index.html">Current best: unchanged</a></p>
<h2>What changed?</h2>
<p>Each solver call receives one mainland component. All neighbours are absent. The exact coarse Kontur patches and target values come from the saved current-best flow inputs.
Unlike an empty strip in a shared flow field, this gives each country an independent deformation.</p>
<p>The uniform control should retain the original shape. It does, within small numerical errors.
The 90% Kontur result shows distortion from population distribution inside the country, without its neighbours.
Russia still expands in the populated west and contracts in the sparsely populated east.</p>
<p>These tests remove <em>all</em> neighbouring constraints, not only sparse borders. The solver domain and effective spatial resolution also change.
Russia and China give similar results at grids 256 and 512. This supports the diagnosis, but it does not show that a few selected cuts can achieve the same result.</p>
<h2>Measured outline error</h2><p>Lower is better. Shapes are aligned by centre and area, without rotation. Patch error measures the solver's local area accuracy.</p>
<table><tr><th>Mainland</th><th>Grid</th><th>Shared flow</th><th>Independent 90%</th><th>Maximum patch area error</th></tr>'''+''.join(rows)+'''</table>
<p>Target populations and tile-area budgets are unchanged. Independent outputs are uniformly scaled to their component budgets after fitting.
These are continuous shapes, not tile layouts. Panels use equal area within each page; country size and position cannot be compared between pages.
No islands or lakes were placed. The failed Canada 256-grid output is not used.</p>
<h2>Next step</h2><p>Use these independent shapes as reference shapes for a small regional assembly test.
Keep dense borders connected, allow the audited sparse borders to separate, and penalize overlap, excessive gaps, and shape change.
Success requires preserving most of this shape improvement without losing the important borders. Do not replace the current best yet.</p>
<p><a href="grid-256/CAN/blend-0.9/solver.log">Failed Canada run</a> · <a href="checksums.json">Archive checksums</a> · <a href="https://github.com/mgastner/cartogram-cpp">Solver documentation</a></p>
'''+''.join(panels)+'\n')
    checks = {str(p.relative_to(output)): digest(p) for p in sorted(output.rglob('*')) if p.is_file() and p.name != 'checksums.json'}
    (output/'checksums.json').write_text(json.dumps(checks, indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    run(**vars(parser.parse_args()))
