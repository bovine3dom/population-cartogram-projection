#!/usr/bin/env python3
"""Build a whole-world landmass-first trial from fixed OWID artwork."""
import argparse
import csv
import heapq
import json
from pathlib import Path
import shutil

import numpy as np
from shapely import affinity
from shapely.geometry import Point

from audit_owid_budgets import parts, write_csv
from compact_regions import adjacent
from dock_true_borders import contacts
from fit_local_coasts import fit
from fit_owid_landmass import load
from geographic_baseline import simple_toggle
from partition_landmass import partition
from relax_owid_islands import owners, scaled_template
from resize_owid_islands import outline
from restore_reference_water import enclosed
from review_gaps import read_cells
from review_geography import exterior_water
from review_layout import connectivity
from save_review import digest
from shape_placement import place


def reference_parts(owid,labels):
    raw,grid=read_cells(owid,owid=True)
    iso=json.loads(Path('/usr/share/iso-codes/json/iso_3166-1.json').read_text())['3166-1']
    codes={r['alpha_3']:int(r['numeric']) for r in iso};result={};country_codes={}
    for country in sorted({c.split(':')[0] for c in labels}):
        code=codes[country] if country in codes else int(country[5:]);country_codes[country]=code
        for i,ps in enumerate(parts({p for p,c in raw.items() if int(c)==code})):
            result[f'{country}:T{i+1}']=ps
    if set(result)!=set(labels):raise ValueError('Reference parts differ from budget labels')
    return result,grid,country_codes


def landmasses(reference):
    owner=owners(reference)
    return [sorted({owner[p] for p in ps}) for ps in sorted(parts(set(owner)),key=lambda ps:(-len(ps),min(ps)))]


def footprint(source,count,coast_gaps=()):
    if count==len(source):return set(source)
    water=enclosed({p:1 for p in source})
    if not water:return scaled_template(source,count)
    # Retain internal water and its shores. Adjust only the outside coast.
    protected=water|{q for p in water for q in adjacent(p)}|set(coast_gaps)
    shape=outline(source);centre=np.mean(sorted(source),axis=0);scale=(count/len(source))**.5
    guide=affinity.scale(shape,scale,scale,origin=tuple(centre))
    result=set(source);growing=count>len(source);queue=[];queued=set()
    def offer(p):
        if p in protected or p in queued:return
        if growing and p in result:return
        if not growing and p not in result:return
        point=Point(p);distance=guide.boundary.distance(point)
        signed=-distance if guide.covers(point) else distance
        heapq.heappush(queue,(signed if growing else -signed,p));queued.add(p)
    for p in source:
        for q in adjacent(p):
            if q not in source:
                offer(q if growing else p)
    while len(result)!=count:
        rejected=[]
        while queue:
            score,p=heapq.heappop(queue);queued.remove(p)
            if (p in result)==growing:continue
            if simple_toggle(result,p):break
            rejected.append((score,p))
        else:raise ValueError('Cannot resize while keeping lake topology')
        if growing:result.add(p)
        else:result.remove(p)
        for score,q in rejected:heapq.heappush(queue,(score,q));queued.add(q)
        for q in adjacent(p):offer(q)
    if enclosed({p:1 for p in result})!=water:raise ValueError('Internal water changed')
    return result


