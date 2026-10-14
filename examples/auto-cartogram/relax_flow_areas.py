#!/usr/bin/env python3
"""Relax guide areas within source land-border and continent groups, not tile budgets."""
import argparse
import csv
import json
import math
from pathlib import Path
import shutil
import tempfile

from partition_land import contact_groups
from review_layout import read_csv
from save_review import digest


def relaxed_areas(rows,regions,blend):
    if not math.isfinite(blend) or not 0<=blend<=1:raise ValueError('Blend must be between zero and one')
    if len({r['component_id'] for r in rows})!=len(rows):raise ValueError('Duplicate components')
    totals={}
    for r in rows:
        area=float(r['source_area']);tiles=float(r['tiles'])
        if not math.isfinite(area+tiles) or min(area,tiles)<=0:raise ValueError('Invalid component area')
        group=regions[r['component_id']];a,n=totals.get(group,(0.,0.));totals[group]=(a+area,n+tiles)
    return {r['component_id']:(1-blend)*float(r['tiles'])+blend*float(r['source_area'])*totals[regions[r['component_id']]][1]/totals[regions[r['component_id']]][0] for r in rows}


def run(inputs,flow_input,components,map_units,output,blend=.25):
    if output.exists():raise ValueError('Output already exists')
    rows=read_csv(flow_input/'components.csv');labels={r['component_id'] for r in rows}
    budgets={r['component_id']:int(r['tiles']) for r in read_csv(inputs/'groups.csv') if int(r['tiles'])>0}
    if labels!=set(budgets) or any(float(r['tiles'])!=budgets[r['component_id']] for r in rows):raise ValueError('Prepared guide budgets differ from original inputs')
    records=read_csv(components);units={r['component_id']:r['map_unit'] for r in records}
    if len(units)!=len(records):raise ValueError('Duplicate source component records')
    continents={};country_continents={}
    for feature in json.loads(map_units.read_text())['features']:
        p=feature['properties'];unit=p['GU_A3'];continent=p['CONTINENT']
        if unit in continents and continents[unit]!=continent:raise ValueError('Ambiguous source continent')
        continents[unit]=continent
        if p.get('ADM0_A3'):country_continents.setdefault(p['ADM0_A3'],set()).add(continent)
    fallbacks={c:next(iter(values)) for c,values in country_continents.items() if c not in continents and len(values)==1}
    continents.update(fallbacks)
    pairs=[(r['a'],r['b']) for r in read_csv(inputs/'geographic-contacts.csv') if r['both_represented']=='true']
    groups=contact_groups(pairs);membership={c:str(i) for i,group in enumerate(groups) for c in group}
    if not set(membership)<=labels:raise ValueError('Border labels differ')
    try:regions={c:(membership[c],continents[units[c]]) if c in membership else ('isolated',c) for c in labels}
    except KeyError as error:raise ValueError('Missing source map-unit classification') from error
    areas=relaxed_areas(rows,regions,blend)
    totals={}
    for r in rows:
        c=r['component_id'];group=' / '.join(regions[c]);record=totals.setdefault(group,dict(requested=0.,guide=0.))
        record['requested']+=float(r['tiles']);record['guide']+=areas[c]
    if any(not math.isclose(r['requested'],r['guide'],rel_tol=1e-12,abs_tol=1e-8) for r in totals.values()):raise AssertionError('Regional budget changed')
    files=[inputs/'groups.csv',inputs/'geographic-contacts.csv',flow_input/'components.csv',flow_input/'geometry.geojson',components,map_units]
    report=dict(method='Blend requested guide areas with source-area shares inside each source land-border group and Natural Earth continent label',blend=blend,regions=totals,continent_fallbacks={u:fallbacks[u] for u in sorted({units[c] for c in membership}&set(fallbacks))},inputs={str(p):digest(p) for p in files},scripts={name:digest(Path(__file__).with_name(name)) for name in ['relax_flow_areas.py','partition_land.py']},limit='Footprint guide only. These are not population targets. Final tile assignment must use the original inputs. Source continent labels can place a transcontinental component in one region. A dissolved map-unit code can use its country code only when all source map units of that country have one continent label; these fallbacks are recorded. Isolated components retain their requested guide areas. No geometry or adjacency is joined by this classification. The external solver can further adjust small areas.')
    output.parent.mkdir(parents=True,exist_ok=True);temp=Path(tempfile.mkdtemp(prefix='relaxed-flow-',dir=output.parent))
    try:
        shutil.copyfile(flow_input/'geometry.geojson',temp/'geometry.geojson')
        with (temp/'areas.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','tiles'])
            writer.writerows((c,areas[c]) for c in sorted(areas))
        with (temp/'guide-areas.csv').open('w',newline='') as stream:
            writer=csv.writer(stream);writer.writerow(['component_id','requested_tiles','guide_area','source_area','region'])
            writer.writerows((r['component_id'],r['tiles'],areas[r['component_id']],r['source_area'],' / '.join(regions[r['component_id']])) for r in rows)
        report['areas_sha256']=digest(temp/'areas.csv');(temp/'manifest.json').write_text(json.dumps(report,indent=2)+'\n');temp.rename(output)
    finally:
        if temp.exists():shutil.rmtree(temp)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['inputs','flow_input','components','map_units','output']:parser.add_argument(name,type=Path)
    parser.add_argument('--blend',type=float,default=.25)
    print(json.dumps(run(**vars(parser.parse_args())),indent=2))
