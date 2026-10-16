#!/usr/bin/env python3
"""Publish block-flow and tile comparisons with explicit cut-policy costs."""
import argparse
import gzip
from html import escape
import json
from pathlib import Path
import shutil

import numpy as np
from scipy.ndimage import label
from shapely import box, union_all

from place_islands import tile_contacts
from review_flow import read_shapes
from review_gaps import measure
from review_layout import read_csv
from save_review import digest
from trace_kazakhstan import outline_error

CODES = ['RUS','CHN','IND','KAZ']


def tile_audit(root,folder,cuts):
    groups = {r['component_id']:r for r in read_csv(root/'world-55000-dissolved-input/groups.csv')}
    native = read_shapes(root/'world-55000-mainland-flow/input/geometry.geojson')
    cells = read_csv(folder/'layout/cells.csv')
    owners = {(int(r['x']),int(r['y'])):r['component_id'] for r in cells}
    if len(owners)!=len(cells):
        raise ValueError('Tile overlap')
    actual = tile_contacts(owners)
    required = {tuple(sorted((r['a'],r['b']))) for r in read_csv(root/'world-55000-dissolved-input/geographic-contacts.csv') if r['both_represented']=='true'}
    scores = {}
    for code in CODES:
        c = max((c for c in native if c[:3]==code),key=lambda c:int(groups[c]['tiles']))
        g = union_all([box(x-.5,y-.5,x+.5,y+.5) for (x,y),owner in owners.items() if owner==c])
        scores[code] = outline_error(g,native[c])
    gaps,_,enclosed,_,(x0,y0) = measure(owners)
    lakes = {(int(r['x']),int(r['y'])) for r in read_csv(folder/'layout/lake-cells.csv')}
    if lakes & owners.keys():
        raise ValueError('A lake occupies a country tile')
    lake_enclosed = sum(bool(enclosed[y-y0,x-x0]) for x,y in lakes)
    labels,_ = label(enclosed)
    sizes = np.bincount(labels.ravel())
    largest = []
    for i in np.argsort(sizes[1:])[-6:][::-1]+1:
        yy,xx = np.nonzero(labels==i)
        water = {(int(x+x0),int(y+y0)) for x,y in zip(xx,yy)}
        neighbours = {owners[q][:3] for x,y in water for q in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] if q in owners}
        largest.append(dict(cells=len(water),lake_cells=len(water&lakes),adjacent_countries=sorted(neighbours)))
    return dict(largest_enclosed_regions=largest,tiles=len(owners),scores=scores,retained_missing=len((required-cuts)-actual),
                false_contacts=len(actual-required),cut_contacts=sorted(cuts&actual),
                enclosed_empty_cells=gaps['enclosed_empty_cells'],enclosed_lake_cells=lake_enclosed,
                enclosed_non_lake_cells=gaps['enclosed_empty_cells']-lake_enclosed,lake_cells=len(lakes),
                cells_sha256=digest(folder/'layout/cells.csv'),
                limits=['Non-lake enclosed water is not a count of phantom holes. It can include real seas or other intended water.',
                        'Cut contacts are reported separately from false geographic contacts. The baseline is checked against the same retained-contact policy.'])


