#!/usr/bin/env python3
"""Scale a shared OWID island outline before fitting its internal borders."""
import argparse
import csv
import json
from pathlib import Path
import shutil

import numpy as np

from audit_owid_budgets import write_csv
from dock_true_borders import contacts
from fit_local_coasts import fit
from relax_owid_islands import owners, rows, scaled_template
from restore_reference_water import enclosed
from review_layout import connectivity
from save_review import digest


def load(path):
    tiles={}
    for r in rows(path/'cells.csv'):
        tiles.setdefault(r['component_id'],set()).add((int(r['x']),int(r['y'])))
    return tiles


def run(reference,parent,output,labels,seconds=180):
    if output.exists():raise ValueError('Use a new output directory')
    original=load(reference);current=load(parent);selected=set(labels)
    if not selected<=original.keys() or not selected<=current.keys():raise ValueError('Unknown part')
    source=set().union(*(original[c] for c in selected))
    total=sum(len(current[c]) for c in selected)
    footprint=scaled_template(source,total)
    if connectivity(source)!=1 or connectivity(footprint)!=1:raise ValueError('Use one connected landmass')
    centre=np.mean(sorted(source),axis=0);scale=(total/len(source))**.5
    # All parts use the same transform, not independent country centroids.
    preferred={c:{tuple(np.rint(centre+scale*(np.array(p)-centre)).astype(int))
                  for p in original[c]} for c in selected}
    required=contacts(owners(original));water=enclosed(owners(original))
    candidate,attempts=fit(original,required,set(),labels[0],margin=48,seconds=seconds,
        expansion=8,movable=selected,preferred=preferred,perimeter_weight=.15,
        distance_weight=.1,sea_connected=True,protected_water=water,
        fixed_cells=water,budgets={c:len(current[c]) for c in selected},footprint=footprint)
    if candidate is None:raise RuntimeError(attempts)
    result={**current,**{c:candidate[c] for c in selected}}
    before=owners(current);after=owners(result)
    assert len(after)==sum(map(len,result.values()))==len(before)
    assert contacts(after)==contacts(before) and enclosed(after)==enclosed(before)
    assert all(len(result[c])==len(current[c]) and connectivity(result[c])==1 for c in current)
    assert set().union(*(result[c] for c in selected))==footprint
    report=json.loads((parent/'report.json').read_text())
    record=dict(reference=str(reference),parent=str(parent),parts=labels,old_area=len(source),
        new_area=total,scale=scale,attempts=attempts,complete=True,approved=False,
        inputs={str(p):digest(p) for p in (reference/'cells.csv',parent/'cells.csv',Path(__file__),Path(__file__).with_name('fit_local_coasts.py'))})
    report['landmass_fit']=record
    report['limits'].append('The selected shared island has a fixed scaled outline. Internal borders can move. Source identities are unchanged.')
    for entry in report['countries']:
        changed=[c for c in selected if c.split(':')[0]==entry['country']]
        if changed:
            entry['status']='shared island outline trial'
            entry['edits']={c:dict(before=len(current[c]),after=len(result[c]),removed=len(current[c]-result[c]),added=len(result[c]-current[c])) for c in changed}
    output.mkdir(parents=True)
    for name in ('matches.csv','source-assignments.csv','source-scopes-without-tiles.csv','relaxation.json'):
        shutil.copyfile(parent/name,output/name)
    write_csv(output/'cells.csv',[dict(component_id=c,x=x,y=y) for c,p in sorted(result.items()) for x,y in sorted(p)])
    # Keep the parent export's coordinate transform and numeric country codes.
    with (parent/'owid-cartogram.csv').open() as stream:export=[tuple(map(int,r)) for r in csv.reader(stream)]
    # The OWID transform is fixed by the original input, not the trial bounds.
    with Path('data/cartogram.csv').open() as stream:base=[tuple(map(int,r)) for r in csv.reader(stream)]
    x0=min(r[0] for r in base);y0=min(r[1] for r in base);step=report['grid']['input_grid_step']
    codes={before[((x-x0)//step,-(y-y0)//step)]:code for x,y,code in export}
    with (output/'owid-cartogram.csv').open('w',newline='') as stream:
        writer=csv.writer(stream,lineterminator='\n')
        writer.writerows((x0+step*x,y0-step*y,codes[c]) for c,ps in sorted(result.items()) for x,y in sorted(ps))
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    (output/'landmass-fit.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('reference','parent','output'):parser.add_argument(name,type=Path)
    parser.add_argument('--labels',nargs='+',required=True)
    parser.add_argument('--seconds',type=float,default=180)
    run(**vars(parser.parse_args()))