def relax_outline(reference,shape,budgets,seconds,tolerance):
    source=set(owners(reference));water=enclosed(owners(reference));required=contacts(owners(reference))
    ocean=exterior_water(owners(reference))
    inland={c for c,ps in reference.items() if not any(q in ocean for p in ps for q in adjacent(p))}
    centre=np.mean(sorted(source),axis=0);scale=(len(shape)/len(source))**.5
    preferred={c:{tuple(np.rint(centre+scale*(np.array(p)-centre)).astype(int)) for p in ps}
               for c,ps in reference.items()}
    working=reference;attempts=[]
    for target in sorted(reference,key=lambda c:(budgets[c]-len(reference[c])>0,c)):
        if len(working[target])==budgets[target]:continue
        movable={target}|{b if a==target else a for a,b in required if target in (a,b)}
        working,solver=fit(working,required,inland,target,margin=12,seconds=seconds,expansion=8,
            movable=movable,preferred=preferred,distance_weight=.1,perimeter_weight=.15,
            sea_connected=True,protected_water=water,fixed_cells=water|{q for p in water for q in adjacent(p)},
            budgets={target:budgets[target]},outline_guide=shape,outline_weight=2.)
        attempts.append(dict(part=target,solver=solver,accepted=working is not None))
        print(json.dumps(attempts[-1]),flush=True)
        if working is None:return None,dict(attempts=attempts,complete=False)
    actual=set(owners(working));difference=len(actual^shape);limit=max(2,int(tolerance*len(shape)))
    valid=(difference<=limit and contacts(owners(working))==required and enclosed(owners(working))==water
           and all(len(working[c])==budgets[c] and connectivity(ps)==1 for c,ps in working.items()))
    return working if valid else None,dict(attempts=attempts,complete=valid,outline_difference=difference,
        outline_difference_fraction=difference/len(shape),outline_difference_limit=limit)