def run(root,output,flow_names,planet_names):
    if output.exists():
        raise ValueError('Use a new review directory')
    output.mkdir(parents=True)
    records,panels,table = [],[],[]
    for name in flow_names:
        source = root/name
        report = json.loads((source/'experiment.json').read_text())
        target = output/name;target.mkdir()
        (target/'experiment.json').write_text(json.dumps(report,separators=(',',':'))+'\n')
        cuts = [dict(countries=r['countries'],original_policy=r['eligible'],mean_density=r.get('mean_density'),p90_density=r.get('p90_segment_density'),corridor_population=r.get('corridor_population')) for r in report['cuts']]
        record = dict(name=name,grid=report['grid'],cuts=cuts,corridor_population_cost=report['corridor_population_cost'],cases=[])
        for case in report['cases']:
            if not case['complete']:
                raise ValueError('Cannot publish an incomplete flow as a result')
            geometry = source/case['name']/'components.geojson'
            if digest(geometry)!=case['geometry_sha256']:
                raise ValueError('Flow geometry differs')
            path = target/case['name'];path.mkdir()
            shutil.copyfile(source/case['name']/'review.png',path/'review.png')
            (path/'components.geojson.gz').write_bytes(gzip.compress(geometry.read_bytes(),mtime=0))
            shapes = read_shapes(geometry)
            scores = {code:max((r for r in case['records'] if r['country']==code),key=lambda r:shapes[r['component']].area)['shape_error'] for code in CODES}
            record['cases'].append(dict(name=case['name'],scores=scores,retained_contacts=case['retained_contacts'],missing_contacts=case['missing_contacts'],overlap=case['overlap']))
            label = name+'/'+case['name']
            table.append('<tr><td>'+label+'</td>'+''.join(f'<td>{scores[c]:.4f}</td>' for c in CODES)+'</tr>')
            panels.append(f'<section><h3>{label}</h3><a href="{label}/review.png"><img src="{label}/review.png" alt="{label}"></a></section>')
        records.append(record)
    planet_records,planet_panels,tile_rows = [],[],[]
    for name in planet_names:
        source = root/name
        report = json.loads((source/'run.json').read_text())
        if not report['complete'] or digest(source/'layout/cells.csv')!=report['cells_sha256']:
            raise ValueError('Planet preview is incomplete or differs')
        cuts = {tuple(sorted(p)) for p in report['cuts']}
        result = tile_audit(root,source,cuts)
        baseline = tile_audit(root,root/'planet-kontur-coarse90',cuts)
        result.update(name=name,cuts=sorted(cuts),same_policy_baseline=baseline,metrics=report['metrics'])
        planet_records.append(result)
        target = output/name;target.mkdir()
        shutil.copyfile(source/'layout/review.png',target/'review.png')
        shutil.copyfile(source/'run.json',target/'run.json')
        (target/'cells.csv.gz').write_bytes(gzip.compress((source/'layout/cells.csv').read_bytes(),mtime=0))
        (target/'lake-cells.csv.gz').write_bytes(gzip.compress((source/'layout/lake-cells.csv').read_bytes(),mtime=0))
        links = []
        for region in ['europe','south-asia','japan-korea','indonesia','africa']:
            shutil.copyfile(source/'regions'/(region+'.png'),target/(region+'.png'))
            links.append(f'<a href="{name}/{region}.png">{region}</a>')
        for label,entry in [(name,result),('Current best, same policy',baseline)]:
            tile_rows.append('<tr><td>'+label+'</td>'+''.join(f'<td>{entry["scores"][c]:.4f}</td>' for c in CODES)+f'<td>{entry["retained_missing"]}</td><td>{entry["false_contacts"]}</td><td>{entry["enclosed_non_lake_cells"]}</td></tr>')
        planet_panels.append(f'<section><h2>{name}: {len(cuts)} cuts</h2><p>'+ ' · '.join(links)+f' · <a href="{name}/run.json">Run record</a></p><a href="{name}/review.png"><img src="{name}/review.png" alt="{name}"></a></section>')
    summary = dict(flows=records,planets=planet_records,script_sha256=digest(Path(__file__)))
    (output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    cut_lists = ''.join('<h3>'+r['name']+'</h3><p>'+', '.join(escape(c['countries'])+(' *' if not c['original_policy'] else '') for c in r['cuts'])+'</p>' for r in records)
    (output/'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Complete early separators</title>
<style>body{font:17px system-ui;max-width:1700px;margin:32px auto;padding:0 20px;overflow-wrap:anywhere}img{width:100%}.table-scroll{overflow-x:auto}table{border-collapse:collapse}td,th{padding:7px;border:1px solid #aaa}.panels{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,500px),1fr))}</style>
<h1>Complete cuts before population fitting</h1>
<p><a href="../planet-kontur-coarse90/index.html">Current best: unchanged</a> · <a href="summary.json">All measurements</a> · <a href="../wide-early-cuts/index.html">Why wider strips were not enough</a></p>
<p><b>Start with the first 55k preview below: the 18-cut candidate.</b> It gives a useful shape release for China and India,
and improves Russia's tile outline score. Kazakhstan is still slightly worse than the current best.
Britain and the Nordic countries still need work. This is not an approved replacement.</p>
<p><b>Research candidates, not replacements.</b> Separate flow domains let large land groups change shape independently.
The earlier four cuts left routes through the Caucasus and North Korea. They did not split the retained border graph.
A shared flow still coupled the regions. A wider empty strip did not remove that coupling.</p>
<p>The new tests cut the graph before any population fit. They fit whole connected groups, not separate countries.
Every uncut border remains inside a shared flow domain. The six-cut test retains all 287 other regional contacts.
The three-domain tests also separate China from India. They retain the contacts counted in their panels.</p>
<p><b>The cut policy changes.</b> The original limits were mean density 20 and segment p90 50 people/km².
The first relaxed tests use 75 and 150. A further test permits p90 200. A short-border alternative permits at most
50 km and at most 500,000 people in the audited corridor. Russia–North Korea uses that alternative.
A star below marks a border that fails the original rule. No relaxed policy is approved for production.
The graph cost sums corridor populations, which can count a person more than once.</p>
<p>All flow runs reuse the original Kontur patches and population targets. They remove no source land or people.
The regional fit contains 143 components and 6,170,824,688 people. Rigid translations place the large groups after fitting.
The 55k previews then use the existing island and empty-lake stages with a separate cut-aware contact file.</p>
<p><a href="../kazakhstan-scoped/owid.png">OWID reference excerpt</a>: Russia is far from China, but China and India still touch.
The new three-domain method needs more cuts than that reference. The excerpt omits other countries;
not every blank area in it is sea. Population scope and country shapes also differ.</p>
<h2>55,000-tile previews</h2>
<p>All completed previews retain exactly 55,000 country tiles. Lakes are empty cells and do not use country tiles.
Compare these tile results, not only the smoother guides. The six-cut preview improves China but worsens Kazakhstan;
Russia's tile outline score does not improve in that six-cut test. The 18-cut test improves all three large-country scores.
It uses five borders that fail the original density rule. All 18 cuts remain open in its tile preview.</p>
<p>The island-order repair allows the minimum movement needed to satisfy source separation before applying the usual movement limit.
This fixes Japan's rejected eastward move in the 21-cut trial without a country-specific rule.
The 18-cut layout already placed Japan on the correct side of Korea.</p>
<div class="table-scroll"><table><tr><th>Map</th><th>Russia</th><th>China</th><th>India</th><th>Kazakhstan</th><th>Missing retained borders</th><th>False borders</th><th>Non-lake enclosed cells</th></tr>'''+''.join(tile_rows)+'''</table></div>
<p>Outline error: lower is better, with area and centre aligned and no rotation. Non-lake enclosed cells are not all phantom holes;
real seas and intended water can be enclosed. The largest new enclosed regions include water beside the Red Sea countries and the Baltic countries;
the summary lists their neighbouring countries. Each baseline row uses the same retained-border policy as its candidate.</p>'''+''.join(planet_panels)+'''<details><summary>Continuous-flow checks and resolution repeats</summary><h2>Continuous-flow checks</h2>
<p>These maps are guides, not tile layouts. All within-domain contacts remain, but solver area floors still affect tiny components.
Grid 256, 512, and 1024 tests change numerical resolution, not the population source. The tile pipeline can change the shape ranking.</p>
<div class="table-scroll"><table><tr><th>Flow</th><th>Russia</th><th>China</th><th>India</th><th>Kazakhstan</th></tr>'''+''.join(table)+'''</table></div><div class="panels">'''+''.join(panels)+'''</div></details><h2>Cut sets</h2>'''+cut_lists+'\n')
    (output/'checksums.json').write_text(json.dumps({str(p.relative_to(output)):digest(p) for p in sorted(output.rglob('*')) if p.is_file()},indent=2)+'\n')
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    parser.add_argument('output',type=Path)
    parser.add_argument('--flow-names',nargs='+',required=True)
    parser.add_argument('--planet-names',nargs='+',required=True)
    run(**vars(parser.parse_args()))
