#!/usr/bin/env python3
"""Publish a checked coarse Kontur repair trial without changing the current best."""
import argparse
from collections import defaultdict
import gzip
import json
from pathlib import Path
import shutil
import subprocess

import audit_coarse90
from compact_regions import adjacent
from dock_true_borders import contacts
import review_geography
import review_layout
import review_regions
from run_margin1_projection import ROOT, INPUTS, POLYGONS
from save_review import digest


def publish(layout, output):
    if output.exists():raise ValueError('Use a new review directory')
    baseline=ROOT/'planet-kontur-coarse90/layout'
    rows,tiles,owner=review_layout.load(INPUTS,layout)
    before=review_layout.load(INPUTS,baseline)[2]
    required={tuple(sorted((r['a'],r['b']))) for r in review_layout.read_csv(INPUTS/'geographic-contacts.csv') if r['both_represented']=='true'}
    assert len(owner)==55000 and all(len(tiles[c])==int(rows[c]['tiles']) and review_layout.connectivity(tiles[c])==1 for c in tiles)
    water=defaultdict(set)
    for r in review_layout.read_csv(layout/'lake-cells.csv'):water[r['lake_id']].add((int(r['x']),int(r['y'])))
    assert not set().union(*water.values()) & owner.keys()
    lake_report=json.loads((layout/'lake-placement.json').read_text())
    for lake in lake_report['lakes']:
        if not lake.get('accepted'):continue
        points=water[lake['lake_id']]
        shore={owner.get(q) for p in points for q in adjacent(p) if q not in points}
        assert set(lake['required_shores'])<=shore<=set(lake['allowed_shores']), lake['name']
    old,new=contacts(before),contacts(owner)
    record=dict(approved=False,layout=str(layout),known_defects=audit_coarse90.audit(layout),
                baseline_defects=audit_coarse90.audit(baseline),
                gained_true=sorted((new & required)-old),lost_true=sorted((old & required)-new),
                added_false=sorted(new-required-old),removed_false=sorted(old-required-new),
                lake_count=len(water),empty_lake_cells=sum(map(len,water.values())),
                inputs={str(p):digest(p) for p in [baseline/'cells.csv',layout/'cells.csv',layout/'lake-cells.csv',INPUTS/'groups.csv',INPUTS/'geographic-contacts.csv']})
    metrics=review_layout.run(INPUTS,layout,'Coarse 90% Kontur: mainland repair trial')
    review_regions.run(INPUTS,layout,layout/'regions')
    subprocess.run(['rsvg-convert',str(layout/'review.svg'),'-o',str(layout/'review.png')],check=True)
    output.mkdir(parents=True)
    review_geography.run(INPUTS,layout,POLYGONS,output/'geography')
    for name in ['landmass-parts.json','nearby-relations.json','water-access.csv']:
        path=output/'geography'/name
        with gzip.open(path.with_suffix(path.suffix+'.gz'),'wb') as stream:stream.write(path.read_bytes())
        path.unlink()
    audit_coarse90.plot_new_york(layout,output/'new-york.png')
    (output/'new-york.svg').unlink()
    for name in ['review.png','metrics.json']:
        shutil.copyfile(layout/name,output/name)
    for name in ['europe','indonesia','japan-korea','south-america','africa']:
        shutil.copyfile(layout/'regions'/f'{name}.png',output/f'{name}.png')
    for name in ['cells.csv','lake-cells.csv','lake-placement.json']:
        with gzip.open(output/(name+'.gz'),'wb') as stream:stream.write((layout/name).read_bytes())
    for name in ['local-coasts.json','separation.json','coastal-bays.json']:
        if (layout/name).exists():shutil.copyfile(layout/name,output/name)
    record['metrics']=metrics
    record['files']={str(p.relative_to(output)):digest(p) for p in output.rglob('*') if p.is_file()}
    (output/'checks.json').write_text(json.dumps(record,indent=2)+'\n')
    d=record['known_defects'];b=record['baseline_defects']
    def coast(data,country):return sum(v['exterior_water_edges'] for c,v in data['coasts'].items() if c.startswith(country+':'))
    checks=[('Malaysia touches Thailand',b['malaysia_thailand_contact'],d['malaysia_thailand_contact']),
            ('Sweden touches Germany',b['sweden_germany_contact'],d['sweden_germany_contact']),
            ('Lithuania exterior-water edges',coast(b,'LTU'),coast(d,'LTU')),
            ('Paraguay exterior-water edges',coast(b,'PRY'),coast(d,'PRY'))]
    table=''.join(f'<tr><td>{label}</td><td>{old}</td><td>{new}</td></tr>' for label,old,new in checks)
    regions=''.join(f'<h2>{name.replace("-"," ").title()}</h2><img src="{name}.png" alt="{name}">' for name in ['europe','indonesia','japan-korea','south-america','africa','new-york'])
    (output/'index.html').write_text(f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Coarse Kontur repair trial</title>
<style>body{{font:18px system-ui;max-width:1200px;margin:2em auto;padding:0 1em}}img{{max-width:100%}}td,th{{padding:.5em;text-align:left}}table{{border-collapse:collapse}}tr{{border-bottom:1px solid #ccc}}</style>
<h1>Coarse 90% Kontur: mainland repair trial</h1>
<p>Research candidate. The current best and H3-MON data are unchanged. No strategic cuts.</p>
<p>All 55,000 tiles retain exact component budgets. All 481 components are connected. The {len(water)} lakes use {sum(map(len,water.values()))} empty cells. Lake shore checks pass.</p>
<table><tr><th>Check</th><th>Current best</th><th>Candidate</th></tr>{table}</table>
<p>There are {metrics['missing_contacts']} missing and {metrics['false_contacts']} false contacts. The current best has 73 and 48. The candidate gains {len(record['gained_true'])} true contacts and loses {len(record['lost_true'])}. It removes {len(record['removed_false'])} false contacts and adds {len(record['added_false'])}. These totals do not prove correct geography.</p>
<p>Open issues include Paraguay's false coast, the missing Finland–Norway border, the Nordic shapes, and missing mainland connections. A coast can be mathematically valid but visually poor. Do not use this as a production map.</p>
<p><a href="checks.json">Checks and exact contact changes</a> · <a href="cells.csv.gz">Land tiles</a> · <a href="lake-cells.csv.gz">Empty lake cells</a> · <a href="geography/summary.json">Geographic audit</a></p>
<h2>World</h2><img src="review.png" alt="World trial">{regions}</html>\n''')
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('layout',type=Path);parser.add_argument('output',type=Path)
    publish(**vars(parser.parse_args()))
