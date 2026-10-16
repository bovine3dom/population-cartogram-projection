#!/usr/bin/env python3
"""Publish comparisons of source cuts made before continuous fitting."""
import argparse
import gzip
import json
import math
from pathlib import Path
import shutil

from review_flow import read_shapes
from review_layout import read_csv
from save_review import digest

CASES = ['control', 'control-repeat', 'flow-1', 'flow-25', 'flow-50', 'flow-four-1', 'flow-four-5']
COUNTRIES = ['RUS', 'CHN', 'IND', 'KAZ']


def run(root, output):
    output.mkdir(parents=True, exist_ok=True)
    groups = {r['component_id']: r for r in read_csv(root.parent/'world-55000-dissolved-input/groups.csv')}
    records, panels = [], []
    for name in CASES:
        source = root/name
        report = json.loads((source/'experiment.json').read_text())
        entry = next(r for r in report['runs'] if r['strength'] == .9)
        if (report['components'], report['patches'], report['population']) != (189, 369, 7221236218):
            raise ValueError(f'Unexpected population or partition: {name}')
        if not all(r.get('complete') and r.get('solver_success') for r in report['runs']):
            raise ValueError(f'Incomplete experiment: {name}')
        folder = output/name
        folder.mkdir(exist_ok=True)
        shapes = read_shapes(source/'blend-0.9/components.geojson')
        main = {code: max((c for c in shapes if groups[c]['country_id'] == code), key=lambda c: int(groups[c]['tiles'])) for code in COUNTRIES}
        by_id = {r['component']: r for r in entry['records']}
        scores = {code: by_id[c]['shape_error'] for code, c in main.items()}
        tile_size = math.sqrt(sum(g.area for g in shapes.values())/sum(int(groups[c]['tiles']) for c in shapes))
        seams = root/name.replace('flow', 'seams')
        cut = json.loads((seams/'cuts.json').read_text()) if name.startswith('flow') else None
        record = dict(name=name, population=report['population'], patches=report['patches'], scores=scores,
                      valid_connected=all(r['valid'] and r['parts'] == 1 for r in entry['records']),
                      maximum_main_relative_area_error=max(abs(by_id[c]['relative_area_error']) for c in main.values()),
                      maximum_patch_relative_area_error=entry['maximum_patch_relative_area_error'],
                      minimum_cut_gaps_tiles=[dict(a=a, b=b, gap=shapes[a].distance(shapes[b])/tile_size) for a,b in cut['cuts']] if cut else [])
        records.append(record)
        shutil.copyfile(source/'experiment.json', folder/'experiment.json')
        for region in ['world', 'eurasia']:
            shutil.copyfile(source/'blend-0.9'/(region+'.png'), folder/(region+'.png'))
        files = [(source/'blend-0.9/components.geojson', 'components.geojson.gz')]
        if cut:
            shutil.copyfile(seams/'cuts.json', folder/'cuts.json')
            files.append((seams/'geometry.geojson', 'source.geojson.gz'))
        for path, target in files:
            (folder/target).write_bytes(gzip.compress(path.read_bytes(), mtime=0))
        panels.append(f'<section><h2>{name}</h2><p><a href="{name}/world.png">World</a> · '
                      f'<a href="{name}/experiment.json">Settings and checks</a> · '
                      f'<a href="{name}/components.geojson.gz">Flow geometry</a></p>'
                      f'<a href="{name}/eurasia.png"><img src="{name}/eurasia.png" alt="Eurasia: {name}"></a></section>')
    (output/'summary.json').write_text(json.dumps(records, indent=2)+'\n')
    table = ''.join('<tr><td>'+r['name']+'</td>'+''.join(f'<td>{r["scores"][c]:.4f}</td>' for c in COUNTRIES)+'</tr>' for r in records)
    (output/'index.html').write_text('''<!doctype html><meta charset="utf-8">
<title>Strategic cuts before flow</title>
<style>body{font:17px system-ui;max-width:1500px;margin:32px auto;padding:0 20px}img{width:100%}table{border-collapse:collapse}td,th{padding:8px;border:1px solid #aaa}.panels{display:grid;grid-template-columns:repeat(auto-fit,minmax(500px,1fr))}</style>
<h1>Strategic cuts before flow</h1>
<p><a href="../planet-kontur-coarse90/index.html">Current best: unchanged</a></p>
<p><b>Result: no useful large-scale shape change.</b> These cuts precede patch construction and all fitting.
Russia still forms a thin strip above China. Kazakhstan changes slightly. A single continuous flow still moves both sides together.
Do not replace the current best with these experiments. No new tile fit or H3-MON export was made.</p>
<p>All panels use the coarse 90% Kontur blend. Each trial also ran 0% and 50% blends with the same patches.
All seven trials retain 189 components, 369 patches, and 7,221,236,218 people. Component population and target tile budgets are unchanged.
The regional panels omit other countries. Islands and lakes have not been added at this stage.</p>
<p>Two-border trials cut Russia–Kazakhstan and China–Kazakhstan. Four-border trials also cut Russia–China and Russia–Mongolia.
Names give nominal source seam width in kilometres, not final gap width. These are artificial gaps, not seas.
The 25 km corridor audit permits these borders, but does not prove that every border segment is sparse.</p>
<p>Source cuts retain all unselected contacts. Wider cuts may remove small fragments, with an explicit limit of 0.01% of component source area.
All population stays in its original component. The four-border 25 km and 50 km trials were rejected before fitting:
they also remove Russia–North Korea. No contact guard was disabled.</p>
<h2>Shape error against the original geographic outline</h2>
<p>Lower is better. The score aligns area and centre, but does not rotate shapes.
Compare both fresh controls: repeated solver runs vary. The saved current-best guide is not replaced by either control.
Small score changes alone are not evidence of a better layout.</p>
<table><tr><th>Trial</th><th>Russia</th><th>China</th><th>India</th><th>Kazakhstan</th></tr>'''+table+'''</table>
<p><a href="summary.json">Measured results</a> include minimum polygon distances in target-tile units.
A minimum distance is not an average gap width. Solver area floors still inflate some tiny components;
solver success does not mean exact tile budgets. No fit output is approved as a tile guide.</p>
<h2>Next experiment</h2>
<p>Test a deformation model that permits different movement on each side of selected borders.
Keep dense borders constrained. Penalize shape change and excessive separation, rather than merely adding empty strips.
Any later tile fit must exclude the selected cuts from its required-contact policy and check whether they return.</p>
<div class="panels">'''+''.join(panels)+'</div>\n')
    checks = {str(p.relative_to(output)): digest(p) for p in sorted(output.rglob('*')) if p.is_file() and p.name != 'checksums.json'}
    (output/'checksums.json').write_text(json.dumps(checks, indent=2)+'\n')
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    print(json.dumps(run(**vars(parser.parse_args())), indent=2))
