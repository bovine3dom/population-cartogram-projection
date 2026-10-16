#!/usr/bin/env python3
"""Publish wide source-cut diagnostics without changing the current best."""
import argparse
import gzip
from html import escape
import json
from pathlib import Path
import shutil

from save_review import digest
from review_layout import read_csv


def run(source,output):
    if output.exists():
        raise ValueError('Use a new review directory')
    report = json.loads((source/'experiment.json').read_text())
    output.mkdir(parents=True)
    shutil.copyfile(source/'experiment.json',output/'experiment.json')
    panels,records = [],[]
    groups = {r['component_id']:r for r in read_csv(source.parent/'world-55000-dissolved-input/groups.csv')}
    for case in report['cases']:
        if not case['complete']:
            continue
        name = case['name']
        folder = source/name/'flow'
        details = json.loads((folder/'experiment.json').read_text())
        run = next(r for r in details['runs'] if r['strength']==.9)
        geometry = folder/'blend-0.9/components.geojson'
        if run['geometry_sha256'] != digest(geometry) or details['population'] != 7221236218:
            raise ValueError('Geometry or population differs from the recorded run')
        scores = {code:max((r for r in run['records'] if r['country']==code),key=lambda r:int(groups[r['component']]['tiles']))['shape_error']
                  for code in ['RUS','CHN','IND','KAZ']}
        records.append(dict(name=name,scores=scores,
                            valid_connected=all(r['valid'] and r['parts']==1 for r in run['records']),
                            maximum_patch_relative_area_error=run['maximum_patch_relative_area_error'],
                            removed=case['removed'],population=details['population'],patches=details['patches']))
        target = output/name
        target.mkdir()
        shutil.copyfile(folder/'experiment.json',target/'experiment.json')
        for region in ['world','eurasia']:
            shutil.copyfile(folder/'blend-0.9'/(region+'.png'),target/(region+'.png'))
        (target/'components.geojson.gz').write_bytes(gzip.compress(geometry.read_bytes(),mtime=0))
        panels.append(f'<section><h2>{name}</h2><p><a href="{name}/world.png">World</a> · <a href="{name}/experiment.json">Checks</a></p><a href="{name}/eurasia.png"><img src="{name}/eurasia.png" alt="Eurasia: {name}"></a></section>')
    table = ''.join('<tr><td>'+r['name']+'</td>'+''.join(f'<td>{r["scores"][c]:.4f}</td>' for c in ['RUS','CHN','IND','KAZ'])+'</tr>' for r in records)
    failures = ''.join('<li>'+escape(r['name']+': '+r['error'])+'</li>' for r in report['cases'] if 'error' in r)
    (output/'summary.json').write_text(json.dumps(records,indent=2)+'\n')
    (output/'index.html').write_text('''<!doctype html><meta charset="utf-8">
<title>Wide cuts before population flow</title>
<style>body{font:17px system-ui;max-width:1600px;margin:32px auto;padding:0 20px}img{width:100%}table{border-collapse:collapse}td,th{padding:8px;border:1px solid #aaa}.panels{display:grid;grid-template-columns:repeat(auto-fit,minmax(500px,1fr))}</style>
<h1>Wide cuts before population flow</h1>
<p><a href="../planet-kontur-coarse90/index.html">Current best: unchanged</a></p>
<p><b>Diagnostic only. The wider gaps do not give useful shape recovery.</b>
Russia remains a long strip above China. Kazakhstan becomes thinner. No tile fit or H3-MON export uses these maps.</p>
<p>These cuts occur in the original Equal Earth geometry, before population patches and flow.
The four selected borders are Russia–Kazakhstan, China–Kazakhstan, Russia–China, and Russia–Mongolia.
Each strict trial fails because a wider cut also removes an unselected contact.</p>
<p>The separate short-border policy permits one extra cut: Russia–North Korea.
It selects a border that closes a two-edge route around a primary cut, is at most 50 km long,
and has at most 500,000 people in its audited corridor. This border fails the original mean-density rule.
This alternative policy is not approved. The audit uses a 25 km corridor, not the full removed strip.</p>
<p>The width is the nominal source gap in kilometres, not the final gap width.
The 500 km trial removes 45% of Kazakhstan's source area and 16% of Russia's.
No population is removed. All 7,221,236,218 people stay in their original components.
Centres outside the changed outline use the nearest remaining patch in the same component.
All unselected source contacts must remain. This check permits shorter borders; it does not preserve their full length.</p>
<p>Each completed case runs 0% and 90% population blends. The panels show 90%.
The patch grid uses 200 source units, approximately 1,274 km, not 200 km.
The solver grid is 512. Islands, lake insertion, and tiles are absent at this stage.
Tiny components remain subject to the solver area floor. A successful process exit does not give exact population areas.</p>
<h2>Outline error against unchanged geography</h2>
<p>Lower is better. The score aligns area and centre, without rotation.
Small score changes do not establish visual improvement. The table uses the largest mainland component for each named country.</p>
<table><tr><th>Trial</th><th>Russia</th><th>China</th><th>India</th><th>Kazakhstan</th></tr>'''+table+'''</table>
<p><a href="summary.json">Measured results</a> · <a href="experiment.json">Cut settings and failures</a></p>
<h2>Rejected source cuts</h2><ul>'''+failures+'''</ul><div class="panels">'''+''.join(panels)+'</div>\n')
    (output/'checksums.json').write_text(json.dumps({str(p.relative_to(output)):digest(p) for p in sorted(output.rglob('*')) if p.is_file()},indent=2)+'\n')
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    parser.add_argument('output',type=Path)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