def run(owid,parent,output,seconds=120,radius=4,max_shift=24,outline_tolerance=.01):
    if output.exists():raise ValueError('Use a new output directory')
    output.mkdir(parents=True)
    current=load(parent);reference,grid,codes=reference_parts(owid,current)
    groups=landmasses(reference);budgets={c:len(ps) for c,ps in current.items()}
    record=dict(complete=False,approved=False,reference=str(owid),budget_parent=str(parent),landmasses=[],
        inputs={str(p):digest(p) for p in (owid,parent/'cells.csv',parent/'matches.csv',Path(__file__),Path(__file__).with_name('partition_landmass.py'))},
        max_axis_shift=max_shift,seconds_per_partition=seconds,candidate_radius=radius,outline_tolerance=outline_tolerance)
    def save(): (output/'landmass-world.json').write_text(json.dumps(record,indent=2)+'\n')
    templates=[]
    for labels in groups:
        source=set().union(*(reference[c] for c in labels));target=sum(budgets[c] for c in labels)
        local_owner={p:c for c in labels for p in reference[c]}
        shore={q for p in source for q in adjacent(p) if q not in source}
        coast_gaps={p for p in shore if len({local_owner[q] for n in adjacent(p) for q in [n,*adjacent(n)] if q in local_owner})>1}
        shape=footprint(source,target,coast_gaps)
        entry=dict(parts=labels,before=len(source),after=target,scale=(target/len(source))**.5,
                   internal_water=len(enclosed({p:1 for p in source})))
        if all(len(reference[c])==budgets[c] for c in labels):
            fitted={c:reference[c] for c in labels};entry['status']='unchanged budgets'
        elif len(labels)==1:
            fitted={labels[0]:shape};entry['status']='single-part outline'
        else:
            fitted,entry['solver']=partition({c:reference[c] for c in labels},shape,{c:budgets[c] for c in labels},radius,seconds)
            entry['status']='partitioned' if fitted is not None else 'blocked'
            if fitted is None and outline_tolerance>0:
                fitted,entry['relaxed_solver']=relax_outline({c:reference[c] for c in labels},shape,
                    {c:budgets[c] for c in labels},seconds,outline_tolerance)
                if fitted is not None:entry['status']='bounded outline relaxation'
        record['landmasses'].append(entry);save()
        print(json.dumps(entry),flush=True)
        if fitted is None:continue
        templates.append((labels,fitted,entry))
    if any(r['status']=='blocked' for r in record['landmasses']):return record
    # Place each completed landmass as a rigid object. Keep the reviewed parent
    # centres as position guides, but never use its outlines as shape input.
    occupied=set();placed=[];result={};protected_water=set()
    for labels,fitted,entry in sorted(templates,key=lambda r:(-sum(budgets[c] for c in r[0]),r[0])):
        shape=set().union(*fitted.values());old=set().union(*(current[c] for c in labels))
        desired=np.mean(sorted(old),axis=0);centre=np.mean(sorted(shape),axis=0)
        low=desired-centre-max_shift;high=desired-centre+max_shift
        for previous,moved_centre in placed:
            for axis in (0,1):
                delta=desired[axis]-previous[axis]
                if delta>=2:low[axis]=max(low[axis],moved_centre[axis]+1-centre[axis])
                elif delta<=-2:high[axis]=min(high[axis],moved_centre[axis]-1-centre[axis])
        blocked=occupied|protected_water|{(x+dx,y+dy) for x,y in occupied for dx in (-1,0,1) for dy in (-1,0,1)}
        try:moved=place(shape,desired,blocked,maximum_radius=64,translation_bounds=[low,high])
        except ValueError as error:
            entry['placement_error']=str(error);save();return record
        shift=np.rint(np.mean(sorted(moved),axis=0)-centre).astype(int);dx,dy=map(int,shift)
        for c,ps in fitted.items():result[c]={(x+dx,y+dy) for x,y in ps}
        lake={(x+dx,y+dy) for x,y in enclosed({p:1 for p in shape})}
        if lake&occupied:raise ValueError('Placement would enclose another landmass in a lake')
        occupied|=moved;protected_water|=lake;placed.append((desired,centre+shift))
        entry['translation']=[dx,dy];entry['centre_displacement']=(centre+shift-desired).tolist();save()
    owner=owners(result)
    assert len(owner)==sum(budgets.values())
    assert all(len(result[c])==budgets[c] and connectivity(result[c])==1 for c in budgets)
    assert contacts(owner)==contacts(owners(reference))
    water=enclosed(owner)
    if water!=protected_water:
        record['water_error']=dict(unexpected=len(water-protected_water),missing=len(protected_water-water));save();return record
    record.update(complete=True,parts=len(result),total_tiles=len(owner),enclosed_water_cells=len(water),
                  released_inter_landmass_gap_cells=len(enclosed(owners(reference)))-sum(r['internal_water'] for r in record['landmasses']))
    write_csv(output/'cells.csv',[dict(component_id=c,x=x,y=y) for c,ps in sorted(result.items()) for x,y in sorted(ps)])
    with owid.open() as stream:raw=[tuple(map(int,r)) for r in csv.reader(stream)]
    x0=min(r[0] for r in raw);y0=min(r[1] for r in raw)
    step=json.loads((parent/'report.json').read_text())['grid']['input_grid_step']
    with (output/'owid-cartogram.csv').open('w',newline='') as stream:
        writer=csv.writer(stream,lineterminator='\n')
        writer.writerows((x0+step*x,y0-step*y,codes[c.split(':')[0]]) for c,ps in sorted(result.items()) for x,y in sorted(ps))
    for name in ('matches.csv','source-assignments.csv','source-scopes-without-tiles.csv'):shutil.copyfile(parent/name,output/name)
    report=json.loads((parent/'report.json').read_text())
    # Preserve old reports only as provenance, not as checks on this new layout.
    for key in ('relaxation','landmass_fit','parent_layout_sha256'):report.pop(key,None)
    report.update(relaxed_layout=False,landmass_world=record,enclosed_water_cells=len(water))
    for entry in report['countries']:
        entry['status']='landmass-first trial'
        entry['edits']={c:dict(before=len(reference[c]),after=len(result[c]),removed=len(reference[c]-result[c]),added=len(result[c]-reference[c]))
                        for c in result if c.split(':')[0]==entry['country'] and result[c]!=reference[c]}
    report['limits'].append('All shape guides come from original OWID artwork. Internal landmass water is retained. Inter-landmass gaps can open to the sea. Source identities are inherited, not approved.')
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n');save()
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('owid','parent','output'):parser.add_argument(name,type=Path)
    parser.add_argument('--seconds',type=float,default=120)
    parser.add_argument('--radius',type=float,default=4)
    parser.add_argument('--max-shift',type=int,default=24)
    parser.add_argument('--outline-tolerance',type=float,default=.01)
    raise SystemExit(0 if run(**vars(parser.parse_args()))['complete'] else 2)
